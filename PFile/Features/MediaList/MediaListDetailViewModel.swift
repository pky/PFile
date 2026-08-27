import Foundation
import UIKit

enum MediaListSortKey: String, CaseIterable {
    case name
    case size
    case addedAt
    case sourceCreatedAt

    var displayName: String {
        switch self {
        case .name: return "名前"
        case .size: return "サイズ"
        case .addedAt: return "追加順"
        case .sourceCreatedAt: return "元ファイル日時"
        }
    }
}

enum MediaListDateDisplayMode: String, CaseIterable {
    case addedAt
    case sourceCreatedAt

    var displayName: String {
        switch self {
        case .addedAt: return "リスト登録日時"
        case .sourceCreatedAt: return "元ファイル日時"
        }
    }

    func date(for file: MediaFile) -> Date? {
        switch self {
        case .addedAt:
            return file.addedAt
        case .sourceCreatedAt:
            return file.sourceCreatedAt
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
    var sortKey: MediaListSortKey = .addedAt {
        didSet { refreshFiles(reason: "sort_key") }
    }
    var sortOrder: SortOrder = .descending {
        didSet { refreshFiles(reason: "sort_order") }
    }
    var dateDisplayMode: MediaListDateDisplayMode = .addedAt

    private let repository: any MediaListRepository
    private let remoteConnectionRepository: (any RemoteConnectionRepository)?
    private let mediaThumbnailProvider: (any MediaThumbnailProviding)?
    private let thumbnailService: ThumbnailService?
    private let smbClientManager: SMBClientManager?
    private var thumbnailCacheObserver: ThumbnailCacheClearObserver?
    private static let sortKeyDefaultsKey = "MediaListDetail.sortKey"
    private static let sortOrderDefaultsKey = "MediaListDetail.sortOrder"
    private static let dateDisplayModeDefaultsKey = "MediaListDetail.dateDisplayMode"

    init(
        list: MediaList,
        repository: any MediaListRepository,
        remoteConnectionRepository: (any RemoteConnectionRepository)? = nil,
        mediaThumbnailProvider: (any MediaThumbnailProviding)? = nil,
        thumbnailService: ThumbnailService? = nil,
        smbClientManager: SMBClientManager? = nil
    ) {
        self.list = list
        self.repository = repository
        self.remoteConnectionRepository = remoteConnectionRepository
        self.mediaThumbnailProvider = mediaThumbnailProvider
        self.thumbnailService = thumbnailService
        self.smbClientManager = smbClientManager
        self.thumbnailCacheObserver = ThumbnailCacheClearObserver { [weak self] in
            self?.thumbnails.removeAll()
        }
        if let raw = UserDefaults.standard.string(forKey: Self.sortKeyDefaultsKey),
           let saved = MediaListSortKey(rawValue: raw) {
            sortKey = saved
        }
        if let raw = UserDefaults.standard.string(forKey: Self.sortOrderDefaultsKey),
           let saved = SortOrder(rawValue: raw) {
            sortOrder = saved
        }
        if let raw = UserDefaults.standard.string(forKey: Self.dateDisplayModeDefaultsKey),
           let saved = MediaListDateDisplayMode(rawValue: raw) {
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
        let sorted: [MediaFile]
        switch sortKey {
        case .name:
            sorted = files.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .size:
            sorted = files.sorted { ($0.fileSize ?? 0) < ($1.fileSize ?? 0) }
        case .addedAt:
            sorted = files.sorted { $0.addedAt < $1.addedAt }
        case .sourceCreatedAt:
            sorted = files.sorted {
                ($0.sourceCreatedAt ?? .distantPast) < ($1.sourceCreatedAt ?? .distantPast)
            }
        }
        return sortOrder == .ascending ? sorted : Array(sorted.reversed())
    }

}
