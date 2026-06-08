import Foundation

// AMSMB2 は実機専用ライブラリ（libsmb2-ios.a に arm64-simulator スライスがない）
// Simulator ビルド時は import せず、stub で代替する
#if !targetEnvironment(simulator)
import AMSMB2
#endif

final class SMBClientManager {

    struct SMBCredential: Codable {
        let shareName: String
        let username: String
        let password: String
    }

    func loadCredential(for connection: RemoteConnection) throws -> SMBCredential {
        try KeychainService.shared.load(SMBCredential.self, key: connection.keychainIdentifier)
    }

#if !targetEnvironment(simulator)

    private var clients: [UUID: SMB2Manager] = [:]
    private let lock = NSLock()

    func client(for connection: RemoteConnection) throws -> SMB2Manager {
        lock.lock()
        defer { lock.unlock() }
        if let existing = clients[connection.id] { return existing }
        let client = try makeClient(for: connection)
        clients[connection.id] = client
        return client
    }

    func reconnectClient(for connection: RemoteConnection) throws -> SMB2Manager {
        let oldClient: SMB2Manager?
        let newClient = try makeClient(for: connection)

        lock.lock()
        oldClient = clients[connection.id]
        clients[connection.id] = newClient
        lock.unlock()

        Task { try? await oldClient?.disconnectShare() }
        return newClient
    }

    private func makeClient(for connection: RemoteConnection) throws -> SMB2Manager {
        let credential = try loadCredential(for: connection)
        let url = buildURL(
            host: connection.host ?? "",
            port: connection.port ?? ServiceType.smb.defaultPort ?? 445,
            share: credential.shareName
        )
        let urlCredential = URLCredential(
            user: credential.username,
            password: credential.password,
            persistence: .forSession
        )
        guard let client = SMB2Manager(url: url, credential: urlCredential) else {
            throw SMBClientError.invalidURL
        }
        return client
    }

    /// キャッシュを使わず専用の SMB2Manager を生成する。
    /// 動画再生など、FileBrowser の接続と競合させたくない用途に使う。
    func makeDedicatedClient(for connection: RemoteConnection) throws -> SMB2Manager {
        let credential = try loadCredential(for: connection)
        let url = buildURL(
            host: connection.host ?? "",
            port: connection.port ?? ServiceType.smb.defaultPort ?? 445,
            share: credential.shareName
        )
        let urlCredential = URLCredential(
            user: credential.username,
            password: credential.password,
            persistence: .forSession
        )
        guard let client = SMB2Manager(url: url, credential: urlCredential) else {
            throw SMBClientError.invalidURL
        }
        return client
    }

    func disconnect(for connectionId: UUID) {
        lock.lock()
        let client = clients[connectionId]
        clients.removeValue(forKey: connectionId)
        lock.unlock()
        Task { try? await client?.disconnectShare() }
    }

    func disconnectAll() {
        lock.lock()
        let all = Array(clients.values)
        clients.removeAll()
        lock.unlock()
        Task { for c in all { try? await c.disconnectShare() } }
    }

    private func buildURL(host: String, port: Int, share: String) -> URL {
        var c = URLComponents()
        c.scheme = "smb"
        c.host   = host
        c.port   = port != 445 ? port : nil
        c.path   = "/\(share)"
        return c.url!
    }

#else

    // Simulator 用スタブ
    func disconnect(for connectionId: UUID) {}
    func disconnectAll() {}

#endif
}

enum SMBClientError: LocalizedError {
    case invalidURL
    case simulatorUnsupported

    var errorDescription: String? {
        switch self {
        case .invalidURL:            return "無効なSMB URLです"
        case .simulatorUnsupported:  return "SMB接続はSimulatorでは使用できません"
        }
    }
}
