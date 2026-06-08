@testable import PFile
import Testing

@MainActor
struct HomeViewModelTests {

    // MARK: - loadConnections

    @Test("接続先一覧を正常に取得できる")
    func loadConnections_success() async {
        let repo = MockRemoteConnectionRepository()
        repo.connections = [
            ModelFactory.makeConnection(displayName: "NAS-A"),
            ModelFactory.makeConnection(displayName: "NAS-B"),
        ]
        let vm = HomeViewModel(remoteConnectionRepository: repo)

        await vm.loadConnections()

        #expect(vm.connections.count == 2)
        #expect(vm.errorMessage == nil)
        #expect(vm.isLoading == false)
    }

    @Test("取得エラー時に errorMessage がセットされる")
    func loadConnections_error() async {
        let repo = MockRemoteConnectionRepository()
        repo.shouldThrow = true
        let vm = HomeViewModel(remoteConnectionRepository: repo)

        await vm.loadConnections()

        #expect(vm.connections.isEmpty)
        #expect(vm.errorMessage != nil)
    }

    // MARK: - delete

    @Test("接続先を削除すると一覧から消える")
    func delete_success() async {
        let repo = MockRemoteConnectionRepository()
        let connection = ModelFactory.makeConnection(displayName: "削除対象NAS")
        repo.connections = [connection]

        let vm = HomeViewModel(remoteConnectionRepository: repo)
        await vm.loadConnections()
        #expect(vm.connections.count == 1)

        await vm.delete(connection)

        #expect(vm.connections.isEmpty)
        #expect(repo.deletedConnections.count == 1)
    }

    @Test("削除エラー時に errorMessage がセットされる")
    func delete_error() async {
        let repo = MockRemoteConnectionRepository()
        let connection = ModelFactory.makeConnection()
        repo.connections = [connection]

        let vm = HomeViewModel(remoteConnectionRepository: repo)
        await vm.loadConnections()

        repo.shouldThrow = true
        await vm.delete(connection)

        #expect(vm.errorMessage != nil)
        #expect(vm.connections.count == 1)
    }
}
