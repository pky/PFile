import Foundation
import UIKit

@Observable
@MainActor
final class FileBrowserViewModel {

    var items: [DirectoryItem] = []
    var currentPath: String
    var isLoading = false
    var errorMessage: String?
    var sortKey: SortKey = .name
    var sortOrder: SortOrder = .ascending
    /// 取得済みサムネイル。変更が @Observable 経由で View に伝わる
    var thumbnails: [String: UIImage] = [:]

    // MARK: - 複数選択
    var isSelectMode = false
    var selectedPaths: Set<String> = []

    // MARK: - フィルター
    var showUnregisteredOnly = false {
        didSet {
            UserDefaults.standard.set(showUnregisteredOnly, forKey: Self.showUnregisteredOnlyKey)
        }
    }
    var registeredPaths: Set<String> = []
    var registeredFileIds: Set<UInt64> = []

    // MARK: - フォルダ優先
    var foldersFirst = false {
        didSet {
            UserDefaults.standard.set(foldersFirst, forKey: Self.foldersFirstKey)
        }
    }

    var filteredItems: [DirectoryItem] {
        let baseItems: [DirectoryItem]
        if showUnregisteredOnly {
            baseItems = items.filter { $0.isDirectory || !isRegistered($0) }
        } else {
            baseItems = items
        }
        return baseItems
    }

    private let connection: RemoteConnection
    private let fileRepository: any FileRepository
    private let sortService = SortService()
    private let mediaThumbnailProvider: (any MediaThumbnailProviding)?
    private let thumbnailService: ThumbnailService?
    private let smbClientManager: SMBClientManager?
    private let mediaListRepository: (any MediaListRepository)?
    private let reconnectHandler: (() -> Void)?
    private var warmUpTask: Task<Void, Never>?
    private var thumbnailCacheObserver: ThumbnailCacheClearObserver?
    private var isNetworkWorkSuspended = false

    private static let sortKeyDefaultsKey        = "FileBrowser.sortKey"
    private static let sortOrderDefaultsKey      = "FileBrowser.sortOrder"
    private static let showUnregisteredOnlyKey   = "FileBrowser.showUnregisteredOnly"
    private static let foldersFirstKey           = "FileBrowser.foldersFirst"

    var listRegistrationFileRepository: any FileRepository {
        fileRepository
    }

    var breadcrumbs: [String] {
        let base = connection.startPath == "/" ? "" : connection.startPath
        let relative = currentPath.hasPrefix(base) ? String(currentPath.dropFirst(base.count)) : currentPath
        return relative.split(separator: "/").map(String.init)
    }

    init(
        connection: RemoteConnection,
        fileRepository: any FileRepository,
        mediaThumbnailProvider: (any MediaThumbnailProviding)? = nil,
        thumbnailService: ThumbnailService? = nil,
        smbClientManager: SMBClientManager? = nil,
        mediaListRepository: (any MediaListRepository)? = nil,
        reconnectHandler: (() -> Void)? = nil,
        startPath: String? = nil
    ) {
        self.connection = connection
        self.fileRepository = fileRepository
        self.mediaThumbnailProvider = mediaThumbnailProvider
        self.thumbnailService = thumbnailService
        self.smbClientManager = smbClientManager
        self.mediaListRepository = mediaListRepository
        self.reconnectHandler = reconnectHandler ?? smbClientManager.map { manager in
            { manager.disconnect(for: connection.id) }
        }
        self.currentPath = startPath ?? connection.startPath
        self.thumbnailCacheObserver = ThumbnailCacheClearObserver { [weak self] in
            self?.thumbnails.removeAll()
        }

        if let raw = UserDefaults.standard.string(forKey: Self.sortKeyDefaultsKey),
           let key = SortKey(rawValue: raw) { self.sortKey = key }
        if let raw = UserDefaults.standard.string(forKey: Self.sortOrderDefaultsKey),
           let order = SortOrder(rawValue: raw) { self.sortOrder = order }
        self.showUnregisteredOnly = UserDefaults.standard.bool(forKey: Self.showUnregisteredOnlyKey)
        self.foldersFirst = UserDefaults.standard.bool(forKey: Self.foldersFirstKey)
    }

    // MARK: - ディレクトリ操作

    func loadDirectory() async {
        isNetworkWorkSuspended = false
        isLoading = true
        defer { isLoading = false }
        do {
            let fetched = try await fileRepository.listDirectory(at: currentPath)
            items = sortService.sort(fetched, by: sortKey, order: sortOrder, foldersFirst: foldersFirst)
            errorMessage = nil
            startVideoFileWarmUp()
        } catch {
            items = []
            errorMessage = error.localizedDescription
        }
    }

    func navigate(to item: DirectoryItem) async {
        guard item.isDirectory else { return }
        currentPath = item.path
        await loadDirectory()
    }

    func reconnect() async {
        reconnectHandler?()
        await loadDirectory()
    }

    @discardableResult
    func refreshConnectionIfNeeded(forceReconnect: Bool = false) async -> Bool {
        if forceReconnect {
            reconnectHandler?()
        }
        await loadDirectory()
        return errorMessage == nil
    }

    func prepareForBackground() {
        isNetworkWorkSuspended = true
        warmUpTask?.cancel()
        warmUpTask = nil
        reconnectHandler?()
    }

    /// タブへ戻ったとき、表示セルのサムネイル生成を再開可能にする。
    func resumeNetworkWork() {
        guard isNetworkWorkSuspended else { return }
        isNetworkWorkSuspended = false
        startVideoFileWarmUp()
    }

    func applySortChange() async {
        UserDefaults.standard.set(sortKey.rawValue, forKey: Self.sortKeyDefaultsKey)
        UserDefaults.standard.set(sortOrder.rawValue, forKey: Self.sortOrderDefaultsKey)
        items = sortService.sort(items, by: sortKey, order: sortOrder, foldersFirst: foldersFirst)
    }

    // MARK: - サムネイル

    /// メモリキャッシュから取得済みサムネイルを返す
    func thumbnail(for item: DirectoryItem) -> UIImage? {
        thumbnails[cacheKey(for: item)]
    }

    /// サムネイルを非同期でロードし thumbnails に反映する
    func loadThumbnail(for item: DirectoryItem) async {
        guard !Task.isCancelled else { return }
        let key = cacheKey(for: item)

        // すでに取得済みならスキップ
        if thumbnails[key] != nil { return }

        if let mediaThumbnailProvider,
           let cached = mediaThumbnailProvider.thumbnail(for: .remote(connection.id), item: item) {
            thumbnails[key] = cached
            return
        }

        guard !isNetworkWorkSuspended else { return }

        if let mediaThumbnailProvider,
           let image = await mediaThumbnailProvider.loadThumbnail(
            for: .remote(connection.id),
            item: item,
            connection: connection
           ) {
            guard !Task.isCancelled, !isNetworkWorkSuspended else { return }
            thumbnails[key] = image
            return
        }

        // Provider が存在する場合は同じ ThumbnailService を再度呼ばない。
        if mediaThumbnailProvider != nil { return }

        guard item.isVideo,
              let thumbnailService,
              let smbClientManager else { return }

        if let cached = thumbnailService.thumbnail(for: key) {
            thumbnails[key] = cached
            return
        }

        if let image = await thumbnailService.generateVideoThumbnail(
            for: item,
            connection: connection,
            smbClientManager: smbClientManager
        ) {
            guard !Task.isCancelled, !isNetworkWorkSuspended else { return }
            thumbnails[key] = image
        }
    }

    /// 指定した動画1本から、ユーザーが選べるサムネイル候補を生成する。
    func generateThumbnailChoices(
        for item: DirectoryItem,
        progress: @escaping ThumbnailChoiceProgressHandler = { _, _ in }
    ) async -> [UIImage] {
        guard item.isVideo,
              !isNetworkWorkSuspended,
              let thumbnailService,
              let smbClientManager else { return [] }
        return await thumbnailService.generateVideoThumbnailChoices(
            for: item,
            connection: connection,
            smbClientManager: smbClientManager,
            progress: progress
        )
    }

    /// 選択した画像を共有キャッシュと現在の表示へ反映する。
    func selectThumbnail(_ image: UIImage, for item: DirectoryItem) {
        let key = cacheKey(for: item)
        thumbnailService?.store(image, for: key)
        thumbnails[key] = image
    }

    private func startVideoFileWarmUp() {
        warmUpTask?.cancel()
        warmUpTask = nil
        guard !isNetworkWorkSuspended,
              let smbClientManager else { return }

        warmUpTask = Task {
            if let firstVideo = items.first(where: { $0.isVideo }) {
                try? await smbClientManager.warmUpFile(for: connection, at: firstVideo.path)
                return
            }

            if let firstFile = items.first(where: { !$0.isDirectory }) {
                try? await smbClientManager.warmUpFile(for: connection, at: firstFile.path)
                return
            }

            try? await smbClientManager.warmUpFirstReadableFile(for: connection, at: currentPath)
        }
    }

    private func cacheKey(for item: DirectoryItem) -> String {
        mediaThumbnailProvider?.cacheKey(source: .remote(connection.id), item: item)
            ?? "\(connection.id.uuidString)/\(item.path)"
    }

    // MARK: - 選択モード

    func toggleSelectMode() {
        isSelectMode.toggle()
        if !isSelectMode { selectedPaths.removeAll() }
    }

    func toggleSelection(for item: DirectoryItem) {
        if selectedPaths.contains(item.path) {
            selectedPaths.remove(item.path)
        } else {
            selectedPaths.insert(item.path)
        }
    }

    func clearSelection() {
        selectedPaths.removeAll()
    }

    var selectedItems: [DirectoryItem] {
        items.filter { selectedPaths.contains($0.path) }
    }

    // MARK: - フィルター

    func loadRegisteredPaths() async {
        guard let mediaListRepository else { return }
        do {
            let refs = try await mediaListRepository.registeredReferences(for: connection.id)
            registeredPaths = Set(refs.map(\.path))
            registeredFileIds = Set(refs.compactMap(\.fileId))
        } catch {
            // フィルター取得失敗は無視
        }
    }

    private func isRegistered(_ item: DirectoryItem) -> Bool {
        if registeredPaths.contains(item.path) {
            return true
        }
        if let fileId = item.fileId, fileId > 0, registeredFileIds.contains(fileId) {
            return true
        }
        return false
    }

}
