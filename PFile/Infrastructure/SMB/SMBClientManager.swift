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

    func warmUpFile(for connection: RemoteConnection, at path: String) async throws {
        let credential = try loadCredential(for: connection)
        let shareName = credential.shareName == "/" ? "" : credential.shareName
        let client = try client(for: connection)

        do {
            try await readFileHeader(client: client, shareName: shareName, path: path)
        } catch {
            let reconnectedClient = try reconnectClient(for: connection)
            try await readFileHeader(client: reconnectedClient, shareName: shareName, path: path)
        }
    }

    func warmUpFirstReadableFile(for connection: RemoteConnection, at path: String) async throws {
        let credential = try loadCredential(for: connection)
        let shareName = credential.shareName == "/" ? "" : credential.shareName
        let client = try client(for: connection)

        do {
            try await warmUpFirstReadableFile(client: client, shareName: shareName, path: path)
        } catch {
            let reconnectedClient = try reconnectClient(for: connection)
            try await warmUpFirstReadableFile(client: reconnectedClient, shareName: shareName, path: path)
        }
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

    private func warmUp(client: SMB2Manager, shareName: String, path: String) async throws {
        try await client.connectShare(name: shareName)
        let directoryPath = normalizedRelativePath(path)
        _ = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[[URLResourceKey: any Sendable]], Error>) in
            client.contentsOfDirectory(atPath: directoryPath) { cont.resume(with: $0) }
        }
    }

    private func normalizedRelativePath(_ path: String) -> String {
        let relative = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return relative.precomposedStringWithCanonicalMapping
    }

    private func readFileHeader(client: SMB2Manager, shareName: String, path: String) async throws {
        try await client.connectShare(name: shareName)
        let filePath = normalizedRelativePath(path)
        _ = try await client.contents(atPath: filePath, range: UInt64(0)..<UInt64(1024 * 1024))
    }

    private func warmUpFirstReadableFile(client: SMB2Manager, shareName: String, path: String) async throws {
        try await client.connectShare(name: shareName)
        let rootPath = normalizedRelativePath(path)
        guard let filePath = try await findFirstReadableFilePath(client: client, path: rootPath, remainingDepth: 3) else {
            return
        }
        _ = try await client.contents(atPath: filePath, range: UInt64(0)..<UInt64(1024 * 1024))
    }

    private func findFirstReadableFilePath(
        client: SMB2Manager,
        path: String,
        remainingDepth: Int
    ) async throws -> String? {
        let entries = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[[URLResourceKey: any Sendable]], Error>) in
            client.contentsOfDirectory(atPath: path) { cont.resume(with: $0) }
        }

        let visibleEntries = entries.filter { entry in
            guard let name = entry[.nameKey] as? String else { return false }
            return !name.hasPrefix(".")
        }

        if let file = visibleEntries.first(where: { ($0[.isDirectoryKey] as? Bool) != true }),
           let filePath = warmUpEntryPath(file, parentPath: path) {
            return filePath
        }

        guard remainingDepth > 0 else { return nil }

        for directory in visibleEntries.prefix(12) where (directory[.isDirectoryKey] as? Bool) == true {
            guard let directoryPath = warmUpEntryPath(directory, parentPath: path) else { continue }
            if let filePath = try? await findFirstReadableFilePath(
                client: client,
                path: directoryPath,
                remainingDepth: remainingDepth - 1
            ) {
                return filePath
            }
        }

        return nil
    }

    private func warmUpEntryPath(_ entry: [URLResourceKey: any Sendable], parentPath: String) -> String? {
        guard let name = entry[.nameKey] as? String else { return nil }
        let parent = parentPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let pathFromParent = parent.isEmpty ? name : "\(parent)/\(name)"
        if !pathFromParent.isEmpty {
            return normalizedRelativePath(pathFromParent)
        }
        if let rawPath = entry[.pathKey] as? String {
            return normalizedRelativePath(rawPath)
        }
        return nil
    }

#else

    // Simulator 用スタブ
    func warmUpShare(for connection: RemoteConnection, at path: String) async throws {
        throw SMBClientError.simulatorUnsupported
    }

    func warmUpFile(for connection: RemoteConnection, at path: String) async throws {
        throw SMBClientError.simulatorUnsupported
    }

    func warmUpFirstReadableFile(for connection: RemoteConnection, at path: String) async throws {
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
