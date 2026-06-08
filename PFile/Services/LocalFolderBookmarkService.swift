import Foundation

enum LocalFolderBookmarkService {

    struct ResolvedBookmark {
        let url: URL
        let isStale: Bool
    }

    static func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: bookmarkCreationOptions,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    static func resolveBookmark(from bookmarkData: Data) throws -> ResolvedBookmark {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: bookmarkData,
            options: bookmarkResolutionOptions,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return ResolvedBookmark(url: url, isStale: isStale)
    }

    static func resolveURL(from bookmarkData: Data) throws -> URL {
        try resolveBookmark(from: bookmarkData).url
    }

    private static var bookmarkCreationOptions: URL.BookmarkCreationOptions {
#if os(iOS)
        return []
#else
        return [.withSecurityScope]
#endif
    }

    private static var bookmarkResolutionOptions: URL.BookmarkResolutionOptions {
#if os(iOS)
        return []
#else
        return [.withSecurityScope]
#endif
    }
}
