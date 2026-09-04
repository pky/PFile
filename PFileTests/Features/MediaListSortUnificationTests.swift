@testable import PFile
import Foundation
import Testing
import UIKit

private final class StubFileRepository: FileRepository {
    let childrenByPath: [String: [DirectoryItem]]
    private(set) var listedPaths: [String] = []

    init(childrenByPath: [String: [DirectoryItem]] = [:]) {
        self.childrenByPath = childrenByPath
    }

    func listDirectory(at path: String) async throws -> [DirectoryItem] {
        listedPaths.append(path)
        return childrenByPath[path] ?? []
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
struct MediaListSortUnificationTests {

    private func item(_ name: String, modifiedAt: TimeInterval, fileId: UInt64? = nil) -> DirectoryItem {
        DirectoryItem(
            name: name,
            path: "/videos/\(name)",
            itemType: .video,
            size: 10,
            modifiedAt: Date(timeIntervalSince1970: modifiedAt),
            createdAt: nil,
            fileId: fileId
        )
    }

    private func solidImage(_ color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 320, height: 180)).image { context in
            context.cgContext.setFillColor(color.cgColor)
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
        }
    }

    // MARK: - ソートキー

    @Test("リストの並び順はブラウズと同じキーにリスト登録日時を加えたもの")
    func sortKeysMatchBrowser() {
        #expect(MediaListSortKey.allCases == [.name, .size, .modifiedAt, .createdAt, .listAddedAt])
        #expect(MediaListSortKey.name.displayName == SortKey.name.displayName)
        #expect(MediaListSortKey.size.displayName == SortKey.size.displayName)
        #expect(MediaListSortKey.modifiedAt.displayName == SortKey.modifiedAt.displayName)
        #expect(MediaListSortKey.createdAt.displayName == SortKey.createdAt.displayName)
        #expect(MediaListSortKey.listAddedAt.displayName == "リスト登録日時")
        #expect(MediaListDateDisplayMode.allCases == [.modifiedAt, .createdAt, .listAddedAt])
    }

    @Test("保存済みの旧ソート設定は新しいキーへ読み替える")
    func legacyPersistedValuesMap() {
        #expect(MediaListSortKey(persistedRawValue: "addedAt") == .listAddedAt)
        #expect(MediaListSortKey(persistedRawValue: "sourceCreatedAt") == .createdAt)
        #expect(MediaListSortKey(persistedRawValue: "modifiedAt") == .modifiedAt)
        #expect(MediaListSortKey(persistedRawValue: "unknown") == nil)
        #expect(MediaListDateDisplayMode(persistedRawValue: "addedAt") == .listAddedAt)
        #expect(MediaListDateDisplayMode(persistedRawValue: "sourceCreatedAt") == .createdAt)
        #expect(MediaListDateDisplayMode(persistedRawValue: "modifiedAt") == .modifiedAt)
    }

    @Test("更新日時ソートはブラウズの SortService と同じ順になる")
    func modifiedAtSortMatchesBrowser() {
        let items = [item("c.mp4", modifiedAt: 300), item("a.mp4", modifiedAt: 100), item("b.mp4", modifiedAt: 200)]
        let list = MediaList(name: "テスト", sortOrder: 0)
        list.items = items.map { item in
            MediaFile(
                connectionId: UUID(),
                path: item.path,
                name: item.name,
                itemTypeRaw: "video",
                sourceModifiedAt: item.modifiedAt
            )
        }
        let repo = MockMediaListRepository()
        repo.lists = [list]
        let vm = MediaListDetailViewModel(list: list, repository: repo)
        let sortService = SortService()

        for order in SortOrder.allCases {
            vm.sortKey = .modifiedAt
            vm.sortOrder = order
            let expected = sortService.sort(items, by: .modifiedAt, order: order).map(\.name)
            #expect(vm.files.map(\.name) == expected)
        }
    }

    @Test("リスト登録日時ソートは元ファイルの日時に影響されない")
    func listAddedAtSortUsesAddedDate() {
        let list = MediaList(name: "テスト", sortOrder: 0)
        let older = MediaFile(
            connectionId: UUID(),
            path: "/older.mp4",
            name: "older.mp4",
            itemTypeRaw: "video",
            addedAt: Date(timeIntervalSince1970: 100),
            sourceModifiedAt: Date(timeIntervalSince1970: 900)
        )
        let newer = MediaFile(
            connectionId: UUID(),
            path: "/newer.mp4",
            name: "newer.mp4",
            itemTypeRaw: "video",
            addedAt: Date(timeIntervalSince1970: 200),
            sourceModifiedAt: Date(timeIntervalSince1970: 100)
        )
        list.items = [older, newer]
        let vm = MediaListDetailViewModel(list: list, repository: MockMediaListRepository())

        vm.sortKey = .listAddedAt
        vm.sortOrder = .descending

        #expect(vm.files.map(\.name) == ["newer.mp4", "older.mp4"])
        #expect(MediaListDateDisplayMode.listAddedAt.date(for: newer) == newer.addedAt)
        #expect(MediaListDateDisplayMode.modifiedAt.date(for: newer) == newer.sourceModifiedAt)
    }

    // MARK: - 更新日時の保持

    @Test("リスト登録時に元ファイルの更新日時を保持し再登録で更新する")
    func addItemsStoresSourceModifiedAt() async throws {
        let repo = MockMediaListRepository()
        let connection = ModelFactory.makeConnection()
        let sourceID = ContentSource.remote(connection.id).id
        let list = MediaList(name: "お気に入り", scopeID: sourceID, sortOrder: 0)

        try await repo.addItems([item("a.mp4", modifiedAt: 100, fileId: 5)], sourceID: sourceID, to: list)
        #expect(list.items.first?.sourceModifiedAt == Date(timeIntervalSince1970: 100))
        #expect(list.items.first?.toDirectoryItem().modifiedAt == Date(timeIntervalSince1970: 100))

        try await repo.addItems([item("a.mp4", modifiedAt: 500, fileId: 5)], sourceID: sourceID, to: list)
        #expect(list.items.count == 1)
        #expect(list.items.first?.sourceModifiedAt == Date(timeIntervalSince1970: 500))
    }

    @Test("更新日時が未取得の登録済み項目は読み込み時にブラウズ情報から補完する")
    func loadBackfillsSourceModifiedAt() async {
        let connection = ModelFactory.makeConnection()
        let sourceID = ContentSource.remote(connection.id).id
        let list = MediaList(name: "テスト", scopeID: sourceID, sortOrder: 0)
        let stale = MediaFile(
            connectionId: connection.id,
            sourceID: sourceID,
            path: "/videos/a.mp4",
            name: "a.mp4",
            itemTypeRaw: "video",
            fileId: 7
        )
        let fresh = MediaFile(
            connectionId: connection.id,
            sourceID: sourceID,
            path: "/videos/b.mp4",
            name: "b.mp4",
            itemTypeRaw: "video",
            fileId: 8,
            sourceModifiedAt: Date(timeIntervalSince1970: 50)
        )
        list.items = [stale, fresh]
        let repo = MockMediaListRepository()
        repo.lists = [list]
        repo.files = [stale, fresh]
        let connectionRepository = MockRemoteConnectionRepository()
        connectionRepository.connections = [connection]
        let fileRepository = StubFileRepository(childrenByPath: [
            "/videos": [item("a.mp4", modifiedAt: 400, fileId: 7), item("b.mp4", modifiedAt: 999, fileId: 8)],
        ])
        let vm = MediaListDetailViewModel(
            list: list,
            repository: repo,
            remoteConnectionRepository: connectionRepository,
            fileRepositoryFactory: { _ in fileRepository }
        )

        await vm.load()

        #expect(stale.sourceModifiedAt == Date(timeIntervalSince1970: 400))
        #expect(fresh.sourceModifiedAt == Date(timeIntervalSince1970: 50))
        #expect(fileRepository.listedPaths == ["/videos"])
    }

    // MARK: - サムネイルの共有

    @Test("リスト詳細で選んだサムネイルはブラウズ側の表示にも反映される")
    func selectedThumbnailPropagatesToBrowser() async {
        let connection = ModelFactory.makeConnection()
        let sourceID = ContentSource.remote(connection.id).id
        let service = ThumbnailService()
        let manager = SMBClientManager()
        let provider = MediaThumbnailProvider(thumbnailService: service, smbClientManager: manager)
        let browseItem = item("a.mp4", modifiedAt: 100, fileId: 99)
        let browser = FileBrowserViewModel(
            connection: connection,
            fileRepository: StubFileRepository(),
            mediaThumbnailProvider: provider,
            thumbnailService: service,
            smbClientManager: manager
        )
        browser.selectThumbnail(solidImage(.red), for: browseItem)
        let before = browser.thumbnail(for: browseItem)

        let list = MediaList(name: "テスト", scopeID: sourceID, sortOrder: 0)
        let file = MediaFile(
            connectionId: connection.id,
            sourceID: sourceID,
            path: browseItem.path,
            name: browseItem.name,
            itemTypeRaw: "video",
            fileId: 99
        )
        list.items = [file]
        let connectionRepository = MockRemoteConnectionRepository()
        connectionRepository.connections = [connection]
        let detail = MediaListDetailViewModel(
            list: list,
            repository: MockMediaListRepository(),
            remoteConnectionRepository: connectionRepository,
            mediaThumbnailProvider: provider,
            thumbnailService: service,
            smbClientManager: manager
        )
        await detail.load()

        detail.selectThumbnail(solidImage(.blue), for: file)

        let after = browser.thumbnail(for: browseItem)
        #expect(before != nil)
        #expect(after != nil)
        #expect(after !== before)
        #expect(after === detail.thumbnail(for: file))
    }
}
