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

}
