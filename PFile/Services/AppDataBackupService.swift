import Foundation
import SwiftData

// MARK: - Protocol

extension Notification.Name {
    static let appDataDidRestore = Notification.Name("appDataDidRestore")
}

struct AppDataBackupRestoreResult {
    let restoredFromURL: URL
    let preRestoreSnapshotURL: URL
}

@MainActor
protocol AppDataBackupServiceProtocol {
    var lastAutoBackupAt: Date? { get }
    func exportBackup() throws -> URL
    func restoreLatestBackup() throws -> AppDataBackupRestoreResult
    func restoreBackup(from url: URL) throws -> AppDataBackupRestoreResult
    func backupDirectoryURLForDisplay() throws -> URL
}

// MARK: - Implementation

@MainActor
final class AppDataBackupService: AppDataBackupServiceProtocol {

    private enum Keys {
        static let lastAutoBackupAt = "AppDataBackup.lastAutoBackupAt"
    }

    private let context: ModelContext
    private let smbClientManager: SMBClientManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let userDefaults: UserDefaults

    var lastAutoBackupAt: Date? {
        userDefaults.object(forKey: Keys.lastAutoBackupAt) as? Date
    }

    init(
        modelContainer: ModelContainer,
        smbClientManager: SMBClientManager,
        userDefaults: UserDefaults = .standard
    ) {
        self.context = modelContainer.mainContext
        self.smbClientManager = smbClientManager
        self.userDefaults = userDefaults

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func performAutoBackupIfNeeded() throws -> URL? {
        let now = Date()
        if let lastBackupAt = userDefaults.object(forKey: Keys.lastAutoBackupAt) as? Date,
           Calendar.current.isDate(lastBackupAt, inSameDayAs: now) {
            return nil
        }

        let url = try exportLatestOnlyBackup(filePrefix: "PFileBackup")
        userDefaults.set(now, forKey: Keys.lastAutoBackupAt)
        return url
    }

    func exportBackup() throws -> URL {
        try exportCurrentData(filePrefix: "PFileBackup", updateLatest: true)
    }

    func restoreLatestBackup() throws -> AppDataBackupRestoreResult {
        try restoreBackup(from: latestBackupURL())
    }

    func restoreBackup(from url: URL) throws -> AppDataBackupRestoreResult {
        let didAccessScopedResource = url.startAccessingSecurityScopedResource()
        defer {
            if didAccessScopedResource {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let data = try Data(contentsOf: url)
        let backup = try decoder.decode(AppDataBackup.self, from: data)
        let preRestoreSnapshotURL = try exportCurrentData(
            filePrefix: "PFileBackup-before-restore",
            updateLatest: false
        )

        try restore(from: backup)
        NotificationCenter.default.post(
            name: .appDataDidRestore,
            object: nil,
            userInfo: ["restoredFromURL": url]
        )
        return AppDataBackupRestoreResult(
            restoredFromURL: url,
            preRestoreSnapshotURL: preRestoreSnapshotURL
        )
    }

    func backupDirectoryURLForDisplay() throws -> URL {
        try backupDirectoryURL()
    }

    private func restore(from backup: AppDataBackup) throws {
        try deleteExistingData()

        var restoredConnectionsByID: [UUID: RemoteConnection] = [:]
        for connectionBackup in backup.connections {
            let connection = RemoteConnection(
                id: connectionBackup.id,
                displayName: connectionBackup.displayName,
                serviceType: connectionBackup.serviceType,
                host: connectionBackup.host,
                port: connectionBackup.port,
                username: connectionBackup.username,
                keychainIdentifier: connectionBackup.keychainIdentifier,
                startPath: connectionBackup.startPath
            )
            connection.createdAt = connectionBackup.createdAt
            connection.lastConnectedAt = connectionBackup.lastConnectedAt
            context.insert(connection)
            restoredConnectionsByID[connection.id] = connection

            if let credential = connectionBackup.credential {
                try KeychainService.shared.save(credential, key: connection.keychainIdentifier)
            }
        }

        for localFolderBackup in backup.localFolders {
            let localFolder = LocalFolderSource(
                id: localFolderBackup.id,
                displayName: localFolderBackup.displayName,
                bookmarkData: localFolderBackup.bookmarkData,
                createdAt: localFolderBackup.createdAt
            )
            context.insert(localFolder)
        }

        var fileIndex: [String: MediaFile] = [:]
        for listBackup in backup.lists.sorted(by: sortListsForRestore) {
            let list = MediaList(
                id: listBackup.id,
                name: listBackup.name,
                scopeID: listBackup.scopeID,
                sortOrder: listBackup.sortOrder,
                createdAt: listBackup.createdAt
            )
            context.insert(list)

            for fileBackup in listBackup.items {
                let key = mediaFileKey(
                    sourceID: fileBackup.sourceID ?? "",
                    connectionId: fileBackup.connectionId,
                    path: fileBackup.path,
                    fileId: fileBackup.fileId
                )
                let file: MediaFile
                if let existing = fileIndex[key] {
                    file = existing
                } else {
                    file = MediaFile(
                        id: fileBackup.id,
                        connectionId: fileBackup.connectionId,
                        sourceID: fileBackup.sourceID ?? "",
                        path: fileBackup.path,
                        name: fileBackup.name,
                        itemTypeRaw: fileBackup.itemTypeRaw,
                        fileId: fileBackup.fileId,
                        fileSize: fileBackup.fileSize,
                        addedAt: fileBackup.addedAt
                    )
                    context.insert(file)
                    fileIndex[key] = file
                }
                if !list.items.contains(where: { $0.id == file.id }) {
                    list.items.append(file)
                }
            }
        }

        for historyBackup in backup.watchHistories.sorted(by: { $0.watchedAt < $1.watchedAt }) {
            let history = WatchHistory(
                id: historyBackup.id,
                sourceID: historyBackup.sourceID ?? historyBackup.connectionID.map { ContentSource.remote($0).id } ?? "",
                connection: historyBackup.connectionID.flatMap { restoredConnectionsByID[$0] },
                filePath: historyBackup.filePath,
                fileName: historyBackup.fileName,
                lastPositionSeconds: historyBackup.lastPositionSeconds,
                durationSeconds: historyBackup.durationSeconds,
                fileId: historyBackup.fileId,
                thumbnailData: historyBackup.thumbnailData
            )
            history.watchedAt = historyBackup.watchedAt
            context.insert(history)
        }

        try context.save()
    }

    private func deleteExistingData() throws {
        for history in try context.fetch(FetchDescriptor<WatchHistory>()) {
            context.delete(history)
        }
        for list in try context.fetch(FetchDescriptor<MediaList>()) {
            context.delete(list)
        }
        for file in try context.fetch(FetchDescriptor<MediaFile>()) {
            context.delete(file)
        }
        for localFolder in try context.fetch(FetchDescriptor<LocalFolderSource>()) {
            context.delete(localFolder)
        }
        for connection in try context.fetch(FetchDescriptor<RemoteConnection>()) {
            KeychainService.shared.delete(key: connection.keychainIdentifier)
            context.delete(connection)
        }
        try context.save()
    }

    private func fetchConnections() throws -> [RemoteConnection] {
        try context.fetch(FetchDescriptor<RemoteConnection>(
            sortBy: [SortDescriptor(\.createdAt)]
        ))
    }

    private func fetchLocalFolders() -> [LocalFolderSource] {
        (try? context.fetch(FetchDescriptor<LocalFolderSource>(
            sortBy: [SortDescriptor(\.createdAt)]
        ))) ?? []
    }

    private func fetchLists() -> [MediaList] {
        (try? context.fetch(FetchDescriptor<MediaList>(
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.createdAt)]
        ))) ?? []
    }

    private func fetchWatchHistories() -> [WatchHistory] {
        (try? context.fetch(FetchDescriptor<WatchHistory>(
            sortBy: [SortDescriptor(\.watchedAt)]
        ))) ?? []
    }

    private func exportCurrentData(filePrefix: String, updateLatest: Bool) throws -> URL {
        let backup = try AppDataBackup(
            exportedAt: Date(),
            connections: try fetchConnections().map(makeConnectionBackup),
            localFolders: fetchLocalFolders().map(LocalFolderBackup.init),
            lists: fetchLists().map(makeMediaListBackup),
            watchHistories: fetchWatchHistories().compactMap(makeWatchHistoryBackup)
        )

        let data = try encoder.encode(backup)
        let directoryURL = try backupDirectoryURL()
        let timestamp = Self.fileNameDateFormatter.string(from: Date())
        let fileURL = directoryURL.appendingPathComponent("\(filePrefix)-\(timestamp).json")

        try data.write(to: fileURL, options: .atomic)

        if updateLatest {
            let latestURL = directoryURL.appendingPathComponent("PFileBackup-latest.json")
            try data.write(to: latestURL, options: .atomic)
        }

        return fileURL
    }

    private func exportLatestOnlyBackup(filePrefix: String) throws -> URL {
        let backup = try AppDataBackup(
            exportedAt: Date(),
            connections: try fetchConnections().map(makeConnectionBackup),
            localFolders: fetchLocalFolders().map(LocalFolderBackup.init),
            lists: fetchLists().map(makeMediaListBackup),
            watchHistories: fetchWatchHistories().compactMap(makeWatchHistoryBackup)
        )

        let data = try encoder.encode(backup)
        let latestURL = try backupDirectoryURL().appendingPathComponent("\(filePrefix)-latest.json")
        try data.write(to: latestURL, options: .atomic)
        return latestURL
    }

    private func makeConnectionBackup(_ connection: RemoteConnection) throws -> RemoteConnectionBackup {
        let credential = try? smbClientManager.loadCredential(for: connection)
        return RemoteConnectionBackup(
            id: connection.id,
            displayName: connection.displayName,
            serviceType: connection.serviceType,
            host: connection.host,
            port: connection.port,
            username: connection.username,
            keychainIdentifier: connection.keychainIdentifier,
            startPath: connection.startPath,
            createdAt: connection.createdAt,
            lastConnectedAt: connection.lastConnectedAt,
            credential: credential.map(ConnectionCredentialBackup.init)
        )
    }

    private func makeMediaListBackup(_ list: MediaList) -> MediaListBackup {
        MediaListBackup(
            id: list.id,
            name: list.name,
            scopeID: list.scopeID,
            sortOrder: list.sortOrder,
            createdAt: list.createdAt,
            items: list.items
                .sorted { $0.addedAt < $1.addedAt }
                .map(MediaFileBackup.init)
        )
    }

    private func makeWatchHistoryBackup(_ history: WatchHistory) -> WatchHistoryBackup? {
        WatchHistoryBackup(history: history, connectionID: history.connection?.id)
    }

    private func backupDirectoryURL() throws -> URL {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let directoryURL = documentsURL.appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }

    private func latestBackupURL() throws -> URL {
        let url = try backupDirectoryURL().appendingPathComponent("PFileBackup-latest.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AppDataBackupError.backupNotFound
        }
        return url
    }

    private func mediaFileKey(sourceID: String, connectionId: UUID, path: String, fileId: UInt64?) -> String {
        let normalizedSourceID = sourceID.isEmpty ? ContentSource.remote(connectionId).id : sourceID
        if let fileId {
            return "\(normalizedSourceID)|fid:\(fileId)"
        }
        return "\(normalizedSourceID)|path:\(path)"
    }

    private func sortListsForRestore(lhs: MediaListBackup, rhs: MediaListBackup) -> Bool {
        if lhs.scopeID == rhs.scopeID {
            if lhs.sortOrder == rhs.sortOrder {
                return lhs.createdAt < rhs.createdAt
            }
            return lhs.sortOrder < rhs.sortOrder
        }
        return lhs.scopeID < rhs.scopeID
    }

    private static let fileNameDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}

enum AppDataBackupError: LocalizedError {
    case backupNotFound

    var errorDescription: String? {
        switch self {
        case .backupNotFound:
            return "復元できるバックアップが見つかりません"
        }
    }
}

private struct AppDataBackup: Codable {
    let exportedAt: Date
    let connections: [RemoteConnectionBackup]
    let localFolders: [LocalFolderBackup]
    let lists: [MediaListBackup]
    let watchHistories: [WatchHistoryBackup]
}

private struct RemoteConnectionBackup: Codable {
    let id: UUID
    let displayName: String
    let serviceType: ServiceType
    let host: String?
    let port: Int?
    let username: String?
    let keychainIdentifier: String
    let startPath: String
    let createdAt: Date
    let lastConnectedAt: Date?
    let credential: ConnectionCredentialBackup?
}

private struct ConnectionCredentialBackup: Codable {
    let shareName: String
    let username: String
    let password: String

    init(_ credential: SMBClientManager.SMBCredential) {
        self.shareName = credential.shareName
        self.username = credential.username
        self.password = credential.password
    }
}

private struct LocalFolderBackup: Codable {
    let id: UUID
    let displayName: String
    let bookmarkData: Data
    let createdAt: Date

    init(_ localFolder: LocalFolderSource) {
        self.id = localFolder.id
        self.displayName = localFolder.displayName
        self.bookmarkData = localFolder.bookmarkData
        self.createdAt = localFolder.createdAt
    }
}

private struct MediaListBackup: Codable {
    let id: UUID
    let name: String
    let scopeID: String
    let sortOrder: Int
    let createdAt: Date
    let items: [MediaFileBackup]
}

private struct MediaFileBackup: Codable {
    let id: UUID
    let connectionId: UUID
    let sourceID: String?
    let path: String
    let name: String
    let itemTypeRaw: String
    let addedAt: Date
    let fileSize: Int64?
    let fileId: UInt64?

    init(_ file: MediaFile) {
        self.id = file.id
        self.connectionId = file.connectionId
        self.sourceID = file.sourceID
        self.path = file.path
        self.name = file.name
        self.itemTypeRaw = file.itemTypeRaw
        self.addedAt = file.addedAt
        self.fileSize = file.fileSize
        self.fileId = file.fileId
    }
}

private struct WatchHistoryBackup: Codable {
    let id: UUID
    let sourceID: String?
    let connectionID: UUID?
    let filePath: String
    let fileName: String
    let lastPositionSeconds: Double
    let durationSeconds: Double?
    let fileId: UInt64?
    let watchedAt: Date
    let thumbnailData: Data?

    init(history: WatchHistory, connectionID: UUID?) {
        self.id = history.id
        self.sourceID = history.sourceID
        self.connectionID = connectionID
        self.filePath = history.filePath
        self.fileName = history.fileName
        self.lastPositionSeconds = history.lastPositionSeconds
        self.durationSeconds = history.durationSeconds
        self.fileId = history.fileId
        self.watchedAt = history.watchedAt
        self.thumbnailData = history.thumbnailData
    }
}
