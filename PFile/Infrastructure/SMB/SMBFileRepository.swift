import Foundation

#if !targetEnvironment(simulator)
import AMSMB2
#endif

// MARK: - SMBFileRepository

final class SMBFileRepository: FileRepository {

    private let connection: RemoteConnection
    private let clientManager: SMBClientManager
    private let shareName: String

    init(connection: RemoteConnection, clientManager: SMBClientManager) throws {
        self.connection = connection
        self.clientManager = clientManager
#if targetEnvironment(simulator)
        self.shareName = ""
#else
        let credential = try clientManager.loadCredential(for: connection)
        // "/" はルートブラウズ用のデフォルト値。connectShare には空文字を渡す
        self.shareName = credential.shareName == "/" ? "" : credential.shareName
#endif
    }

#if targetEnvironment(simulator)

    // Simulator 用スタブ：ユニットテストは MockFileRepository を使うためここには到達しない
    func listDirectory(at path: String) async throws -> [DirectoryItem] { throw SMBClientError.simulatorUnsupported }
    func fileExists(at path: String) async throws -> Bool { throw SMBClientError.simulatorUnsupported }
    func download(from remotePath: String, to localURL: URL, progress: ((Double) -> Void)?) async throws { throw SMBClientError.simulatorUnsupported }
    func upload(from localURL: URL, to remotePath: String, progress: ((Double) -> Void)?) async throws { throw SMBClientError.simulatorUnsupported }
    func createDirectory(at path: String) async throws { throw SMBClientError.simulatorUnsupported }
    func delete(at path: String) async throws { throw SMBClientError.simulatorUnsupported }
    func move(from sourcePath: String, to destinationPath: String) async throws { throw SMBClientError.simulatorUnsupported }
    func copy(from sourcePath: String, to destinationPath: String) async throws { throw SMBClientError.simulatorUnsupported }
    func rename(at path: String, to newName: String) async throws { throw SMBClientError.simulatorUnsupported }

#else

    func listDirectory(at path: String) async throws -> [DirectoryItem] {
        let client = try await connectedClient()
        let resolvedPath = try await resolveExistingPath(path, client: client, preferDirectoryListing: true)
        let entries = try await listDirectoryEntries(at: resolvedPath, client: client)
        return entries.compactMap { DirectoryItem(smbEntry: $0, parentPath: path) }
    }

    func fileExists(at path: String) async throws -> Bool {
        let client = try await connectedClient()
        for candidate in candidateRelativePaths(for: path) {
            if await pathExists(candidate, client: client) {
                return true
            }
        }
        return false
    }

    func download(from remotePath: String, to localURL: URL, progress: ((Double) -> Void)?) async throws {
        let client = try await connectedClient()
        let resolvedPath = try await resolveExistingPath(remotePath, client: client)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            client.downloadItem(atPath: resolvedPath, to: localURL, progress: { bytes, total in
                progress?(total > 0 ? Double(bytes) / Double(total) : 0)
                return true
            }) { e in e == nil ? cont.resume() : cont.resume(throwing: e!) }
        }
    }

    func upload(from localURL: URL, to remotePath: String, progress: ((Double) -> Void)?) async throws {
        let client = try await connectedClient()
        var sent: Int64 = 0
        let destinationPath = normalizedRelativePath(remotePath)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            client.uploadItem(at: localURL, toPath: destinationPath, progress: { bytes in
                sent += bytes; progress?(Double(sent)); return true
            }) { e in e == nil ? cont.resume() : cont.resume(throwing: e!) }
        }
    }

    func createDirectory(at path: String) async throws {
        let client = try await connectedClient()
        let destinationPath = normalizedRelativePath(path)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            client.createDirectory(atPath: destinationPath) { e in e == nil ? cont.resume() : cont.resume(throwing: e!) }
        }
    }

    func delete(at path: String) async throws {
        let client = try await connectedClient()
        let resolvedPath = try await resolveExistingPath(path, client: client)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            client.removeItem(atPath: resolvedPath) { e in e == nil ? cont.resume() : cont.resume(throwing: e!) }
        }
    }

    func move(from sourcePath: String, to destinationPath: String) async throws {
        let client = try await connectedClient()
        let resolvedSourcePath = try await resolveExistingPath(sourcePath, client: client)
        let normalizedDestinationPath = normalizedRelativePath(destinationPath)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            client.moveItem(atPath: resolvedSourcePath, toPath: normalizedDestinationPath) { e in e == nil ? cont.resume() : cont.resume(throwing: e!) }
        }
    }

    func copy(from sourcePath: String, to destinationPath: String) async throws {
        let client = try await connectedClient()
        let resolvedSourcePath = try await resolveExistingPath(sourcePath, client: client)
        let normalizedDestinationPath = normalizedRelativePath(destinationPath)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            client.copyItem(atPath: resolvedSourcePath, toPath: normalizedDestinationPath, recursive: true, progress: nil) { e in e == nil ? cont.resume() : cont.resume(throwing: e!) }
        }
    }

    func rename(at path: String, to newName: String) async throws {
        let dir  = (path as NSString).deletingLastPathComponent
        let dest = (dir as NSString).appendingPathComponent(newName)
        try await move(from: path, to: dest)
    }

    // MARK: - Private

    private func connectShare(_ client: SMB2Manager) async throws {
        try await client.connectShare(name: shareName)
    }

    private func connectedClient() async throws -> SMB2Manager {
        let client = try clientManager.client(for: connection)
        do {
            try await connectShare(client)
            return client
        } catch {
            let reconnectedClient = try clientManager.reconnectClient(for: connection)
            try await connectShare(reconnectedClient)
            return reconnectedClient
        }
    }

    private func resolveExistingPath(
        _ path: String,
        client: SMB2Manager,
        preferDirectoryListing: Bool = false
    ) async throws -> String {
        let candidates = candidateRelativePaths(for: path)
        if candidates.count == 1 {
            return candidates[0]
        }

        for candidate in candidates {
            if preferDirectoryListing {
                if (try? await listDirectoryEntries(at: candidate, client: client)) != nil {
                    return candidate
                }
            } else if await pathExists(candidate, client: client) {
                return candidate
            }
        }

        return candidates[0]
    }

    private func listDirectoryEntries(
        at path: String,
        client: SMB2Manager
    ) async throws -> [[URLResourceKey: any Sendable]] {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[[URLResourceKey: any Sendable]], Error>) in
            client.contentsOfDirectory(atPath: path) { cont.resume(with: $0) }
        }
    }

    private func pathExists(_ path: String, client: SMB2Manager) async -> Bool {
        await withCheckedContinuation { cont in
            client.attributesOfItem(atPath: path) { result in
                switch result {
                case .success:
                    cont.resume(returning: true)
                case .failure:
                    cont.resume(returning: false)
                }
            }
        }
    }

    private func candidateRelativePaths(for path: String) -> [String] {
        let original = rawRelativePath(path)
        let normalized = original.precomposedStringWithCanonicalMapping
        if normalized == original {
            return [normalized]
        }
        return [normalized, original]
    }

    private func normalizedRelativePath(_ path: String) -> String {
        rawRelativePath(path).precomposedStringWithCanonicalMapping
    }

    private func rawRelativePath(_ path: String) -> String {
        path.hasPrefix("/") ? String(path.dropFirst()) : path
    }

#endif
}

// MARK: - DirectoryItem + SMB entry

#if !targetEnvironment(simulator)
private extension DirectoryItem {
    init?(smbEntry entry: [URLResourceKey: any Sendable], parentPath: String) {
        guard let name = entry[.nameKey] as? String, !name.hasPrefix(".") else { return nil }
        let isDir = entry[.isDirectoryKey] as? Bool ?? false
        let rawPath = entry[.pathKey] as? String
        let path = Self.absoluteSMBPath(parentPath: parentPath, name: name, rawPath: rawPath)
        self.name       = name
        self.path       = path
        self.size       = isDir ? nil : (entry[.fileSizeKey] as? Int64)
        self.modifiedAt = entry[.contentModificationDateKey] as? Date
        self.createdAt  = entry[.creationDateKey] as? Date
        self.itemType   = isDir ? .directory : .from(fileName: name)
        // inode番号（0は無効値のためnilに変換）
        let ino = entry[.documentIdentifierKey] as? UInt64 ?? 0
        self.fileId = ino > 0 ? ino : nil
    }

    private static func absoluteSMBPath(parentPath: String, name: String, rawPath: String?) -> String {
        let normalizedParent: String = {
            if parentPath.isEmpty { return "/" }
            if parentPath.hasPrefix("/") { return parentPath }
            return "/\(parentPath)"
        }()

        if let rawPath, rawPath.hasPrefix("/") {
            return rawPath
        }

        let parentURL = URL(fileURLWithPath: normalizedParent, isDirectory: true)
        return parentURL.appendingPathComponent(name).path
    }
}
#endif
