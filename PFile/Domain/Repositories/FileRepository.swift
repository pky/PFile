import Foundation

protocol FileRepository {
    func listDirectory(at path: String) async throws -> [DirectoryItem]
    func fileExists(at path: String) async throws -> Bool
    func download(from remotePath: String, to localURL: URL, progress: ((Double) -> Void)?) async throws
    func upload(from localURL: URL, to remotePath: String, progress: ((Double) -> Void)?) async throws
    func createDirectory(at path: String) async throws
    func delete(at path: String) async throws
    func move(from sourcePath: String, to destinationPath: String) async throws
    func copy(from sourcePath: String, to destinationPath: String) async throws
    func rename(at path: String, to newName: String) async throws
}

extension FileRepository {
    func collectMediaItemsRecursively(from items: [DirectoryItem]) async throws -> [DirectoryItem] {
        var results: [DirectoryItem] = []
        var visitedPaths = Set<String>()

        func visit(_ item: DirectoryItem) async throws {
            guard visitedPaths.insert(item.path).inserted else { return }
            if item.isMedia {
                results.append(item)
                return
            }
            guard item.isDirectory else { return }
            let children = try await listDirectory(at: item.path)
            for child in children {
                try await visit(child)
            }
        }

        for item in items {
            try await visit(item)
        }
        return results
    }

    func findMediaItemRecursively(at rootPath: String, matchingFileId fileId: UInt64) async throws -> DirectoryItem? {
        var visitedPaths = Set<String>()

        func visit(path: String) async throws -> DirectoryItem? {
            guard visitedPaths.insert(path).inserted else { return nil }

            let children = try await listDirectory(at: path)
            for child in children {
                if child.isMedia, child.fileId == fileId {
                    return child
                }
                if child.isDirectory, let found = try await visit(path: child.path) {
                    return found
                }
            }
            return nil
        }

        return try await visit(path: rootPath)
    }

    func comicImageItemsIfEligible(in folder: DirectoryItem) async throws -> [DirectoryItem]? {
        guard folder.isDirectory else { return nil }
        let children = try await listDirectory(at: folder.path)
        let imageItems = children.filter(\.isImage)
        guard imageItems.count >= 2 else { return nil }
        return imageItems
    }
}
