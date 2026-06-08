@testable import PFile
import Testing

@MainActor
struct ConnectionEditViewModelTests {

    private func makeConnection() -> RemoteConnection {
        ModelFactory.makeConnection(displayName: "テスト接続", host: "nas-edit.example.local")
    }

    private func makeViewModel(connection: RemoteConnection, repo: MockRemoteConnectionRepository? = nil) -> (ConnectionEditViewModel, MockRemoteConnectionRepository) {
        let r = repo ?? MockRemoteConnectionRepository()
        r.connections = [connection]
        let vm = ConnectionEditViewModel(
            connection: connection,
            remoteConnectionRepository: r,
            smbClientManager: SMBClientManager()
        )
        return (vm, r)
    }

    // MARK: - init

    @Test("initでconnectionの基本情報が読み込まれる")
    func init_prefillsBasicInfo() {
        let connection = makeConnection()
        let (vm, _) = makeViewModel(connection: connection)

        #expect(vm.displayName == "テスト接続")
        #expect(vm.host == "nas-edit.example.local")
    }

    // MARK: - canSave

    @Test("displayNameが空のとき canSave が false")
    func canSave_falseWhenDisplayNameEmpty() {
        let connection = makeConnection()
        let (vm, _) = makeViewModel(connection: connection)
        vm.displayName = ""

        #expect(vm.canSave == false)
    }

    @Test("hostが空のとき canSave が false")
    func canSave_falseWhenHostEmpty() {
        let connection = makeConnection()
        let (vm, _) = makeViewModel(connection: connection)
        vm.host = ""

        #expect(vm.canSave == false)
    }

    @Test("displayNameとhostが非空のとき canSave が true")
    func canSave_trueWhenBothNonEmpty() {
        let connection = makeConnection()
        let (vm, _) = makeViewModel(connection: connection)

        #expect(vm.canSave == true)
    }

    // MARK: - connectionTested リセット

    @Test("host変更後に connectionTested がリセットされる")
    func connectionTested_resetsOnHostChange() {
        let connection = makeConnection()
        let (vm, _) = makeViewModel(connection: connection)
        vm.connectionTested = true

        vm.host = "nas-updated.example.local"

        #expect(vm.connectionTested == false)
    }

    @Test("password変更後に connectionTested がリセットされる")
    func connectionTested_resetsOnPasswordChange() {
        let connection = makeConnection()
        let (vm, _) = makeViewModel(connection: connection)
        vm.connectionTested = true

        vm.password = "newpassword"

        #expect(vm.connectionTested == false)
    }

    @Test("shareName変更後に connectionTested がリセットされる")
    func connectionTested_resetsOnShareNameChange() {
        let connection = makeConnection()
        let (vm, _) = makeViewModel(connection: connection)
        vm.connectionTested = true

        vm.shareName = "newshare"

        #expect(vm.connectionTested == false)
    }

    // MARK: - save

    @Test("saveを呼ぶとrepositoryのupdateが呼ばれる")
    func save_callsRepositoryUpdate() async {
        let connection = makeConnection()
        let (vm, repo) = makeViewModel(connection: connection)
        vm.displayName = "更新後接続"

        try? await vm.save()

        #expect(repo.updatedConnections.count == 1)
    }

    @Test("saveでconnectionのdisplayNameが更新される")
    func save_updatesDisplayName() async {
        let connection = makeConnection()
        let (vm, _) = makeViewModel(connection: connection)
        vm.displayName = "リネーム後"

        try? await vm.save()

        #expect(connection.displayName == "リネーム後")
    }

    @Test("repositoryがエラーを返したとき errorMessage がセットされる")
    func save_setsErrorMessage_onRepositoryError() async {
        let repo = MockRemoteConnectionRepository()
        repo.shouldThrow = true
        let connection = makeConnection()
        let (vm, _) = makeViewModel(connection: connection, repo: repo)

        try? await vm.save()

        #expect(vm.errorMessage != nil)
    }
}
