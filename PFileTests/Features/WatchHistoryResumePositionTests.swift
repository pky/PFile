@testable import PFile
import Testing
import Foundation
import SwiftData

@MainActor
struct WatchHistoryResumePositionTests {

    @Test("一致するsourceIDとfilePathがある場合、lastPositionSecondsを返す")
    func fetchLastPosition_found() async throws {
        let repo = MockWatchHistoryRepository()
        let connection = ModelFactory.makeConnection()
        let sourceID = ContentSource.remote(connection.id).id
        repo.histories = [
            WatchHistory(
                sourceID: sourceID,
                connection: connection,
                filePath: "/videos/a.mp4",
                fileName: "a.mp4",
                lastPositionSeconds: 42.0
            )
        ]

        let position = try await repo.fetchLastPosition(sourceID: sourceID, filePath: "/videos/a.mp4")

        #expect(position == 42.0)
    }

    @Test("一致するエントリがない場合、nilを返す")
    func fetchLastPosition_notFound() async throws {
        let repo = MockWatchHistoryRepository()
        let connection = ModelFactory.makeConnection()
        let sourceID = ContentSource.remote(connection.id).id
        repo.histories = []

        let position = try await repo.fetchLastPosition(sourceID: sourceID, filePath: "/videos/a.mp4")

        #expect(position == nil)
    }

    @Test("sourceIDが異なる場合、nilを返す")
    func fetchLastPosition_differentSourceID() async throws {
        let repo = MockWatchHistoryRepository()
        let connection = ModelFactory.makeConnection()
        let otherConnection = ModelFactory.makeConnection()
        let sourceID = ContentSource.remote(connection.id).id
        let otherSourceID = ContentSource.remote(otherConnection.id).id
        repo.histories = [
            WatchHistory(
                sourceID: otherSourceID,
                connection: otherConnection,
                filePath: "/videos/a.mp4",
                fileName: "a.mp4",
                lastPositionSeconds: 10.0
            )
        ]

        let position = try await repo.fetchLastPosition(sourceID: sourceID, filePath: "/videos/a.mp4")

        #expect(position == nil)
    }

    @Test("filePathが異なる場合、nilを返す")
    func fetchLastPosition_differentFilePath() async throws {
        let repo = MockWatchHistoryRepository()
        let connection = ModelFactory.makeConnection()
        let sourceID = ContentSource.remote(connection.id).id
        repo.histories = [
            WatchHistory(
                sourceID: sourceID,
                connection: connection,
                filePath: "/videos/b.mp4",
                fileName: "b.mp4",
                lastPositionSeconds: 20.0
            )
        ]

        let position = try await repo.fetchLastPosition(sourceID: sourceID, filePath: "/videos/a.mp4")

        #expect(position == nil)
    }

    @Test("shouldThrow=trueの場合、エラーをスローする")
    func fetchLastPosition_throws() async {
        let repo = MockWatchHistoryRepository()
        repo.shouldThrow = true

        await #expect(throws: (any Error).self) {
            _ = try await repo.fetchLastPosition(sourceID: "any", filePath: "/any.mp4")
        }
    }

    @Test("終了直前の履歴は再開位置を0秒に丸める")
    func fetchLastPosition_returnsZeroWhenHistoryIsNearEnd() async throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Schema([WatchHistory.self, RemoteConnection.self]),
            configurations: [configuration]
        )
        let repo = WatchHistoryRepositoryImpl(context: ModelContext(container))
        let connection = ModelFactory.makeConnection()
        let sourceID = ContentSource.remote(connection.id).id

        try await repo.upsert(
            sourceID: sourceID,
            connection: connection,
            filePath: "/videos/a.mp4",
            fileName: "a.mp4",
            lastPositionSeconds: 5_291,
            durationSeconds: 5_300,
            fileId: nil,
            thumbnailData: nil
        )

        let position = try await repo.fetchLastPosition(sourceID: sourceID, filePath: "/videos/a.mp4")

        #expect(position == 0)
    }

    @Test("残り10秒より多い履歴は再開位置を保持する")
    func fetchLastPosition_keepsPositionWhenHistoryIsNotNearEnd() async throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Schema([WatchHistory.self, RemoteConnection.self]),
            configurations: [configuration]
        )
        let repo = WatchHistoryRepositoryImpl(context: ModelContext(container))
        let connection = ModelFactory.makeConnection()
        let sourceID = ContentSource.remote(connection.id).id

        try await repo.upsert(
            sourceID: sourceID,
            connection: connection,
            filePath: "/videos/a.mp4",
            fileName: "a.mp4",
            lastPositionSeconds: 5_189.507,
            durationSeconds: 5_300,
            fileId: nil,
            thumbnailData: nil
        )

        let position = try await repo.fetchLastPosition(sourceID: sourceID, filePath: "/videos/a.mp4")

        #expect(position == 5_189.507)
    }

    @Test("fileIdが一致する履歴は移動後のパスに更新する")
    func upsert_updatesExistingHistoryWhenFileIdMatches() async throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Schema([WatchHistory.self, RemoteConnection.self]),
            configurations: [configuration]
        )
        let repo = WatchHistoryRepositoryImpl(context: ModelContext(container))
        let connection = ModelFactory.makeConnection()
        let sourceID = ContentSource.remote(connection.id).id

        try await repo.upsert(
            sourceID: sourceID,
            connection: connection,
            filePath: "/old/a.mp4",
            fileName: "a.mp4",
            lastPositionSeconds: 60,
            durationSeconds: 120,
            fileId: 123,
            thumbnailData: nil
        )

        try await repo.upsert(
            sourceID: sourceID,
            connection: connection,
            filePath: "/new/a.mp4",
            fileName: "a.mp4",
            lastPositionSeconds: 70,
            durationSeconds: 120,
            fileId: 123,
            thumbnailData: nil
        )

        let histories = try await repo.fetchAll()
        #expect(histories.count == 1)
        #expect(histories[0].filePath == "/new/a.mp4")
        #expect(histories[0].lastPositionSeconds == 70)
    }

    @Test("重複した同一動画履歴はupsert時に1件へ統合する")
    func upsert_mergesDuplicateHistoriesForSameFile() async throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Schema([WatchHistory.self, RemoteConnection.self]),
            configurations: [configuration]
        )
        let context = ModelContext(container)
        let repo = WatchHistoryRepositoryImpl(context: context)
        let connection = ModelFactory.makeConnection()
        let sourceID = ContentSource.remote(connection.id).id

        context.insert(WatchHistory(
            sourceID: sourceID,
            connection: connection,
            filePath: "/old/a.mp4",
            fileName: "a.mp4",
            lastPositionSeconds: 30,
            durationSeconds: 120,
            fileId: 123
        ))
        context.insert(WatchHistory(
            sourceID: sourceID,
            connection: connection,
            filePath: "/new/a.mp4",
            fileName: "a.mp4",
            lastPositionSeconds: 40,
            durationSeconds: 120,
            fileId: 123
        ))
        try context.save()

        try await repo.upsert(
            sourceID: sourceID,
            connection: connection,
            filePath: "/newer/a.mp4",
            fileName: "a.mp4",
            lastPositionSeconds: 80,
            durationSeconds: 120,
            fileId: 123,
            thumbnailData: nil
        )

        let histories = try await repo.fetchAll()
        #expect(histories.count == 1)
        #expect(histories[0].filePath == "/newer/a.mp4")
        #expect(histories[0].lastPositionSeconds == 80)
        #expect(histories[0].fileId == 123)
    }

    @Test("UserDefaultsの視聴履歴上限が500なら100件を超えて保存できる")
    func upsert_respectsStoredWatchHistoryLimit() async throws {
        UserDefaults.standard.set(500, forKey: WatchHistoryLimitSettings.key)
        defer { UserDefaults.standard.removeObject(forKey: WatchHistoryLimitSettings.key) }

        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Schema([WatchHistory.self, RemoteConnection.self]),
            configurations: [configuration]
        )
        let repo = WatchHistoryRepositoryImpl(context: ModelContext(container))
        let connection = ModelFactory.makeConnection()
        let sourceID = ContentSource.remote(connection.id).id

        for index in 0..<120 {
            try await repo.upsert(
                sourceID: sourceID,
                connection: connection,
                filePath: "/videos/\(index).mp4",
                fileName: "\(index).mp4",
                lastPositionSeconds: 10,
                durationSeconds: 100,
                fileId: nil,
                thumbnailData: nil
            )
        }

        let histories = try await repo.fetchAll()
        #expect(histories.count == 120)
    }
}
