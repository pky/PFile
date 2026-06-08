import Foundation

extension Notification.Name {
    static let playbackHistoryDidChange = Notification.Name("playbackHistoryDidChange")
}

@MainActor
final class PlaybackHistoryService {
    private enum ResumePositionPolicy {
        static let completionThresholdRemainingSeconds = 10.0

        static func normalizedPosition(
            currentPositionSeconds: Double,
            durationSeconds: Double
        ) -> Double {
            let safePosition = max(0, currentPositionSeconds)
            guard durationSeconds > 0 else { return safePosition }

            let remainingSeconds = max(0, durationSeconds - safePosition)
            if remainingSeconds <= completionThresholdRemainingSeconds {
                return 0
            }
            return min(safePosition, durationSeconds)
        }
    }

    private let repository: any WatchHistoryRepository
    private let mediaThumbnailProvider: MediaThumbnailProvider?

    init(
        repository: any WatchHistoryRepository,
        mediaThumbnailProvider: MediaThumbnailProvider? = nil
    ) {
        self.repository = repository
        self.mediaThumbnailProvider = mediaThumbnailProvider
    }

    func saveProgress(
        source: ContentSource,
        connection: RemoteConnection?,
        item: DirectoryItem,
        currentPositionSeconds: Double,
        durationSeconds: Double?,
        thumbnailData: Data?
    ) async {
        guard let durationSeconds, durationSeconds > 0 else { return }
        let normalizedPosition = ResumePositionPolicy.normalizedPosition(
            currentPositionSeconds: currentPositionSeconds,
            durationSeconds: durationSeconds
        )
        let resolvedThumbnailData = await resolvedThumbnailData(
            source: source,
            connection: connection,
            item: item,
            preferredThumbnailData: thumbnailData
        )

        do {
            try await repository.upsert(
                sourceID: source.id,
                connection: connection,
                filePath: item.path,
                fileName: item.name,
                lastPositionSeconds: normalizedPosition,
                durationSeconds: durationSeconds,
                fileId: item.fileId,
                thumbnailData: resolvedThumbnailData
            )
            NotificationCenter.default.post(
                name: .playbackHistoryDidChange,
                object: nil,
                userInfo: ["sourceID": source.id]
            )
        } catch {
            print("[PlaybackHistoryService] Failed to save progress: \(error)")
        }
    }

    private func resolvedThumbnailData(
        source: ContentSource,
        connection: RemoteConnection?,
        item: DirectoryItem,
        preferredThumbnailData: Data?
    ) async -> Data? {
        if let mediaThumbnailProvider {
            let image = await mediaThumbnailProvider.loadThumbnail(
                for: source,
                item: item,
                connection: connection
            )
            if let imageData = image?.jpegData(compressionQuality: 0.7) {
                return imageData
            }
        }
        return preferredThumbnailData
    }
}
