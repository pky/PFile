import Foundation
import SwiftData

// MARK: - Protocol

extension Notification.Name {
    static let appDataDidRestore = Notification.Name("appDataDidRestore")
}

struct AppDataBackupRestoreResult {
    let restoredFromURL: URL
    let preRestoreSnapshotURL: URL
    let requiresCredentialReentry: Bool
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
    private let backupDirectoryOverride: URL?

    var lastAutoBackupAt: Date? {
        userDefaults.object(forKey: Keys.lastAutoBackupAt) as? Date
    }

    init(
        modelContainer: ModelContainer,
        smbClientManager: SMBClientManager,
        userDefaults: UserDefaults = .standard,
        backupDirectoryURL: URL? = nil
    ) {
        self.context = modelContainer.mainContext
        self.smbClientManager = smbClientManager
        self.userDefaults = userDefaults
        self.backupDirectoryOverride = backupDirectoryURL

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func performAutoBackupIfNeeded() throws -> URL? {
        try sanitizeStoredBackups()

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
        try sanitizeStoredBackups()
        return try exportCurrentData(filePrefix: "PFileBackup", updateLatest: true)
    }

    func restoreLatestBackup() throws -> AppDataBackupRestoreResult {
        try sanitizeStoredBackups()
        return try restoreBackup(from: latestBackupURL())
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
            preRestoreSnapshotURL: preRestoreSnapshotURL,
            requiresCredentialReentry: !backup.connections.isEmpty
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
                // 認証情報はバックアップしないため、共有名を編集画面で再入力できる形に退避する。
                startPath: connectionBackup.pathForCredentialReentry
            )
            connection.createdAt = connectionBackup.createdAt
            connection.lastConnectedAt = connectionBackup.lastConnectedAt
            context.insert(connection)
            restoredConnectionsByID[connection.id] = connection
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
                        addedAt: fileBackup.addedAt,
                        sourceCreatedAt: fileBackup.sourceCreatedAt,
                        sourceModifiedAt: fileBackup.sourceModifiedAt
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
        let backup = AppDataBackup(
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
        let backup = AppDataBackup(
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
            shareName: credential?.shareName,
            startPath: connection.startPath,
            createdAt: connection.createdAt,
            lastConnectedAt: connection.lastConnectedAt
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
        if let backupDirectoryOverride {
            try FileManager.default.createDirectory(
                at: backupDirectoryOverride,
                withIntermediateDirectories: true
            )
            return backupDirectoryOverride
        }

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

    /// 旧バージョンが生成した端末内バックアップから平文の認証情報を除去する。
    /// 共有名は再入力を助けるため非機密フィールドとして残す。
    private func sanitizeStoredBackups() throws {
        let directoryURL = try backupDirectoryURL()
        let fileURLs = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        ).filter {
            $0.pathExtension.lowercased() == "json"
                && $0.lastPathComponent.hasPrefix("PFileBackup")
        }

        for fileURL in fileURLs {
            let data = try Data(contentsOf: fileURL)
            guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  var connections = root["connections"] as? [[String: Any]] else {
                continue
            }

            var didRemoveCredential = false
            for index in connections.indices {
                guard let credential = connections[index]["credential"] as? [String: Any] else {
                    continue
                }
                if connections[index]["shareName"] == nil,
                   let shareName = credential["shareName"] as? String {
                    connections[index]["shareName"] = shareName
                }
                connections[index].removeValue(forKey: "credential")
                didRemoveCredential = true
            }

            guard didRemoveCredential else { continue }
            root["connections"] = connections
            let sanitizedData = try JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys]
            )
            try sanitizedData.write(to: fileURL, options: .atomic)
        }
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
    let shareName: String?
    let startPath: String
    let createdAt: Date
    let lastConnectedAt: Date?

    var pathForCredentialReentry: String {
        let components = [shareName, startPath]
            .compactMap { $0 }
            .flatMap { $0.split(separator: "/").map(String.init) }
        return components.isEmpty ? "/" : "/" + components.joined(separator: "/")
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case serviceType
        case host
        case port
        case username
        case keychainIdentifier
        case shareName
        case startPath
        case createdAt
        case lastConnectedAt
        case credential
    }

    init(
        id: UUID,
        displayName: String,
        serviceType: ServiceType,
        host: String?,
        port: Int?,
        username: String?,
        keychainIdentifier: String,
        shareName: String?,
        startPath: String,
        createdAt: Date,
        lastConnectedAt: Date?
    ) {
        self.id = id
        self.displayName = displayName
        self.serviceType = serviceType
        self.host = host
        self.port = port
        self.username = username
        self.keychainIdentifier = keychainIdentifier
        self.shareName = shareName
        self.startPath = startPath
        self.createdAt = createdAt
        self.lastConnectedAt = lastConnectedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        serviceType = try container.decode(ServiceType.self, forKey: .serviceType)
        host = try container.decodeIfPresent(String.self, forKey: .host)
        port = try container.decodeIfPresent(Int.self, forKey: .port)
        username = try container.decodeIfPresent(String.self, forKey: .username)
        keychainIdentifier = try container.decode(String.self, forKey: .keychainIdentifier)
        startPath = try container.decode(String.self, forKey: .startPath)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        lastConnectedAt = try container.decodeIfPresent(Date.self, forKey: .lastConnectedAt)

        let legacyCredential = try container.decodeIfPresent(
            LegacyConnectionCredentialBackup.self,
            forKey: .credential
        )
        shareName = try container.decodeIfPresent(String.self, forKey: .shareName)
            ?? legacyCredential?.shareName
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(serviceType, forKey: .serviceType)
        try container.encodeIfPresent(host, forKey: .host)
        try container.encodeIfPresent(port, forKey: .port)
        try container.encodeIfPresent(username, forKey: .username)
        try container.encode(keychainIdentifier, forKey: .keychainIdentifier)
        try container.encodeIfPresent(shareName, forKey: .shareName)
        try container.encode(startPath, forKey: .startPath)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(lastConnectedAt, forKey: .lastConnectedAt)
        // credential は旧バックアップの読み込み専用。認証情報は絶対に出力しない。
    }
}

private struct LegacyConnectionCredentialBackup: Decodable {
    let shareName: String
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
    let sourceCreatedAt: Date?
    let sourceModifiedAt: Date?
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
        self.sourceCreatedAt = file.sourceCreatedAt
        self.sourceModifiedAt = file.sourceModifiedAt
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
