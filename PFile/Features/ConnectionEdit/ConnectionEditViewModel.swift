import Foundation

#if !targetEnvironment(simulator)
import AMSMB2
#endif

@Observable
final class ConnectionEditViewModel {

    var displayName: String

    var host: String {
        didSet { if host != oldValue { connectionTested = false } }
    }
    var port: String {
        didSet { if port != oldValue { connectionTested = false } }
    }
    var username: String {
        didSet { if username != oldValue { connectionTested = false } }
    }
    var password: String {
        didSet { if password != oldValue { connectionTested = false } }
    }
    var shareName: String {
        didSet { if shareName != oldValue { connectionTested = false } }
    }

    var isLoading = false
    var isFetchingShares = false
    var isTesting = false
    var connectionTested = false
    var availableShares: [String] = []
    var errorMessage: String?

    private let connection: RemoteConnection
    private let remoteConnectionRepository: any RemoteConnectionRepository
    private let smbClientManager: SMBClientManager

    init(
        connection: RemoteConnection,
        remoteConnectionRepository: any RemoteConnectionRepository,
        smbClientManager: SMBClientManager
    ) {
        self.connection = connection
        self.remoteConnectionRepository = remoteConnectionRepository
        self.smbClientManager = smbClientManager

        self.displayName = connection.displayName
        self.host = connection.host ?? ""
        self.port = connection.port.map(String.init) ?? ""
        self.username = connection.username ?? ""

        let credential = try? smbClientManager.loadCredential(for: connection)
        let savedShare = (credential?.shareName == "/" || credential?.shareName == nil) ? "" : (credential?.shareName ?? "")
        let savedPath  = connection.startPath == "/" ? "" : String(connection.startPath.drop(while: { $0 == "/" }))
        self.shareName = savedPath.isEmpty ? savedShare : (savedShare.isEmpty ? savedPath : "\(savedShare)/\(savedPath)")
        self.password = credential?.password ?? ""
    }

    var canSave: Bool {
        !displayName.isEmpty && !host.isEmpty
    }

    // MARK: - Actions

    func testConnection() async {
        guard !host.isEmpty else { return }
        isTesting = true
        connectionTested = false
        errorMessage = nil
        defer { isTesting = false }

#if targetEnvironment(simulator)
        connectionTested = true
#else
        do {
            try await performConnectionTest()
            connectionTested = true
        } catch {
            errorMessage = connectionErrorMessage(error)
        }
#endif
    }

    func fetchShares() async {
        guard !host.isEmpty else { return }
        isFetchingShares = true
        errorMessage = nil
        defer { isFetchingShares = false }

#if targetEnvironment(simulator)
        errorMessage = "共有フォルダの取得は実機でのみ使用できます"
#else
        do {
            let portNum = Int(port) ?? 445
            guard let url = URL(string: "smb://\(host)\(portNum != 445 ? ":\(portNum)" : "")") else {
                errorMessage = "無効なホスト名です"
                return
            }
            let credential = URLCredential(
                user: username.isEmpty ? "guest" : username,
                password: password,
                persistence: .forSession
            )
            guard let client = SMB2Manager(url: url, credential: credential) else {
                errorMessage = "接続クライアントの初期化に失敗しました"
                return
            }
            let shares = try await client.listShares()
            let names = shares.map(\.name)
            availableShares = names
            if names.count == 1 { shareName = names[0] }
        } catch {
            errorMessage = "共有フォルダの取得に失敗しました: \(error.localizedDescription)"
        }
#endif
    }

    func save() async throws {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

#if !targetEnvironment(simulator)
        do {
            try await performConnectionTest()
        } catch {
            errorMessage = connectionErrorMessage(error)
            throw error
        }
#endif

        let (effectiveShare, startPath) = parseShareInput(shareName)

        // RemoteConnection は参照型。プロパティを直接更新する
        connection.displayName = displayName
        connection.host = host.isEmpty ? nil : host
        connection.port = Int(port) ?? connection.serviceType.defaultPort
        connection.username = username.isEmpty ? nil : username
        connection.startPath = startPath

        struct SMBCredential: Codable {
            let shareName: String
            let username: String
            let password: String
        }
        let credential = SMBCredential(
            shareName: effectiveShare,
            username: username,
            password: password
        )
        try KeychainService.shared.save(credential, key: connection.keychainIdentifier)

        do {
            try await remoteConnectionRepository.update(connection)
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    // MARK: - Private

#if !targetEnvironment(simulator)
    private func performConnectionTest() async throws {
        let portNum = Int(port) ?? 445
        guard let url = URL(string: "smb://\(host)\(portNum != 445 ? ":\(portNum)" : "")") else {
            throw URLError(.badURL)
        }
        let credential = URLCredential(
            user: username.isEmpty ? "guest" : username,
            password: password,
            persistence: .forSession
        )
        guard let client = SMB2Manager(url: url, credential: credential) else {
            throw SMBClientError.invalidURL
        }
        let (effectiveShare, _) = parseShareInput(shareName)
        if effectiveShare == "/" {
            _ = try await client.listShares()
        } else {
            try await client.connectShare(name: effectiveShare)
            try? await client.disconnectShare()
        }
    }
#endif

    /// "videos/movies" → (shareName: "videos", startPath: "/movies")
    private func parseShareInput(_ input: String) -> (shareName: String, startPath: String) {
        let parts = input.trimmingCharacters(in: .whitespaces)
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard !parts.isEmpty else { return (shareName: "/", startPath: "/") }
        let share = parts[0]
        let subPath = parts.count > 1 ? "/" + parts.dropFirst().joined(separator: "/") : "/"
        return (shareName: share, startPath: subPath)
    }

    private func connectionErrorMessage(_ error: Error) -> String {
        let desc = error.localizedDescription.lowercased()
        if desc.contains("timeout") || desc.contains("timed out") {
            return "接続タイムアウト: ホストアドレスを確認してください"
        } else if desc.contains("auth") || desc.contains("credential") || desc.contains("password") {
            return "認証失敗: ユーザー名・パスワードを確認してください"
        } else if desc.contains("not found") || desc.contains("no route") {
            return "ホストが見つかりません: IPアドレスを確認してください"
        } else {
            return "接続失敗: \(error.localizedDescription)"
        }
    }
}
