import Foundation

final class LocalFileRepository: FileRepository {

    private let rootURL: URL
    private let fileManager = FileManager.default

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    func listDirectory(at path: String) async throws -> [DirectoryItem] {
        let directoryURL = URL(fileURLWithPath: path)
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .nameKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .creationDateKey,
            .isHiddenKey,
        ]
        let urls = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants]
        )
        return try urls.compactMap { url in
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isHidden == true { return nil }
            return SourceDirectoryItemAdapter.localFile(url: url, values: values)
        }
    }

    func fileExists(at path: String) async throws -> Bool {
        fileManager.fileExists(atPath: path)
    }

    func download(from remotePath: String, to localURL: URL, progress: ((Double) -> Void)?) async throws {
        _ = progress
        if fileManager.fileExists(atPath: localURL.path) {
            try fileManager.removeItem(at: localURL)
        }
        try fileManager.copyItem(at: URL(fileURLWithPath: remotePath), to: localURL)
    }

    func upload(from localURL: URL, to remotePath: String, progress: ((Double) -> Void)?) async throws {
        _ = progress
        let destinationURL = URL(fileURLWithPath: remotePath)
        let parentURL = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true, attributes: nil)
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.copyItem(at: localURL, to: destinationURL)
    }

    func createDirectory(at path: String) async throws {
        try fileManager.createDirectory(at: URL(fileURLWithPath: path), withIntermediateDirectories: true, attributes: nil)
    }

    func delete(at path: String) async throws {
        try fileManager.removeItem(at: URL(fileURLWithPath: path))
    }

    func move(from sourcePath: String, to destinationPath: String) async throws {
        try fileManager.moveItem(at: URL(fileURLWithPath: sourcePath), to: URL(fileURLWithPath: destinationPath))
    }

    func copy(from sourcePath: String, to destinationPath: String) async throws {
        try fileManager.copyItem(at: URL(fileURLWithPath: sourcePath), to: URL(fileURLWithPath: destinationPath))
    }

    func rename(at path: String, to newName: String) async throws {
        let sourceURL = URL(fileURLWithPath: path)
        let destinationURL = sourceURL.deletingLastPathComponent().appendingPathComponent(newName)
        try fileManager.moveItem(at: sourceURL, to: destinationURL)
    }

    var rootPath: String { rootURL.path }
}
