@testable import PFile
import Foundation

@MainActor
final class MockWatchHistoryRepository: WatchHistoryRepository {

    var histories: [WatchHistory] = []
    var upsertedCalls: [(filePath: String, position: Double)] = []
    var deletedHistories: [WatchHistory] = []
    var trimmedLimit: Int?
    var shouldThrow = false

    func fetchAll() async throws -> [WatchHistory] {
        if shouldThrow { throw TestError.mock }
        return histories
    }

    func fetch(for connectionId: UUID) async throws -> [WatchHistory] {
        if shouldThrow { throw TestError.mock }
        return histories.filter { $0.connection?.id == connectionId }
    }

    func fetch(for sourceID: String) async throws -> [WatchHistory] {
        if shouldThrow { throw TestError.mock }
        return histories.filter { $0.sourceID == sourceID }
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
        if shouldThrow { throw TestError.mock }
        upsertedCalls.append((filePath: filePath, position: lastPositionSeconds))
    }

    func fetchLastPosition(sourceID: String, filePath: String, fileId: UInt64?) async throws -> Double? {
        if shouldThrow { throw TestError.mock }
        return histories.first {
            guard $0.sourceID == sourceID else { return false }
            if let fileId, fileId > 0 {
                return $0.fileId == fileId || $0.filePath == filePath
            }
            return $0.filePath == filePath
        }?.lastPositionSeconds
    }

    func trim(to limit: Int) async throws {
        if shouldThrow { throw TestError.mock }
        trimmedLimit = limit
        histories = Array(histories.prefix(limit))
    }

    func delete(_ history: WatchHistory) async throws {
        if shouldThrow { throw TestError.mock }
        deletedHistories.append(history)
        histories.removeAll { $0.id == history.id }
    }

    var deleteAllCalled = false

    func deleteAll() async throws {
        if shouldThrow { throw TestError.mock }
        deleteAllCalled = true
        histories.removeAll()
    }
}
