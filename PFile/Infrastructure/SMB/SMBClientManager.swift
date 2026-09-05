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

    // 切断は必ず gracefully: true で行う。
    // AMSMB2 の disconnect は libsmb2 の開いているディレクトリをすべて解放するため、
    // 同じクライアントで contentsOfDirectory が走っている最中に即時切断すると
    // 列挙中のエントリ名が解放済みメモリを指し、strlen で EXC_BAD_ACCESS になる。
    func reconnectClient(for connection: RemoteConnection) throws -> SMB2Manager {
        let oldClient: SMB2Manager?
        let newClient = try makeClient(for: connection)

        lock.lock()
        oldClient = clients[connection.id]
        clients[connection.id] = newClient
        lock.unlock()

        Task {
            try? await SMB2OperationGate.runAsync {
                try await oldClient?.disconnectShare(gracefully: true)
            }
        }
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

    func warmUpShare(for connection: RemoteConnection, at path: String) async throws {
        let credential = try loadCredential(for: connection)
        let shareName = credential.shareName == "/" ? "" : credential.shareName
        let client = try client(for: connection)

        do {
            try await warmUp(client: client, shareName: shareName, path: path)
        } catch {
            let reconnectedClient = try reconnectClient(for: connection)
            try await warmUp(client: reconnectedClient, shareName: shareName, path: path)
        }
    }

    /// 指定ファイルの途中をランダムに 1MiB 読み、NAS の HDD を起こす。
    func warmUpFile(for connection: RemoteConnection, at path: String, fileSize: Int64?) async throws {
        let credential = try loadCredential(for: connection)
        let shareName = credential.shareName == "/" ? "" : credential.shareName
        let client = try client(for: connection)

        do {
            try await readWarmUpBlock(client: client, shareName: shareName, path: path, fileSize: fileSize)
        } catch {
            let reconnectedClient = try reconnectClient(for: connection)
            try await readWarmUpBlock(client: reconnectedClient, shareName: shareName, path: path, fileSize: fileSize)
        }
    }

    /// ディレクトリ配下（深さ 3 まで）から最大の動画を探し、その途中をランダムに読む。
    func warmUpDirectoryFile(for connection: RemoteConnection, at path: String) async throws {
        let credential = try loadCredential(for: connection)
        let shareName = credential.shareName == "/" ? "" : credential.shareName
        let client = try client(for: connection)

        do {
            try await warmUpDirectoryFile(client: client, shareName: shareName, path: path)
        } catch {
            let reconnectedClient = try reconnectClient(for: connection)
            try await warmUpDirectoryFile(client: reconnectedClient, shareName: shareName, path: path)
        }
    }

    func disconnect(for connectionId: UUID) {
        lock.lock()
        let client = clients[connectionId]
        clients.removeValue(forKey: connectionId)
        lock.unlock()
        Task {
            try? await SMB2OperationGate.runAsync {
                try await client?.disconnectShare(gracefully: true)
            }
        }
    }

    func disconnectAll() {
        lock.lock()
        let all = Array(clients.values)
        clients.removeAll()
        lock.unlock()
        Task {
            for c in all {
                try? await SMB2OperationGate.runAsync {
                    try await c.disconnectShare(gracefully: true)
                }
            }
        }
    }

    private func buildURL(host: String, port: Int, share: String) -> URL {
        var c = URLComponents()
        c.scheme = "smb"
        c.host   = host
        c.port   = port != 445 ? port : nil
        c.path   = "/\(share)"
        return c.url!
    }

    private func warmUp(client: SMB2Manager, shareName: String, path: String) async throws {
        try await SMB2OperationGate.runAsync {
            try await client.connectShare(name: shareName)
        }
        let directoryPath = normalizedRelativePath(path)
        _ = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[[URLResourceKey: any Sendable]], Error>) in
            client.contentsOfDirectory(atPath: directoryPath) { cont.resume(with: $0) }
        }
    }

    private func normalizedRelativePath(_ path: String) -> String {
        let relative = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return relative.precomposedStringWithCanonicalMapping
    }

    private func readWarmUpBlock(
        client: SMB2Manager,
        shareName: String,
        path: String,
        fileSize: Int64?
    ) async throws {
        try await SMB2OperationGate.runAsync {
            try await client.connectShare(name: shareName)
        }
        let filePath = normalizedRelativePath(path)
        let range = SMBWarmUpPlanner.readRange(fileSize: fileSize)
        _ = try await client.contents(atPath: filePath, range: range)
    }

    private func warmUpDirectoryFile(client: SMB2Manager, shareName: String, path: String) async throws {
        try await SMB2OperationGate.runAsync {
            try await client.connectShare(name: shareName)
        }
        guard let target = try await findWarmUpTarget(client: client, path: path, remainingDepth: 3) else {
            return
        }
        let range = SMBWarmUpPlanner.readRange(fileSize: target.size)
        _ = try await client.contents(atPath: normalizedRelativePath(target.path), range: range)
    }

    private func findWarmUpTarget(
        client: SMB2Manager,
        path: String,
        remainingDepth: Int
    ) async throws -> DirectoryItem? {
        let directoryPath = normalizedRelativePath(path)
        let entries = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[[URLResourceKey: any Sendable]], Error>) in
            client.contentsOfDirectory(atPath: directoryPath) { cont.resume(with: $0) }
        }
        let items = entries.compactMap { DirectoryItem(smbEntry: $0, parentPath: path) }
        if let target = SMBWarmUpPlanner.preferredItem(in: items) {
            return target
        }

        guard remainingDepth > 0 else { return nil }

        for directory in items.filter(\.isDirectory).prefix(12) {
            if let target = try? await findWarmUpTarget(
                client: client,
                path: directory.path,
                remainingDepth: remainingDepth - 1
            ) {
                return target
            }
        }

        return nil
    }

#else

    // Simulator 用スタブ
    func warmUpShare(for connection: RemoteConnection, at path: String) async throws {
        throw SMBClientError.simulatorUnsupported
    }

    func warmUpFile(for connection: RemoteConnection, at path: String, fileSize: Int64?) async throws {
        throw SMBClientError.simulatorUnsupported
    }

    func warmUpDirectoryFile(for connection: RemoteConnection, at path: String) async throws {
        throw SMBClientError.simulatorUnsupported
    }

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
