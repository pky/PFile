@testable import PFile
import UIKit

final class MockMediaThumbnailProvider: MediaThumbnailProviding {
    struct LoadCall {
        let source: ContentSource
        let itemPath: String
        let connectionID: UUID?
    }

    struct CacheCall {
        let source: ContentSource
        let itemPath: String
    }

    var cachedImage: UIImage?
    var loadedImage: UIImage?
    private(set) var cacheCalls: [CacheCall] = []
    private(set) var loadCalls: [LoadCall] = []

    func thumbnail(for source: ContentSource, item: DirectoryItem) -> UIImage? {
        cacheCalls.append(CacheCall(source: source, itemPath: item.path))
        return cachedImage
    }

    func loadThumbnail(
        for source: ContentSource,
        item: DirectoryItem,
        connection: RemoteConnection?
    ) async -> UIImage? {
        loadCalls.append(LoadCall(source: source, itemPath: item.path, connectionID: connection?.id))
        return loadedImage
    }

    func cacheKey(source: ContentSource, item: DirectoryItem) -> String {
        "\(source.id)|\(item.path)"
    }
}
