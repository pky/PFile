@testable import PFile
import Foundation

final class MockFileRepository: FileRepository {

    var items: [DirectoryItem] = []
    var directoryItemsByPath: [String: [DirectoryItem]] = [:]
    var shouldThrow = false
    var listedPaths: [String] = []

    func listDirectory(at path: String) async throws -> [DirectoryItem] {
        if shouldThrow { throw TestError.mock }
        listedPaths.append(path)
        return directoryItemsByPath[path] ?? items
    }

    func fileExists(at path: String) async throws -> Bool {
        if shouldThrow { throw TestError.mock }
        return items.contains { $0.path == path }
    }

    func download(from remotePath: String, to localURL: URL, progress: ((Double) -> Void)?) async throws {
        if shouldThrow { throw TestError.mock }
    }

    func upload(from localURL: URL, to remotePath: String, progress: ((Double) -> Void)?) async throws {
        if shouldThrow { throw TestError.mock }
    }

    func createDirectory(at path: String) async throws {
        if shouldThrow { throw TestError.mock }
    }

    func delete(at path: String) async throws {
        if shouldThrow { throw TestError.mock }
        items.removeAll { $0.path == path }
    }

    func move(from sourcePath: String, to destinationPath: String) async throws {
        if shouldThrow { throw TestError.mock }
    }

    func copy(from sourcePath: String, to destinationPath: String) async throws {
        if shouldThrow { throw TestError.mock }
    }

    func rename(at path: String, to newName: String) async throws {
        if shouldThrow { throw TestError.mock }
    }
}
