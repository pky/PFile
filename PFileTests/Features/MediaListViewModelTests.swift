@testable import PFile
import Foundation
import Testing
import UIKit

private final class RecursiveLookupFileRepository: FileRepository {
    let childrenByPath: [String: [DirectoryItem]]

    init(childrenByPath: [String: [DirectoryItem]]) {
        self.childrenByPath = childrenByPath
    }

    func listDirectory(at path: String) async throws -> [DirectoryItem] {
        childrenByPath[path] ?? []
    }

    func fileExists(at path: String) async throws -> Bool { false }
    func download(from remotePath: String, to localURL: URL, progress: ((Double) -> Void)?) async throws {}
    func upload(from localURL: URL, to remotePath: String, progress: ((Double) -> Void)?) async throws {}
    func createDirectory(at path: String) async throws {}
    func delete(at path: String) async throws {}
    func move(from sourcePath: String, to destinationPath: String) async throws {}
    func copy(from sourcePath: String, to destinationPath: String) async throws {}
    func rename(at path: String, to newName: String) async throws {}
}

@MainActor
struct MediaListViewModelTests {

    private let testScopeID = ContentSource.remote(UUID()).id

    private func makeListsViewModel() -> (MediaListsViewModel, MockMediaListRepository) {
        let repo = MockMediaListRepository()
        let vm = MediaListsViewModel(repository: repo, scopeID: testScopeID)
        return (vm, repo)
    }

    private func makeDetailViewModel(list: MediaList) -> (MediaListDetailViewModel, MockMediaListRepository) {
        let repo = MockMediaListRepository()
        repo.lists = [list]
        let vm = MediaListDetailViewModel(list: list, repository: repo)
        return (vm, repo)
    }

    // MARK: - MediaListsViewModel

    @Test("load でリスト一覧を取得できる")
    func load_success() async {
        let (vm, repo) = makeListsViewModel()
        let list = MediaList(name: "お気に入り", scopeID: testScopeID, sortOrder: 0)
        repo.lists = [list]

        await vm.load()

        #expect(vm.lists.count == 1)
        #expect(vm.lists.first?.name == "お気に入り")
        #expect(vm.isLoading == false)
        #expect(vm.errorMessage == nil)
    }

    @Test("createList でリストを作成できる")
    func createList_success() async {
        let (vm, repo) = makeListsViewModel()

        await vm.createList(name: "新しいリスト")

        #expect(vm.lists.count == 1)
        #expect(repo.lists.count == 1)
        #expect(vm.lists.first?.name == "新しいリスト")
    }

    @Test("deleteList でリストを削除できる")
    func deleteList_success() async {
        let (vm, repo) = makeListsViewModel()
        let list = MediaList(name: "削除対象", scopeID: testScopeID, sortOrder: 0)
        repo.lists = [list]
        await vm.load()

        await vm.deleteList(list)

        #expect(vm.lists.isEmpty)
        #expect(repo.lists.isEmpty)
    }

    @Test("renameList でリスト名を変更できる")
    func renameList_success() async {
        let (vm, repo) = makeListsViewModel()
        let list = MediaList(name: "古い名前", scopeID: testScopeID, sortOrder: 0)
        repo.lists = [list]
        await vm.load()

        await vm.renameList(list, to: "新しい名前")

        #expect(vm.lists.first?.name == "新しい名前")
    }

    @Test("moveLists で並び順を変更できる")
    func moveLists_success() async {
        let (vm, repo) = makeListsViewModel()
        let list0 = MediaList(name: "A", scopeID: testScopeID, sortOrder: 0)
        let list1 = MediaList(name: "B", scopeID: testScopeID, sortOrder: 1)
        let list2 = MediaList(name: "C", scopeID: testScopeID, sortOrder: 2)
        repo.lists = [list0, list1, list2]
        await vm.load()

        // A を末尾へ
        await vm.moveLists(from: IndexSet(integer: 0), to: 3)

        #expect(vm.lists.map(\.name) == ["B", "C", "A"])
    }

    // MARK: - MediaListDetailViewModel

    @Test("load でファイル一覧を取得できる")
    func detail_load_success() async {
        let list = MediaList(name: "テスト", sortOrder: 0)
        let file = MediaFile(connectionId: UUID(), path: "/a.mp4", name: "a.mp4", itemTypeRaw: "video")
        list.items = [file]
        let (vm, _) = makeDetailViewModel(list: list)

        await vm.load()

        #expect(vm.files.count == 1)
        #expect(vm.files.first?.name == "a.mp4")
    }

    @Test("detail は名前順に並び替えできる")
    func detail_sortByName_success() async {
        let list = MediaList(name: "テスト", sortOrder: 0)
        let oldDate = Date(timeIntervalSince1970: 100)
        let newDate = Date(timeIntervalSince1970: 200)
        let zFile = MediaFile(
            connectionId: UUID(),
            path: "/z.mp4",
            name: "z.mp4",
            itemTypeRaw: "video",
            fileSize: 200,
            addedAt: oldDate
        )
        let aFile = MediaFile(
            connectionId: UUID(),
            path: "/a.mp4",
            name: "a.mp4",
            itemTypeRaw: "video",
            fileSize: 100,
            addedAt: newDate
        )
        list.items = [zFile, aFile]
        let (vm, _) = makeDetailViewModel(list: list)

        vm.sortKey = .name
        vm.sortOrder = .ascending

        #expect(vm.files.map(\.name) == ["a.mp4", "z.mp4"])
    }

    @Test("detail は追加順の新しい順に並び替えできる")
    func detail_sortByAddedAtDescending_success() async {
        let list = MediaList(name: "テスト", sortOrder: 0)
        let oldDate = Date(timeIntervalSince1970: 100)
        let newDate = Date(timeIntervalSince1970: 200)
        let oldFile = MediaFile(
            connectionId: UUID(),
            path: "/old.mp4",
            name: "old.mp4",
            itemTypeRaw: "video",
            addedAt: oldDate
        )
        let newFile = MediaFile(
            connectionId: UUID(),
            path: "/new.mp4",
            name: "new.mp4",
            itemTypeRaw: "video",
            addedAt: newDate
        )
        list.items = [oldFile, newFile]
        let (vm, _) = makeDetailViewModel(list: list)

        vm.sortKey = .addedAt
        vm.sortOrder = .descending

        #expect(vm.files.map(\.name) == ["new.mp4", "old.mp4"])
    }

    @Test("detail は元ファイル日時で並び替えできる")
    func detail_sortBySourceCreatedAtDescending_success() async {
        let list = MediaList(name: "テスト", sortOrder: 0)
        let oldDate = Date(timeIntervalSince1970: 100)
        let newDate = Date(timeIntervalSince1970: 200)
        let oldFile = MediaFile(
            connectionId: UUID(),
            path: "/old.mp4",
            name: "old.mp4",
            itemTypeRaw: "video",
            sourceCreatedAt: oldDate
        )
        let newFile = MediaFile(
            connectionId: UUID(),
            path: "/new.mp4",
            name: "new.mp4",
            itemTypeRaw: "video",
            sourceCreatedAt: newDate
        )
        list.items = [oldFile, newFile]
        let (vm, _) = makeDetailViewModel(list: list)

        vm.sortKey = .sourceCreatedAt
        vm.sortOrder = .descending

        #expect(vm.files.map(\.name) == ["new.mp4", "old.mp4"])
    }

    @Test("removeFile でファイルをリストから削除できる")
    func detail_removeFile_success() async {
        let list = MediaList(name: "テスト", sortOrder: 0)
        let file = MediaFile(connectionId: UUID(), path: "/a.mp4", name: "a.mp4", itemTypeRaw: "video")
        list.items = [file]
        let (vm, _) = makeDetailViewModel(list: list)
        await vm.load()

        await vm.removeFile(file)

        #expect(vm.files.isEmpty)
    }

    @Test("removeFiles で複数ファイルをリストから削除できる")
    func detail_removeFiles_success() async {
        let list = MediaList(name: "テスト", sortOrder: 0)
        let file1 = MediaFile(connectionId: UUID(), path: "/a.mp4", name: "a.mp4", itemTypeRaw: "video")
        let file2 = MediaFile(connectionId: UUID(), path: "/b.mp4", name: "b.mp4", itemTypeRaw: "video")
        let file3 = MediaFile(connectionId: UUID(), path: "/c.jpg", name: "c.jpg", itemTypeRaw: "image")
        list.items = [file1, file2, file3]
        let (vm, _) = makeDetailViewModel(list: list)
        await vm.load()

        await vm.removeFiles([file1, file3])

        #expect(vm.files.count == 1)
        #expect(vm.files.first?.id == file2.id)
    }

    @Test("リスト詳細はキャッシュ未命中時にサムネイル生成を試みる")
    func detail_loadThumbnail_callsProviderLoad() async {
        let connection = ModelFactory.makeConnection()
        let sourceID = ContentSource.remote(connection.id).id
        let list = MediaList(name: "テスト", scopeID: sourceID, sortOrder: 0)
        let file = MediaFile(
            connectionId: connection.id,
            sourceID: sourceID,
            path: "/list/movie.mp4",
            name: "movie.mp4",
            itemTypeRaw: "video"
        )
        list.items = [file]
        let repo = MockMediaListRepository()
        let provider = MockMediaThumbnailProvider()
        let vm = MediaListDetailViewModel(
            list: list,
            repository: repo,
            mediaThumbnailProvider: provider
        )

        await vm.loadThumbnail(for: file)

        #expect(provider.loadCalls.count == 1)
        #expect(provider.loadCalls.first?.source.id == sourceID)
        #expect(provider.loadCalls.first?.itemPath == "/list/movie.mp4")
    }

    @Test("サムネイル更新ではファイル一覧を再ソートしない")
    func detail_loadThumbnail_doesNotSortFilesAgain() async {
        let connection = ModelFactory.makeConnection()
        let sourceID = ContentSource.remote(connection.id).id
        let list = MediaList(name: "テスト", scopeID: sourceID, sortOrder: 0)
        let file = MediaFile(
            connectionId: connection.id,
            sourceID: sourceID,
            path: "/list/movie.mp4",
            name: "movie.mp4",
            itemTypeRaw: "video"
        )
        list.items = [file]
        let provider = MockMediaThumbnailProvider()
        provider.loadedImage = UIImage()
        let vm = MediaListDetailViewModel(
            list: list,
            repository: MockMediaListRepository(),
            mediaThumbnailProvider: provider
        )
        let sortCountBeforeLoading = vm.fileSortCount

        await vm.loadThumbnail(for: file)

        #expect(vm.thumbnail(for: file) != nil)
        #expect(vm.fileSortCount == sortCountBeforeLoading)
    }

    @Test("外部で追加された項目は明示的な同期で一覧へ反映する")
    func detail_refreshFiles_reflectsExternalItemChanges() {
        let list = MediaList(name: "テスト", sortOrder: 0)
        let (vm, _) = makeDetailViewModel(list: list)
        let file = MediaFile(
            connectionId: UUID(),
            path: "/added.mp4",
            name: "added.mp4",
            itemTypeRaw: "video"
        )

        list.items = [file]
        vm.refreshFiles()

        #expect(vm.files.map(\.id) == [file.id])
    }

    @Test("リスト詳細で選択した候補画像をサムネイルへ反映する")
    func detail_selectThumbnail_storesSelectedImage() async {
        let connection = ModelFactory.makeConnection()
        let sourceID = ContentSource.remote(connection.id).id
        let list = MediaList(name: "テスト", scopeID: sourceID, sortOrder: 0)
        let file = MediaFile(
            connectionId: connection.id,
            sourceID: sourceID,
            path: "/list/movie.mp4",
            name: "movie.mp4",
            itemTypeRaw: "video"
        )
        list.items = [file]
        let connectionRepository = MockRemoteConnectionRepository()
        connectionRepository.connections = [connection]
        let service = ThumbnailService()
        let manager = SMBClientManager()
        let provider = MediaThumbnailProvider(
            thumbnailService: service,
            smbClientManager: manager
        )
        let vm = MediaListDetailViewModel(
            list: list,
            repository: MockMediaListRepository(),
            remoteConnectionRepository: connectionRepository,
            mediaThumbnailProvider: provider,
            thumbnailService: service,
            smbClientManager: manager
        )
        await vm.load()

        vm.selectThumbnail(UIImage(), for: file)

        #expect(vm.canChooseThumbnail(for: file))
        #expect(vm.thumbnail(for: file) != nil)
    }

    @Test("detail は fileId 一致で移動後のパスへ更新できる")
    func detail_addItems_updatesExistingPathByFileId() async throws {
        let repo = MockMediaListRepository()
        let connection = ModelFactory.makeConnection()
        let scopeID = ContentSource.remote(connection.id).id
        let list = MediaList(name: "テスト", scopeID: scopeID, sortOrder: 0)
        let original = MediaFile(
            connectionId: connection.id,
            sourceID: scopeID,
            path: "/old/movie.mp4",
            name: "movie.mp4",
            itemTypeRaw: "video",
            fileId: 42
        )
        list.items = [original]
        repo.files = [original]

        let movedItem = DirectoryItem(
            name: "movie.mp4",
            path: "/new/movie.mp4",
            itemType: .video,
            size: 1_000,
            modifiedAt: nil,
            createdAt: nil,
            fileId: 42
        )

        try await repo.addItems([movedItem], sourceID: scopeID, to: list)

        #expect(list.items.count == 1)
        #expect(list.items.first?.path == "/new/movie.mp4")
        #expect(list.items.first?.id == original.id)
    }

    @Test("移動済み動画は複数fileIdを一度のツリー走査で復元できる")
    func recursiveLookup_findsAllMovedItems() async throws {
        let folder = DirectoryItem(
            name: "moved",
            path: "/moved",
            itemType: .directory,
            size: nil,
            modifiedAt: nil,
            createdAt: nil
        )
        let first = DirectoryItem(
            name: "first.mp4",
            path: "/moved/first.mp4",
            itemType: .video,
            size: nil,
            modifiedAt: nil,
            createdAt: nil,
            fileId: 101
        )
        let second = DirectoryItem(
            name: "second.mp4",
            path: "/moved/second.mp4",
            itemType: .video,
            size: nil,
            modifiedAt: nil,
            createdAt: nil,
            fileId: 202
        )
        let repository = RecursiveLookupFileRepository(
            childrenByPath: ["/": [folder], "/moved": [first, second]]
        )

        let found = try await repository.findMediaItemsRecursively(
            at: "/",
            matchingFileIDs: [101, 202]
        )

        #expect(found[101]?.path == first.path)
        #expect(found[202]?.path == second.path)
    }

    // MARK: - AddToListViewModel

    @Test("load でリスト一覧と既存登録状態を取得できる")
    func addToList_load_success() async {
        let repo = MockMediaListRepository()
        let connection = ModelFactory.makeConnection()
        let scopeID = ContentSource.remote(connection.id).id
        let list = MediaList(name: "お気に入り", scopeID: scopeID, sortOrder: 0)
        let items = [
            DirectoryItem(name: "a.mp4", path: "/a.mp4", itemType: .video, size: nil, modifiedAt: nil, createdAt: nil),
        ]
        repo.lists = [list]
        // ファイルを事前に登録済みにする
        try? await repo.addItems(items, connection: connection, to: list)

        let vm = AddToListViewModel(repository: repo)
        await vm.load(checkedFor: items, scopeID: scopeID)

        #expect(vm.lists.count == 1)
        // 登録済みのためチェック済み
        #expect(vm.selectedListIds.contains(list.id))
    }

    @Test("createAndSelect で新規リストが作成され選択済みになる")
    func addToList_createAndSelect_success() async {
        let repo = MockMediaListRepository()
        let vm = AddToListViewModel(repository: repo)
        await vm.load(checkedFor: [], scopeID: ContentSource.remote(UUID()).id)

        await vm.createAndSelect(name: "新しいリスト")

        #expect(vm.lists.count == 1)
        #expect(vm.selectedListIds.count == 1)
        #expect(vm.lists.first?.name == "新しいリスト")
    }

    @Test("save でチェックを外した既存リストから削除できる")
    func addToList_save_removesFromUncheckedList() async {
        let repo = MockMediaListRepository()
        let connection = ModelFactory.makeConnection()
        let scopeID = ContentSource.remote(connection.id).id
        let list = MediaList(name: "お気に入り", scopeID: scopeID, sortOrder: 0)
        let items = [
            DirectoryItem(name: "a.mp4", path: "/a.mp4", itemType: .video, size: nil, modifiedAt: nil, createdAt: nil),
        ]
        repo.lists = [list]
        try? await repo.addItems(items, connection: connection, to: list)

        let vm = AddToListViewModel(repository: repo)
        await vm.load(checkedFor: items, scopeID: scopeID)
        vm.selectedListIds.remove(list.id)

        await vm.save(items: items, sourceID: scopeID, connection: connection)

        #expect(list.items.isEmpty)
        #expect(vm.initialSelectedListIds.isEmpty)
        #expect(vm.hasChanges == false)
    }

    @Test("save で未選択リストへの追加と既存リストからの削除を同時に反映できる")
    func addToList_save_updatesSelections() async {
        let repo = MockMediaListRepository()
        let connection = ModelFactory.makeConnection()
        let scopeID = ContentSource.remote(connection.id).id
        let oldList = MediaList(name: "旧リスト", scopeID: scopeID, sortOrder: 0)
        let newList = MediaList(name: "新リスト", scopeID: scopeID, sortOrder: 1)
        let items = [
            DirectoryItem(name: "a.mp4", path: "/a.mp4", itemType: .video, size: nil, modifiedAt: nil, createdAt: nil),
        ]
        repo.lists = [oldList, newList]
        try? await repo.addItems(items, connection: connection, to: oldList)

        let vm = AddToListViewModel(repository: repo)
        await vm.load(checkedFor: items, scopeID: scopeID)
        vm.selectedListIds.remove(oldList.id)
        vm.selectedListIds.insert(newList.id)

        await vm.save(items: items, sourceID: scopeID, connection: connection)

        #expect(oldList.items.isEmpty)
        #expect(newList.items.count == 1)
        #expect(vm.selectedListIds == Set([newList.id]))
        #expect(vm.hasChanges == false)
    }

    @Test("既存項目が混在していても未追加分があれば同じリストへ保存できる")
    func addToList_save_allowsMixedExistingItems() async {
        let repo = MockMediaListRepository()
        let connection = ModelFactory.makeConnection()
        let scopeID = ContentSource.remote(connection.id).id
        let list = MediaList(name: "お気に入り", scopeID: scopeID, sortOrder: 0)
        let existing = DirectoryItem(name: "a.mp4", path: "/a.mp4", itemType: .video, size: nil, modifiedAt: nil, createdAt: nil)
        let newItem = DirectoryItem(name: "b.mp4", path: "/b.mp4", itemType: .video, size: nil, modifiedAt: nil, createdAt: nil)
        repo.lists = [list]
        try? await repo.addItems([existing], connection: connection, to: list)

        let vm = AddToListViewModel(repository: repo)
        await vm.load(checkedFor: [existing, newItem], scopeID: scopeID)

        #expect(vm.selectedListIds.contains(list.id))
        #expect(vm.hasChanges == false)
        #expect(vm.canSave == true)
        #expect(vm.addableItemCounts[list.id] == 1)

        await vm.save(items: [existing, newItem], sourceID: scopeID, connection: connection)

        #expect(list.items.count == 2)
        #expect(list.items.contains { $0.path == "/a.mp4" })
        #expect(list.items.contains { $0.path == "/b.mp4" })
        #expect(vm.canSave == false)
    }

    @Test("リスト登録時に元ファイル日時を保持する")
    func addToList_preservesSourceCreatedAt() async throws {
        let repo = MockMediaListRepository()
        let connection = ModelFactory.makeConnection()
        let sourceID = ContentSource.remote(connection.id).id
        let list = MediaList(name: "お気に入り", scopeID: sourceID, sortOrder: 0)
        let createdAt = Date(timeIntervalSince1970: 123_456)
        let item = DirectoryItem(
            name: "a.mp4",
            path: "/a.mp4",
            itemType: .video,
            size: 123,
            modifiedAt: nil,
            createdAt: createdAt
        )

        try await repo.addItems([item], sourceID: sourceID, to: list)

        #expect(list.items.first?.sourceCreatedAt == createdAt)
        #expect(list.items.first?.fileSize == 123)
    }

    // MARK: - TabOrderService

    @Test("TabOrderService のデフォルトタブ順序は [browser, lists, history]")
    func tabOrderService_default() {
        // UserDefaults をクリアしてデフォルト状態をテスト
        UserDefaults.standard.removeObject(forKey: "App.tabOrder")
        let service = TabOrderService()
        #expect(service.tabs == [.browser, .lists, .history])
    }
}
