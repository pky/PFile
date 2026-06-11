import Foundation
import SwiftData

@MainActor
final class WatchHistoryRepositoryImpl: WatchHistoryRepository {
    private enum ResumePositionPolicy {
        static let completionThresholdRemainingSeconds = 10.0

        static func normalizedPosition(
            lastPositionSeconds: Double,
            durationSeconds: Double?
        ) -> Double {
            let safePosition = max(0, lastPositionSeconds)
            guard let durationSeconds, durationSeconds > 0 else { return safePosition }

            let remainingSeconds = max(0, durationSeconds - safePosition)
            if remainingSeconds <= completionThresholdRemainingSeconds {
                return 0
            }
            return min(safePosition, durationSeconds)
        }
    }

    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func fetchAll() async throws -> [WatchHistory] {
        let descriptor = FetchDescriptor<WatchHistory>(
            sortBy: [SortDescriptor(\.watchedAt, order: .reverse)]
        )
        return try context.fetch(descriptor)
    }

    func fetch(for connectionId: UUID) async throws -> [WatchHistory] {
        // #Predicate はオプショナルリレーションの optional chaining に非対応のためメモリフィルター
        let all = try await fetchAll()
        return all.filter { $0.connection?.id == connectionId }
    }

    func fetch(for sourceID: String) async throws -> [WatchHistory] {
        let all = try await fetchAll()
        return all.filter { $0.sourceID == sourceID }
    }

    func upsert(
        sourceID: String,
        connection: RemoteConnection?,
        filePath: String,
        fileName: String,
        lastPositionSeconds: Double,
        durationSeconds: Double?,
        fileId: UInt64?,
        thumbnailData: Data?
    ) async throws {
        let all = try context.fetch(FetchDescriptor<WatchHistory>())
        let normalizedSourceID = sourceID.isEmpty ? connection.map { ContentSource.remote($0.id).id } ?? "" : sourceID
        let matchingHistories = all.filter {
            let existingSourceID = $0.sourceID.isEmpty ? $0.connection.map { ContentSource.remote($0.id).id } ?? "" : $0.sourceID
            guard existingSourceID == normalizedSourceID else { return false }
            if let fileId, fileId > 0 {
                return $0.fileId == fileId || $0.filePath == filePath
            }
            return $0.filePath == filePath
        }
        if let existing = matchingHistories.max(by: { $0.watchedAt < $1.watchedAt }) {
            for duplicate in matchingHistories where duplicate.id != existing.id {
                context.delete(duplicate)
            }
            existing.sourceID = normalizedSourceID
            existing.connection = connection
            existing.filePath = filePath
            existing.fileName = fileName
            existing.lastPositionSeconds = lastPositionSeconds
            existing.durationSeconds = durationSeconds
            if existing.fileId == nil, let fileId {
                existing.fileId = fileId
            }
            existing.watchedAt = Date()
            if let thumbnail = thumbnailData {
                existing.thumbnailData = thumbnail
            }
        } else {
            let history = WatchHistory(
                sourceID: normalizedSourceID,
                connection: connection,
                filePath: filePath,
                fileName: fileName,
                lastPositionSeconds: lastPositionSeconds,
                durationSeconds: durationSeconds,
                fileId: fileId,
                thumbnailData: thumbnailData
            )
            context.insert(history)
        }
        try context.save()

        try await trim(to: WatchHistoryLimitSettings.currentLimit)
    }

    func fetchLastPosition(sourceID: String, filePath: String, fileId: UInt64?) async throws -> Double? {
        let all = try context.fetch(FetchDescriptor<WatchHistory>())
        let history = all.first { history in
            guard history.sourceID == sourceID else { return false }
            if let fileId, fileId > 0 {
                return history.fileId == fileId || history.filePath == filePath
            }
            return history.filePath == filePath
        }
        guard let history else {
            return nil
        }
        return ResumePositionPolicy.normalizedPosition(
            lastPositionSeconds: history.lastPositionSeconds,
            durationSeconds: history.durationSeconds
        )
    }

    func trim(to limit: Int) async throws {
        let limit = max(0, limit)
        let allSorted = try context.fetch(FetchDescriptor<WatchHistory>(
            sortBy: [SortDescriptor(\.watchedAt, order: .reverse)]
        ))
        if allSorted.count > limit {
            allSorted.suffix(from: limit).forEach { context.delete($0) }
            try context.save()
        }
    }

    func delete(_ history: WatchHistory) async throws {
        context.delete(history)
        try context.save()
    }

    func deleteAll() async throws {
        let all = try context.fetch(FetchDescriptor<WatchHistory>())
        for history in all {
            context.delete(history)
        }
        try context.save()
    }
}
