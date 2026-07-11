@testable import PFile
import Testing
import Foundation

@MainActor
struct WatchHistoryListViewModelTests {

    @Test("視聴履歴一覧を正常に取得できる")
    func load_success() async {
        let repo = MockWatchHistoryRepository()
        let connection = ModelFactory.makeConnection()
        repo.histories = [
            WatchHistory(connection: connection, filePath: "/a.mp4", fileName: "a.mp4", lastPositionSeconds: 60),
            WatchHistory(connection: connection, filePath: "/b.mp4", fileName: "b.mp4", lastPositionSeconds: 120),
        ]
        let vm = WatchHistoryListViewModel(watchHistoryRepository: repo)

        await vm.load()

        #expect(vm.histories.count == 2)
        #expect(vm.errorMessage == nil)
    }

    @Test("取得エラー時に errorMessage がセットされる")
    func load_error() async {
        let repo = MockWatchHistoryRepository()
        repo.shouldThrow = true
        let vm = WatchHistoryListViewModel(watchHistoryRepository: repo)

        await vm.load()

        #expect(vm.histories.isEmpty)
        #expect(vm.errorMessage != nil)
    }

    @Test("視聴履歴を削除すると一覧から消える")
    func delete_success() async {
        let repo = MockWatchHistoryRepository()
        let connection = ModelFactory.makeConnection()
        let history = WatchHistory(connection: connection, filePath: "/a.mp4", fileName: "a.mp4", lastPositionSeconds: 30)
        repo.histories = [history]

        let vm = WatchHistoryListViewModel(watchHistoryRepository: repo)
        await vm.load()
        await vm.delete(history)

        #expect(vm.histories.isEmpty)
    }

    @Test("履歴はキャッシュ未命中時にサムネイル生成を試みる")
    func loadThumbnail_callsProviderLoad() async {
        let repo = MockWatchHistoryRepository()
        let connection = ModelFactory.makeConnection()
        let provider = MockMediaThumbnailProvider()
        let history = WatchHistory(
            sourceID: ContentSource.remote(connection.id).id,
            connection: connection,
            filePath: "/history/movie.mp4",
            fileName: "movie.mp4",
            lastPositionSeconds: 30,
            durationSeconds: 120,
            fileId: nil,
            thumbnailData: nil
        )
        let vm = WatchHistoryListViewModel(
            watchHistoryRepository: repo,
            mediaThumbnailProvider: provider
        )

        await vm.loadThumbnail(for: history)

        #expect(provider.loadCalls.count == 1)
        #expect(provider.loadCalls.first?.source.id == ContentSource.remote(connection.id).id)
        #expect(provider.loadCalls.first?.itemPath == "/history/movie.mp4")
        #expect(provider.loadCalls.first?.connectionID == connection.id)
    }

}
