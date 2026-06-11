import Foundation

enum WatchHistoryLimitSettings {
    static let key = "Settings.watchHistoryLimit"
    static let defaultLimit = 100

    static var currentLimit: Int {
        UserDefaults.standard.object(forKey: key) as? Int ?? defaultLimit
    }

    static func save(_ limit: Int) {
        UserDefaults.standard.set(limit, forKey: key)
    }
}

@MainActor
protocol WatchHistoryRepository {
    func fetchAll() async throws -> [WatchHistory]
    func fetch(for connectionId: UUID) async throws -> [WatchHistory]
    func fetch(for sourceID: String) async throws -> [WatchHistory]
    func upsert(
        sourceID: String,
        connection: RemoteConnection?,
        filePath: String,
        fileName: String,
        lastPositionSeconds: Double,
        durationSeconds: Double?,
        fileId: UInt64?,
        thumbnailData: Data?
    ) async throws
    func fetchLastPosition(sourceID: String, filePath: String, fileId: UInt64?) async throws -> Double?
    func trim(to limit: Int) async throws
    func delete(_ history: WatchHistory) async throws
    func deleteAll() async throws
}
