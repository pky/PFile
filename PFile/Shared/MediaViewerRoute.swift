import SwiftUI

enum ReadingDirection: String {
    case rightToLeft
    case leftToRight
}

struct MediaViewerPageSource {
    enum ImagePagingOrder {
        case preserveInput
        case naturalName
    }

    let source: ContentSource
    let items: [DirectoryItem]
    let connection: RemoteConnection?
    let startPositionSeconds: Double
    let imagePagingOrder: ImagePagingOrder
    let readingDirection: ReadingDirection

    func route(for item: DirectoryItem) -> MediaViewerRoute? {
        MediaViewerRoute.make(
            source: source,
            items: items,
            initialItem: item,
            connection: connection,
            startPositionSeconds: startPositionSeconds,
            imagePagingOrder: imagePagingOrder,
            readingDirection: readingDirection
        )
    }

    func route(for file: MediaFile) -> MediaViewerRoute? {
        route(for: file.toDirectoryItem())
    }

    func route(for history: WatchHistory) -> MediaViewerRoute? {
        route(for: history.toDirectoryItem())
    }

    static func remote(connection: RemoteConnection, items: [DirectoryItem]) -> MediaViewerPageSource {
        MediaViewerPageSource(
            source: .remote(connection.id),
            items: items,
            connection: connection,
            startPositionSeconds: 0,
            imagePagingOrder: .naturalName,
            readingDirection: .rightToLeft
        )
    }

    static func localFolder(sourceID: UUID, items: [DirectoryItem]) -> MediaViewerPageSource {
        MediaViewerPageSource(
            source: .localFolder(sourceID),
            items: items,
            connection: nil,
            startPositionSeconds: 0,
            imagePagingOrder: .naturalName,
            readingDirection: .rightToLeft
        )
    }

    static func photoLibrary(items: [DirectoryItem]) -> MediaViewerPageSource {
        MediaViewerPageSource(
            source: .photoLibrary,
            items: items,
            connection: nil,
            startPositionSeconds: 0,
            imagePagingOrder: .preserveInput,
            readingDirection: .rightToLeft
        )
    }

    static func files(
        sourceID: String,
        allFiles: [MediaFile],
        connectionResolver: (MediaFile) -> RemoteConnection?,
        startPositionSeconds: Double = 0
    ) -> MediaViewerPageSource? {
        let sourceFiles = allFiles.filter { $0.sourceID == sourceID }
        guard let source = ContentSource.from(id: sourceID) else { return nil }
        let items = sourceFiles.map { $0.toDirectoryItem() }
        let connection = sourceFiles.first { connectionResolver($0) != nil }
            .flatMap { connectionResolver($0) }
        return MediaViewerPageSource(
            source: source,
            items: items,
            connection: connection,
            startPositionSeconds: startPositionSeconds,
            imagePagingOrder: .preserveInput,
            readingDirection: .rightToLeft
        )
    }

    static func history(_ history: WatchHistory) -> MediaViewerPageSource? {
        let source = ContentSource.from(id: history.sourceID) ?? history.connection.map { .remote($0.id) }
        guard let source else { return nil }
        return MediaViewerPageSource(
            source: source,
            items: [history.toDirectoryItem()],
            connection: history.connection,
            startPositionSeconds: history.lastPositionSeconds,
            imagePagingOrder: .preserveInput,
            readingDirection: .rightToLeft
        )
    }
}

struct MediaViewerRoute: Identifiable {
    let source: ContentSource
    let items: [DirectoryItem]
    let initialItem: DirectoryItem
    let connection: RemoteConnection?
    let startPositionSeconds: Double
    let readingDirection: ReadingDirection

    var id: String {
        "\(source.id)|\(initialItem.path)|\(startPositionSeconds)|\(readingDirection.rawValue)"
    }

    static func remote(
        connection: RemoteConnection,
        items: [DirectoryItem],
        initialItem: DirectoryItem,
        startPositionSeconds: Double = 0,
        readingDirection: ReadingDirection = .rightToLeft
    ) -> MediaViewerRoute {
        MediaViewerRoute(
            source: .remote(connection.id),
            items: items,
            initialItem: initialItem,
            connection: connection,
            startPositionSeconds: startPositionSeconds,
            readingDirection: readingDirection
        )
    }

    static func localFolder(
        sourceID: UUID,
        items: [DirectoryItem],
        initialItem: DirectoryItem,
        readingDirection: ReadingDirection = .rightToLeft
    ) -> MediaViewerRoute {
        MediaViewerRoute(
            source: .localFolder(sourceID),
            items: items,
            initialItem: initialItem,
            connection: nil,
            startPositionSeconds: 0,
            readingDirection: readingDirection
        )
    }

    static func photoLibrary(
        items: [DirectoryItem],
        initialItem: DirectoryItem,
        readingDirection: ReadingDirection = .rightToLeft
    ) -> MediaViewerRoute {
        MediaViewerRoute(
            source: .photoLibrary,
            items: items,
            initialItem: initialItem,
            connection: nil,
            startPositionSeconds: 0,
            readingDirection: readingDirection
        )
    }

    static func make(
        source: ContentSource,
        items: [DirectoryItem],
        initialItem: DirectoryItem,
        connection: RemoteConnection? = nil,
        startPositionSeconds: Double = 0,
        imagePagingOrder: MediaViewerPageSource.ImagePagingOrder = .preserveInput,
        readingDirection: ReadingDirection = .rightToLeft
    ) -> MediaViewerRoute? {
        let siblingItems = pageableItems(
            from: items,
            initialItem: initialItem,
            imagePagingOrder: imagePagingOrder
        )
        switch source {
        case .photoLibrary:
            return .photoLibrary(
                items: siblingItems,
                initialItem: initialItem,
                readingDirection: readingDirection
            )
        case .localFolder(let sourceID):
            return .localFolder(
                sourceID: sourceID,
                items: siblingItems,
                initialItem: initialItem,
                readingDirection: readingDirection
            )
        case .remote:
            guard let connection else { return nil }
            return .remote(
                connection: connection,
                items: siblingItems,
                initialItem: initialItem,
                startPositionSeconds: startPositionSeconds,
                readingDirection: readingDirection
            )
        }
    }

    static func make(
        file: MediaFile,
        allFiles: [MediaFile],
        connectionResolver: (MediaFile) -> RemoteConnection?
    ) -> MediaViewerRoute? {
        MediaViewerPageSource.files(
            sourceID: file.sourceID,
            allFiles: allFiles,
            connectionResolver: connectionResolver
        )?.route(for: file)
    }

    static func make(history: WatchHistory) -> MediaViewerRoute? {
        MediaViewerPageSource.history(history)?.route(for: history)
    }

    private static func pageableItems(
        from items: [DirectoryItem],
        initialItem: DirectoryItem,
        imagePagingOrder: MediaViewerPageSource.ImagePagingOrder
    ) -> [DirectoryItem] {
        let filteredItems: [DirectoryItem]
        if initialItem.isVideo {
            filteredItems = items.filter(\.isVideo)
        } else if initialItem.isImage {
            let imageItems = items.filter(\.isImage)
            switch imagePagingOrder {
            case .preserveInput:
                filteredItems = imageItems
            case .naturalName:
                filteredItems = imageItems.sorted(by: naturalImageOrder)
            }
        } else if initialItem.isPDF {
            filteredItems = [initialItem]
        } else {
            filteredItems = [initialItem]
        }

        if filteredItems.contains(where: { $0.path == initialItem.path }) {
            return filteredItems
        }
        return [initialItem] + filteredItems
    }

    private static func naturalImageOrder(_ lhs: DirectoryItem, _ rhs: DirectoryItem) -> Bool {
        let nameComparison = lhs.name.localizedStandardCompare(rhs.name)
        if nameComparison != .orderedSame {
            return nameComparison == .orderedAscending
        }
        return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
    }
}

struct MediaViewerContainerView: View {
    @Environment(\.appEnvironment) private var appEnvironment
    @Environment(\.dismiss) private var dismiss

    let route: MediaViewerRoute
    var onReturnHome: (() async -> Void)? = nil

    var body: some View {
        Group {
            switch route.source {
            case .photoLibrary:
                PhotoLibraryMediaViewerView(
                    items: route.items,
                    initialItem: route.initialItem,
                    readingDirection: route.readingDirection
                )

            case .localFolder:
                if route.initialItem.isPDF {
                    LocalPDFViewerView(
                        item: route.initialItem,
                        source: route.source,
                        readingDirection: route.readingDirection
                    )
                } else if route.initialItem.isVideo {
                    LocalVideoPlayerView(
                        items: route.items.filter(\.isVideo),
                        initialItem: route.initialItem,
                        source: route.source
                    )
                } else {
                    LocalImageViewerView(
                        items: route.items.filter(\.isImage),
                        initialItem: route.initialItem,
                        source: route.source,
                        readingDirection: route.readingDirection
                    )
                }

            case .remote:
                if let connection = route.connection {
                    if route.initialItem.isPDF {
                        RemotePDFViewerView(
                            connection: connection,
                            item: route.initialItem,
                            source: route.source,
                            readingDirection: route.readingDirection
                        )
                        .environment(\.appEnvironment, appEnvironment)
                    } else if route.initialItem.isVideo {
                        VideoPlayerView(
                            connection: connection,
                            items: route.items.filter(\.isVideo),
                            initialItem: route.initialItem,
                            startPositionSeconds: route.startPositionSeconds,
                            onReturnHome: onReturnHome
                        )
                        .environment(\.appEnvironment, appEnvironment)
                    } else {
                        ImageViewerView(
                            connection: connection,
                            items: route.items.filter(\.isImage),
                            initialItem: route.initialItem,
                            readingDirection: route.readingDirection
                        )
                        .environment(\.appEnvironment, appEnvironment)
                    }
                } else {
                    ContentUnavailableView(
                        "接続先を開けません",
                        systemImage: "wifi.slash",
                        description: Text("接続情報が見つかりません。")
                    )
                    .onTapGesture {
                        dismiss()
                    }
                }
            }
        }
    }
}
