import Foundation
import UIKit

enum MediaListSortKey: String, CaseIterable {
    case name
    case size
    case modifiedAt
    case createdAt
    case listAddedAt

    var displayName: String {
        switch self {
        case .listAddedAt: return "リスト登録日時"
        default: return fileSortKey?.displayName ?? rawValue
        }
    }

    /// ブラウズと共通のソートキー。リスト登録日時だけはリスト固有の並び順
    var fileSortKey: SortKey? {
        switch self {
        case .name: return .name
        case .size: return .size
        case .modifiedAt: return .modifiedAt
        case .createdAt: return .createdAt
        case .listAddedAt: return nil
        }
    }

    /// 旧バージョンで保存した設定値を現在のキーへ読み替える
    init?(persistedRawValue: String) {
        switch persistedRawValue {
        case "addedAt": self = .listAddedAt
        case "sourceCreatedAt": self = .createdAt
        default: self.init(rawValue: persistedRawValue)
        }
    }
}

enum MediaListDateDisplayMode: String, CaseIterable {
    case modifiedAt
    case createdAt
    case listAddedAt

    var displayName: String {
        switch self {
        case .modifiedAt: return SortKey.modifiedAt.displayName
        case .createdAt: return SortKey.createdAt.displayName
        case .listAddedAt: return "リスト登録日時"
        }
    }

    /// 旧バージョンで保存した設定値を現在のモードへ読み替える
    init?(persistedRawValue: String) {
        switch persistedRawValue {
        case "addedAt": self = .listAddedAt
        case "sourceCreatedAt": self = .createdAt
        default: self.init(rawValue: persistedRawValue)
        }
    }

    func date(for file: MediaFile) -> Date? {
        switch self {
        case .modifiedAt:
            return file.sourceModifiedAt
        case .createdAt:
            return file.sourceCreatedAt
        case .listAddedAt:
            return file.addedAt
        }
    }
}

@Observable
@MainActor
final class MediaListDetailViewModel {

    let list: MediaList
    private(set) var files: [MediaFile] = []
    var isLoading = false
    var errorMessage: String?
    private(set) var thumbnails: [String: UIImage] = [:]
    private(set) var connections: [UUID: RemoteConnection] = [:]
    private(set) var fileSortCount = 0
    var sortKey: MediaListSortKey = .listAddedAt {
        didSet { refreshFiles(reason: "sort_key") }
    }
    var sortOrder: SortOrder = .descending {
        didSet { refreshFiles(reason: "sort_order") }
    }
    var dateDisplayMode: MediaListDateDisplayMode = .listAddedAt

    private let repository: any MediaListRepository
    private let remoteConnectionRepository: (any RemoteConnectionRepository)?
    private let mediaThumbnailProvider: (any MediaThumbnailProviding)?
    private let thumbnailService: ThumbnailService?
    private let smbClientManager: SMBClientManager?
    private let fileRepositoryFactory: (RemoteConnection) -> (any FileRepository)?
    private let sortService = SortService()
    private var thumbnailCacheObserver: ThumbnailCacheClearObserver?
    private var thumbnailUpdateObserver: ThumbnailUpdateObserver?
    private static let sortKeyDefaultsKey = "MediaListDetail.sortKey"
    private static let sortOrderDefaultsKey = "MediaListDetail.sortOrder"
    private static let dateDisplayModeDefaultsKey = "MediaListDetail.dateDisplayMode"

    init(
        list: MediaList,
        repository: any MediaListRepository,
        remoteConnectionRepository: (any RemoteConnectionRepository)? = nil,
        mediaThumbnailProvider: (any MediaThumbnailProviding)? = nil,
        thumbnailService: ThumbnailService? = nil,
        smbClientManager: SMBClientManager? = nil,
        fileRepositoryFactory: ((RemoteConnection) -> (any FileRepository)?)? = nil
    ) {
        self.list = list
        self.repository = repository
        self.remoteConnectionRepository = remoteConnectionRepository
        self.mediaThumbnailProvider = mediaThumbnailProvider
        self.thumbnailService = thumbnailService
        self.smbClientManager = smbClientManager
        self.fileRepositoryFactory = fileRepositoryFactory ?? { connection in
            guard let smbClientManager, connection.serviceType == .smb else { return nil }
            return try? SMBFileRepository(connection: connection, clientManager: smbClientManager)
        }
        self.thumbnailCacheObserver = ThumbnailCacheClearObserver { [weak self] in
            self?.thumbnails.removeAll()
        }
        self.thumbnailUpdateObserver = ThumbnailUpdateObserver { [weak self] key, image in
            guard let self, self.thumbnails[key] != nil else { return }
            self.thumbnails[key] = image
        }
        if let raw = UserDefaults.standard.string(forKey: Self.sortKeyDefaultsKey),
           let saved = MediaListSortKey(persistedRawValue: raw) {
            sortKey = saved
        }
        if let raw = UserDefaults.standard.string(forKey: Self.sortOrderDefaultsKey),
           let saved = SortOrder(rawValue: raw) {
            sortOrder = saved
        }
        if let raw = UserDefaults.standard.string(forKey: Self.dateDisplayModeDefaultsKey),
           let saved = MediaListDateDisplayMode(persistedRawValue: raw) {
            dateDisplayMode = saved
        }
        refreshFiles(reason: "init")
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        if let repo = remoteConnectionRepository,
           let all = try? await repo.fetchAll() {
            connections = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        }
        refreshFiles(reason: "load")
        await backfillSourceModifiedDates()
    }

    /// 更新日時を持たない登録済み項目を親フォルダの一覧から補完する。
    /// 旧バージョンで登録した項目でもブラウズと同じ更新日時順に並ぶようにする。
    private func backfillSourceModifiedDates() async {
        let targets = list.items.filter { $0.sourceModifiedAt == nil }
        guard !targets.isEmpty else { return }

        let grouped = Dictionary(grouping: targets) { file in
            "\(file.sourceID)|\((file.path as NSString).deletingLastPathComponent)"
        }
        var didUpdate = false
        for files in grouped.values {
            guard let first = files.first,
                  let connection = sourceConnection(for: first),
                  let fileRepository = fileRepositoryFactory(connection) else { continue }
            let directory = (first.path as NSString).deletingLastPathComponent
            guard let items = try? await fileRepository.listDirectory(at: directory) else { continue }
            let matched = items.filter { item in
                item.modifiedAt != nil && files.contains { file in
                    if let fileId = file.fileId, fileId > 0 {
                        return item.fileId == fileId
                    }
                    return item.path == file.path
                }
            }
            guard !matched.isEmpty else { continue }
            try? await repository.addItems(matched, sourceID: first.sourceID, to: list)
            didUpdate = true
        }
        if didUpdate {
            refreshFiles(reason: "source_dates_backfilled")
        }
    }

    func removeFile(_ file: MediaFile) async {
        do {
            try await repository.removeFile(file, from: list)
            refreshFiles(reason: "remove")
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeFiles(_ files: [MediaFile]) async {
        do {
            for file in files {
                try await repository.removeFile(file, from: list)
            }
            refreshFiles(reason: "remove_multiple")
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Thumbnail

    func thumbnail(for file: MediaFile) -> UIImage? {
        let key = cacheKey(for: file)
        if let img = thumbnails[key] { return img }
        if let mediaThumbnailProvider,
           let img = mediaThumbnailProvider.thumbnail(for: source(for: file), item: file.toDirectoryItem()) {
            thumbnails[key] = img
            return img
        }
        return nil
    }

    func loadThumbnail(for file: MediaFile) async {
        guard !Task.isCancelled else { return }
        let key = cacheKey(for: file)
        guard thumbnails[key] == nil, let mediaThumbnailProvider else { return }
        let item = file.toDirectoryItem()
        let connection = sourceConnection(for: file)
        guard let img = await mediaThumbnailProvider.loadThumbnail(
            for: source(for: file),
            item: item,
            connection: connection
        ) else { return }
        guard !Task.isCancelled else { return }
        thumbnails[key] = img
    }

    func canChooseThumbnail(for file: MediaFile) -> Bool {
        file.itemTypeRaw == "video"
            && sourceConnection(for: file) != nil
            && thumbnailService != nil
            && smbClientManager != nil
    }

    func generateThumbnailChoices(
        for file: MediaFile,
        progress: @escaping ThumbnailChoiceProgressHandler = { _, _ in }
    ) async -> [UIImage] {
        guard canChooseThumbnail(for: file),
              let connection = sourceConnection(for: file),
              let thumbnailService,
              let smbClientManager else { return [] }
        return await thumbnailService.generateVideoThumbnailChoices(
            for: file.toDirectoryItem(),
            connection: connection,
            smbClientManager: smbClientManager,
            progress: progress
        )
    }

    func generateThumbnailPreview(for file: MediaFile, position: Float) async -> UIImage? {
        guard let connection = sourceConnection(for: file),
              let thumbnailService,
              let smbClientManager else { return nil }
        return await thumbnailService.generateVideoThumbnailPreview(
            for: file.toDirectoryItem(),
            connection: connection,
            smbClientManager: smbClientManager,
            position: position
        )
    }

    func selectThumbnail(_ image: UIImage, for file: MediaFile) {
        let key = cacheKey(for: file)
        thumbnails[key] = thumbnailService?.store(image, for: key) ?? image
    }

    func applySortChange() {
        UserDefaults.standard.set(sortKey.rawValue, forKey: Self.sortKeyDefaultsKey)
        UserDefaults.standard.set(sortOrder.rawValue, forKey: Self.sortOrderDefaultsKey)
        UserDefaults.standard.set(dateDisplayMode.rawValue, forKey: Self.dateDisplayModeDefaultsKey)
    }

    func refreshFiles(reason: String = "items_changed") {
        let startedAt = CFAbsoluteTimeGetCurrent()
        files = sortFiles(list.items)
        fileSortCount += 1
#if DEBUG
        MediaDiagnostics.performance(
            "event=media_list_sorted sequence=\(fileSortCount) count=\(files.count) elapsedMs=\(Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)) reason=\(reason)"
        )
#endif
    }

    /// 再生開始前に、リスト内で移動済みの動画をfileIdからまとめて復元する。
    /// スライド遷移で次の動画だけ古いパスのまま残らないようにする。
    func resolvePlayableFile(_ file: MediaFile, smbClientManager: SMBClientManager) async -> MediaFile {
        guard let connection = sourceConnection(for: file),
              connection.serviceType == .smb else {
            return file
        }

        do {
            let repo = try SMBFileRepository(connection: connection, clientManager: smbClientManager)
            let candidates = files.filter {
                $0.sourceID == file.sourceID && ($0.fileId ?? 0) > 0
            }
            var missingFileIDs = Set<UInt64>()
            for candidate in candidates {
                let exists = try await repo.fileExists(at: candidate.path)
                if !exists, let fileId = candidate.fileId {
                    missingFileIDs.insert(fileId)
                }
            }

            guard !missingFileIDs.isEmpty else { return file }
            let resolvedItems = try await repo.findMediaItemsRecursively(
                at: connection.startPath,
                matchingFileIDs: missingFileIDs
            )
            guard !resolvedItems.isEmpty else { return file }

            try await repository.addItems(
                Array(resolvedItems.values),
                sourceID: file.sourceID,
                to: list
            )
            refreshFiles(reason: "paths_resolved")
            errorMessage = nil
            return list.items.first(where: { $0.id == file.id }) ?? file
        } catch {
            errorMessage = error.localizedDescription
            return file
        }
    }

    private func cacheKey(for file: MediaFile) -> String {
        let item = file.toDirectoryItem()
        return mediaThumbnailProvider?.cacheKey(source: source(for: file), item: item)
            ?? "\(file.sourceID)/\(file.path)"
    }

    private func source(for file: MediaFile) -> ContentSource {
        ContentSource.from(id: file.sourceID) ?? .remote(file.connectionId)
    }

    func sourceConnection(for file: MediaFile) -> RemoteConnection? {
        if let connection = connections[file.connectionId] {
            return connection
        }
        guard file.sourceID.hasPrefix("remote:") else { return nil }
        let rawID = String(file.sourceID.dropFirst("remote:".count))
        guard let uuid = UUID(uuidString: rawID) else { return nil }
        return connections[uuid]
    }

    private func sortFiles(_ files: [MediaFile]) -> [MediaFile] {
        if let fileSortKey = sortKey.fileSortKey {
            return sortService.sortFiles(files, by: fileSortKey, order: sortOrder)
        }
        let sorted = files.sorted { $0.addedAt < $1.addedAt }
        return sortOrder == .ascending ? sorted : Array(sorted.reversed())
    }

}
