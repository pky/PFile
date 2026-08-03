@testable import PFile
import Foundation
import Testing
import UIKit

@MainActor
struct FileBrowserViewModelTests {

    @Test("自動サムネイル再試行は3回で打ち切る")
    func automaticThumbnailRetryPolicy_limitsRetryCount() {
        #expect(AutomaticThumbnailRetryPolicy.delay(forAttempt: 0) != nil)
        #expect(AutomaticThumbnailRetryPolicy.delay(forAttempt: 1) != nil)
        #expect(AutomaticThumbnailRetryPolicy.delay(forAttempt: 2) != nil)
        #expect(AutomaticThumbnailRetryPolicy.delay(forAttempt: 3) == nil)
    }

    private func makeViewModel(items: [DirectoryItem] = []) -> (FileBrowserViewModel, MockFileRepository) {
        let repo = MockFileRepository()
        repo.items = items
        let connection = ModelFactory.makeConnection()
        let vm = FileBrowserViewModel(connection: connection, fileRepository: repo)
        return (vm, repo)
    }

    // MARK: - loadDirectory

    @Test("ディレクトリの内容を正常に取得できる")
    func loadDirectory_success() async {
        let items = ModelFactory.makeDirectoryItems()
        let (vm, _) = makeViewModel(items: items)

        await vm.loadDirectory()

        #expect(vm.items.count == items.count)
        #expect(vm.errorMessage == nil)
        #expect(vm.isLoading == false)
    }

    @Test("取得エラー時に errorMessage がセットされる")
    func loadDirectory_error() async {
        let (vm, repo) = makeViewModel()
        repo.shouldThrow = true

        await vm.loadDirectory()

        #expect(vm.items.isEmpty)
        #expect(vm.errorMessage != nil)
    }

    @Test("再接続でハンドラ実行後に再読込できる")
    func reconnect_runsHandlerAndReloads() async {
        let repo = MockFileRepository()
        repo.items = ModelFactory.makeDirectoryItems()
        let connection = ModelFactory.makeConnection()
        var reconnectCount = 0
        let vm = FileBrowserViewModel(
            connection: connection,
            fileRepository: repo,
            reconnectHandler: { reconnectCount += 1 }
        )

        await vm.reconnect()

        #expect(reconnectCount == 1)
        #expect(vm.items.count == repo.items.count)
        #expect(vm.errorMessage == nil)
    }

    @Test("接続再確認が成功した場合は true を返す")
    func refreshConnectionIfNeeded_success() async {
        let items = ModelFactory.makeDirectoryItems()
        let (vm, _) = makeViewModel(items: items)

        let result = await vm.refreshConnectionIfNeeded()

        #expect(result == true)
        #expect(vm.items.count == items.count)
        #expect(vm.errorMessage == nil)
    }

    @Test("接続再確認が失敗した場合は false を返す")
    func refreshConnectionIfNeeded_failure() async {
        let (vm, repo) = makeViewModel()
        repo.shouldThrow = true

        let result = await vm.refreshConnectionIfNeeded()

        #expect(result == false)
        #expect(vm.errorMessage != nil)
    }

    @Test("リスト未登録のみは fileId 一致の移動済み動画を除外する")
    func showUnregisteredOnly_excludesMovedRegisteredItemByFileId() async {
        let connection = ModelFactory.makeConnection()
        let repo = MockFileRepository()
        repo.items = [
            DirectoryItem(
                name: "movie.mp4",
                path: "/new/movie.mp4",
                itemType: .video,
                size: nil,
                modifiedAt: nil,
                createdAt: nil,
                fileId: 42
            ),
            DirectoryItem(
                name: "other.mp4",
                path: "/other.mp4",
                itemType: .video,
                size: nil,
                modifiedAt: nil,
                createdAt: nil,
                fileId: 99
            ),
        ]
        let mediaListRepo = MockMediaListRepository()
        mediaListRepo.files = [
            MediaFile(
                connectionId: connection.id,
                sourceID: ContentSource.remote(connection.id).id,
                path: "/old/movie.mp4",
                name: "movie.mp4",
                itemTypeRaw: "video",
                fileId: 42
            )
        ]
        let vm = FileBrowserViewModel(
            connection: connection,
            fileRepository: repo,
            mediaListRepository: mediaListRepo
        )

        await vm.loadDirectory()
        await vm.loadRegisteredPaths()
        vm.showUnregisteredOnly = true

        #expect(vm.filteredItems.map(\.path) == ["/other.mp4"])
    }

    // MARK: - navigate

    @Test("ディレクトリに移動すると currentPath が更新される")
    func navigate_toDirectory() async {
        let dir = DirectoryItem(name: "Movies", path: "/Movies", itemType: .directory, size: nil, modifiedAt: nil, createdAt: nil)
        let (vm, repo) = makeViewModel(items: [dir])
        repo.items = []

        await vm.navigate(to: dir)

        #expect(vm.currentPath == "/Movies")
    }

    @Test("ファイルに navigate しても currentPath は変わらない")
    func navigate_toFile_noChange() async {
        let file = DirectoryItem(name: "movie.mp4", path: "/movie.mp4", itemType: .video, size: nil, modifiedAt: nil, createdAt: nil)
        let (vm, _) = makeViewModel(items: [file])
        let originalPath = vm.currentPath

        await vm.navigate(to: file)

        #expect(vm.currentPath == originalPath)
    }

    // MARK: - thumbnail

    @Test("ブラウズはキャッシュ未命中時にサムネイル生成を試みる")
    func loadThumbnail_remoteBrowse_callsProviderLoad() async {
        let connection = ModelFactory.makeConnection()
        let repo = MockFileRepository()
        let provider = MockMediaThumbnailProvider()
        let item = DirectoryItem(
            name: "movie.mp4",
            path: "/movie.mp4",
            itemType: .video,
            size: nil,
            modifiedAt: nil,
            createdAt: nil
        )
        let vm = FileBrowserViewModel(
            connection: connection,
            fileRepository: repo,
            mediaThumbnailProvider: provider
        )

        await vm.loadThumbnail(for: item)

        #expect(provider.cacheCalls.map(\.itemPath) == ["/movie.mp4"])
        #expect(provider.loadCalls.count == 1)
        #expect(provider.loadCalls.first?.source.id == ContentSource.remote(connection.id).id)
        #expect(provider.loadCalls.first?.itemPath == "/movie.mp4")
        #expect(provider.loadCalls.first?.connectionID == connection.id)
    }

    @Test("ディレクトリ読み込みでは画面外動画を先行生成しない")
    func loadDirectory_doesNotPrefetchOffscreenVideos() async {
        let connection = ModelFactory.makeConnection()
        let repo = MockFileRepository()
        let provider = MockMediaThumbnailProvider()
        provider.loadedImage = UIImage()
        repo.items = [
            DirectoryItem(
                name: "first.mp4",
                path: "/first.mp4",
                itemType: .video,
                size: nil,
                modifiedAt: nil,
                createdAt: nil
            ),
            DirectoryItem(
                name: "second.mp4",
                path: "/second.mp4",
                itemType: .video,
                size: nil,
                modifiedAt: nil,
                createdAt: nil
            ),
        ]
        let vm = FileBrowserViewModel(
            connection: connection,
            fileRepository: repo,
            mediaThumbnailProvider: provider
        )

        await vm.loadDirectory()
        try? await Task.sleep(for: .milliseconds(50))

        #expect(provider.loadCalls.isEmpty)
    }

    @Test("選択した候補画像をサムネイルとして保存する")
    func selectThumbnail_storesSelectedImage() {
        let connection = ModelFactory.makeConnection()
        let repo = MockFileRepository()
        let service = ThumbnailService()
        let provider = MediaThumbnailProvider(
            thumbnailService: service,
            smbClientManager: SMBClientManager()
        )
        let item = DirectoryItem(
            name: "movie.mp4",
            path: "/movie.mp4",
            itemType: .video,
            size: nil,
            modifiedAt: nil,
            createdAt: nil
        )
        let vm = FileBrowserViewModel(
            connection: connection,
            fileRepository: repo,
            mediaThumbnailProvider: provider,
            thumbnailService: service
        )

        vm.selectThumbnail(UIImage(), for: item)

        #expect(vm.thumbnail(for: item) != nil)
    }

    @Test("SMB動画のProviderと生成サービスは同じキャッシュキーを使う")
    func remoteVideoCacheKey_isSharedByProviderAndService() {
        let connection = ModelFactory.makeConnection()
        let service = ThumbnailService()
        let provider = MediaThumbnailProvider(
            thumbnailService: service,
            smbClientManager: SMBClientManager()
        )
        let item = DirectoryItem(
            name: "movie.mp4",
            path: "/movie.mp4",
            itemType: .video,
            size: nil,
            modifiedAt: nil,
            createdAt: nil
        )

        #expect(
            provider.cacheKey(source: .remote(connection.id), item: item)
                == service.cacheKey(connection: connection, item: item)
        )
    }

    @Test("SMB動画のサムネイルキーはfileIdが同じなら移動後も変わらない")
    func remoteVideoCacheKey_keepsFileIdAcrossMove() {
        let connection = ModelFactory.makeConnection()
        let original = DirectoryItem(
            name: "movie.mp4",
            path: "/old/movie.mp4",
            itemType: .video,
            size: nil,
            modifiedAt: nil,
            createdAt: nil,
            fileId: 42
        )
        let moved = DirectoryItem(
            name: "movie.mp4",
            path: "/other/depth/movie.mp4",
            itemType: .video,
            size: nil,
            modifiedAt: nil,
            createdAt: nil,
            fileId: 42
        )

        #expect(
            ThumbnailService.remoteVideoCacheKey(
                connectionID: connection.id,
                itemPath: original.path,
                fileId: original.fileId
            ) == ThumbnailService.remoteVideoCacheKey(
                connectionID: connection.id,
                itemPath: moved.path,
                fileId: moved.fileId
            )
        )
    }

    @Test("ローカルブラウズはキャッシュ未命中時にサムネイル生成を試みる")
    func loadThumbnail_localBrowse_callsProviderLoad() async {
        let sourceID = UUID()
        let provider = MockMediaThumbnailProvider()
        let rootURL = URL(fileURLWithPath: "/tmp/PFileLocal")
        let item = DirectoryItem(
            name: "local.mp4",
            path: "/tmp/PFileLocal/local.mp4",
            itemType: .video,
            size: nil,
            modifiedAt: nil,
            createdAt: nil
        )
        let vm = LocalFolderBrowserViewModel(
            rootURL: rootURL,
            currentPath: rootURL.path,
            sourceID: sourceID,
            mediaThumbnailProvider: provider
        )

        await vm.loadThumbnail(for: item)

        #expect(provider.cacheCalls.map(\.itemPath) == ["/tmp/PFileLocal/local.mp4"])
        #expect(provider.loadCalls.count == 1)
        #expect(provider.loadCalls.first?.source.id == ContentSource.localFolder(sourceID).id)
        #expect(provider.loadCalls.first?.itemPath == "/tmp/PFileLocal/local.mp4")
        #expect(provider.loadCalls.first?.connectionID == nil)
    }

    // MARK: - sort

    @Test("名前の昇順でソートされる")
    func sort_byName_ascending() async {
        let items = [
            DirectoryItem(name: "c.mp4", path: "/c.mp4", itemType: .video, size: nil, modifiedAt: nil, createdAt: nil),
            DirectoryItem(name: "a.mp4", path: "/a.mp4", itemType: .video, size: nil, modifiedAt: nil, createdAt: nil),
            DirectoryItem(name: "b.mp4", path: "/b.mp4", itemType: .video, size: nil, modifiedAt: nil, createdAt: nil),
        ]
        let (vm, _) = makeViewModel(items: items)
        await vm.loadDirectory()

        vm.sortKey = .name
        vm.sortOrder = .ascending
        await vm.applySortChange()

        #expect(vm.items.map(\.name) == ["a.mp4", "b.mp4", "c.mp4"])
    }

    @Test("サイズの降順でソートされる")
    func sort_bySize_descending() async {
        let items = [
            DirectoryItem(name: "small.mp4",  path: "/small.mp4",  itemType: .video, size: 100, modifiedAt: nil, createdAt: nil),
            DirectoryItem(name: "large.mp4",  path: "/large.mp4",  itemType: .video, size: 300, modifiedAt: nil, createdAt: nil),
            DirectoryItem(name: "medium.mp4", path: "/medium.mp4", itemType: .video, size: 200, modifiedAt: nil, createdAt: nil),
        ]
        let (vm, _) = makeViewModel(items: items)
        await vm.loadDirectory()

        vm.sortKey = .size
        vm.sortOrder = .descending
        await vm.applySortChange()

        #expect(vm.items.map(\.size) == [300, 200, 100])
    }

    @Test("選択したフォルダ配下のメディアを再帰収集できる")
    func collectMediaItemsRecursively_fromDirectory() async throws {
        let rootFolder = DirectoryItem(name: "Movies", path: "/Movies", itemType: .directory, size: nil, modifiedAt: nil, createdAt: nil)
        let nestedFolder = DirectoryItem(name: "Season1", path: "/Movies/Season1", itemType: .directory, size: nil, modifiedAt: nil, createdAt: nil)
        let movie = DirectoryItem(name: "movie.mp4", path: "/Movies/movie.mp4", itemType: .video, size: nil, modifiedAt: nil, createdAt: nil)
        let image = DirectoryItem(name: "cover.jpg", path: "/Movies/Season1/cover.jpg", itemType: .image, size: nil, modifiedAt: nil, createdAt: nil)
        let other = DirectoryItem(name: "note.txt", path: "/Movies/note.txt", itemType: .other, size: nil, modifiedAt: nil, createdAt: nil)

        let repo = MockFileRepository()
        repo.directoryItemsByPath = [
            "/Movies": [nestedFolder, movie, other],
            "/Movies/Season1": [image],
        ]

        let results = try await repo.collectMediaItemsRecursively(from: [rootFolder])

        #expect(results.map(\.path) == ["/Movies/Season1/cover.jpg", "/Movies/movie.mp4"])
        #expect(repo.listedPaths == ["/Movies", "/Movies/Season1"])
    }

    @Test("漫画フォルダ判定では Thumbs.db を無視して画像を返す")
    func comicImageItemsIfEligible_ignoresThumbsDb() async throws {
        let folder = DirectoryItem(name: "Comic", path: "/Comic", itemType: .directory, size: nil, modifiedAt: nil, createdAt: nil)
        let repo = MockFileRepository()
        repo.directoryItemsByPath = [
            "/Comic": [
                DirectoryItem(name: "001.jpg", path: "/Comic/001.jpg", itemType: .image, size: nil, modifiedAt: nil, createdAt: nil),
                DirectoryItem(name: "Thumbs.db", path: "/Comic/Thumbs.db", itemType: .other, size: nil, modifiedAt: nil, createdAt: nil),
                DirectoryItem(name: "002.jpg", path: "/Comic/002.jpg", itemType: .image, size: nil, modifiedAt: nil, createdAt: nil),
            ]
        ]

        let items = try await repo.comicImageItemsIfEligible(in: folder)

        #expect(items?.map(\.name) == ["001.jpg", "002.jpg"])
    }

    @Test("漫画フォルダ判定では混在フォルダでも画像が2枚以上あれば画像だけ返す")
    func comicImageItemsIfEligible_acceptsMixedFolder() async throws {
        let folder = DirectoryItem(name: "Mixed", path: "/Mixed", itemType: .directory, size: nil, modifiedAt: nil, createdAt: nil)
        let repo = MockFileRepository()
        repo.directoryItemsByPath = [
            "/Mixed": [
                DirectoryItem(name: "001.jpg", path: "/Mixed/001.jpg", itemType: .image, size: nil, modifiedAt: nil, createdAt: nil),
                DirectoryItem(name: "extras", path: "/Mixed/extras", itemType: .directory, size: nil, modifiedAt: nil, createdAt: nil),
                DirectoryItem(name: "002.jpg", path: "/Mixed/002.jpg", itemType: .image, size: nil, modifiedAt: nil, createdAt: nil),
                DirectoryItem(name: "note.txt", path: "/Mixed/note.txt", itemType: .other, size: nil, modifiedAt: nil, createdAt: nil),
            ]
        ]

        let items = try await repo.comicImageItemsIfEligible(in: folder)

        #expect(items?.map(\.name) == ["001.jpg", "002.jpg"])
    }

}
