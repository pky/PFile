import SwiftUI
import MobileVLCKit
import UIKit

struct LocalFolderBrowserView: View {
    @Environment(\.appEnvironment) private var appEnvironment
    let source: LocalFolderSource
    private let directRootURL: URL?

    @State private var rootURL: URL?
    @State private var isAccessing = false
    @State private var navigationPath: [String] = []
    @State private var selectedRoute: MediaViewerRoute?
    @State private var errorMessage: String?
    @State private var hasRestoredNavigationPath = false
    @State private var cachedViewModels: [String: LocalFolderBrowserViewModel] = [:]

    init(source: LocalFolderSource, directRootURL: URL? = nil) {
        self.source = source
        self.directRootURL = directRootURL
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                if let rootURL {
                    LocalFolderDirectoryView(
                        rootURL: rootURL,
                        source: source,
                        directoryPath: rootURL.path,
                        navigationPath: $navigationPath,
                        cachedViewModels: $cachedViewModels,
                        selectedRoute: $selectedRoute
                    )
                } else if let errorMessage {
                    ContentUnavailableView("ローカルフォルダを開けません", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
                } else {
                    ProgressView()
                }
            }
            .navigationDestination(for: String.self) { path in
                if let rootURL {
                    LocalFolderDirectoryView(
                        rootURL: rootURL,
                        source: source,
                        directoryPath: path,
                        navigationPath: $navigationPath,
                        cachedViewModels: $cachedViewModels,
                        selectedRoute: $selectedRoute
                    )
                }
            }
        }
        .task {
            await resolveRootURL()
        }
        .task(id: rootURL?.path) {
            guard let rootURL, !hasRestoredNavigationPath else { return }
            let contentSource = ContentSource.localFolder(source.id)
            let restoredPath = appEnvironment.browsePathStore.restoreDeepestPath(
                for: contentSource,
                rootPath: rootURL.path
            ) ?? rootURL.path
            navigationPath = BrowsePathStore.navigationPath(
                from: rootURL.path,
                to: restoredPath
            )
            hasRestoredNavigationPath = true
        }
        .onDisappear {
            if isAccessing, let rootURL {
                rootURL.stopAccessingSecurityScopedResource()
                isAccessing = false
            }
        }
        .fullScreenCover(item: $selectedRoute) { route in
            MediaViewerContainerView(route: route)
        }
    }

    private func resolveRootURL() async {
        if let directRootURL {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directRootURL.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                await MainActor.run {
                    errorMessage = "フォルダが見つかりません: \(directRootURL.path)"
                }
                return
            }

            await MainActor.run {
                rootURL = directRootURL
                isAccessing = false
            }
            return
        }

        do {
            let resolvedBookmark = try LocalFolderBookmarkService.resolveBookmark(from: source.bookmarkData)
            let url = resolvedBookmark.url
            if resolvedBookmark.isStale {
                source.bookmarkData = try LocalFolderBookmarkService.makeBookmark(for: url)
                try await appEnvironment.localFolderSourceRepository.save(source)
            }
            let didAccess = url.startAccessingSecurityScopedResource()
            await MainActor.run {
                rootURL = url
                isAccessing = didAccess
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
            }
        }
    }
}

@MainActor
@Observable
final class LocalFolderBrowserViewModel {
    var items: [DirectoryItem] = []
    var isLoading = false
    var errorMessage: String?
    var isSelectMode = false
    var selectedPaths: Set<String> = []
    var thumbnails: [String: UIImage] = [:]
    private var loadingThumbnailKeys: Set<String> = []

    private let sortService = SortService()
    private let repository: LocalFileRepository
    private let mediaThumbnailProvider: MediaThumbnailProvider?
    private let sourceID: UUID
    private let rootURL: URL
    private(set) var currentPath: String

    var listRegistrationFileRepository: any FileRepository {
        repository
    }

    init(
        rootURL: URL,
        currentPath: String,
        sourceID: UUID,
        mediaThumbnailProvider: MediaThumbnailProvider? = nil
    ) {
        self.rootURL = rootURL
        self.currentPath = currentPath
        self.sourceID = sourceID
        self.repository = LocalFileRepository(rootURL: rootURL)
        self.mediaThumbnailProvider = mediaThumbnailProvider
    }

    var breadcrumbs: [String] {
        let relative = String(currentPath.dropFirst(rootURL.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !relative.isEmpty else { return [] }
        return relative.split(separator: "/").map(String.init)
    }

    func loadDirectory() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let fetched = try await repository.listDirectory(at: currentPath)
            items = sortService.sort(
                fetched,
                by: .name,
                order: .ascending,
                foldersFirst: true
            )
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func thumbnail(for item: DirectoryItem) -> UIImage? {
        thumbnails[cacheKey(for: item)]
    }

    func loadThumbnail(for item: DirectoryItem) async {
        guard item.isMedia else { return }
        let key = cacheKey(for: item)
        if thumbnails[key] != nil { return }
        if loadingThumbnailKeys.contains(key) { return }
        guard let mediaThumbnailProvider else { return }
        loadingThumbnailKeys.insert(key)
        defer { loadingThumbnailKeys.remove(key) }

        let source = ContentSource.localFolder(sourceID)
        if let cached = mediaThumbnailProvider.thumbnail(for: source, item: item) {
            thumbnails[key] = cached
            return
        }

        if let image = await mediaThumbnailProvider.loadThumbnail(
            for: source,
            item: item,
            connection: nil
        ) {
            thumbnails[key] = image
        }
    }

    func prepareForDisplay(at path: String) async {
        currentPath = path
        await loadDirectory()
    }

    func toggleSelectMode() {
        isSelectMode.toggle()
        if !isSelectMode {
            selectedPaths.removeAll()
        }
    }

    func toggleSelection(for item: DirectoryItem) {
        if selectedPaths.contains(item.path) {
            selectedPaths.remove(item.path)
        } else {
            selectedPaths.insert(item.path)
        }
    }

    func clearSelection() {
        selectedPaths.removeAll()
    }

    var selectedItems: [DirectoryItem] {
        items.filter { selectedPaths.contains($0.path) }
    }

    private func cacheKey(for item: DirectoryItem) -> String {
        mediaThumbnailProvider?.cacheKey(source: .localFolder(sourceID), item: item)
            ?? item.path
    }
}

private struct LocalFolderDirectoryView: View {
    @Environment(\.appEnvironment) private var appEnvironment
    let rootURL: URL
    let source: LocalFolderSource
    let directoryPath: String
    @Binding var navigationPath: [String]
    @Binding var cachedViewModels: [String: LocalFolderBrowserViewModel]
    @Binding var selectedRoute: MediaViewerRoute?

    @State private var viewModel: LocalFolderBrowserViewModel?
    @State private var showAddToListSheet = false

    var body: some View {
        Group {
            if let viewModel {
                fileContent(viewModel: viewModel)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(viewModel.map(currentFolderName) ?? rootURL.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(Constants.Theme.panelBackground, for: .navigationBar)
        .background(Constants.Theme.panelBackground.ignoresSafeArea())
        .toolbar {
            if let viewModel {
                toolbarItems(viewModel: viewModel)
            }
        }
        .task(id: directoryPath) {
            let vm: LocalFolderBrowserViewModel
            if let existing = cachedViewModels[directoryPath] {
                vm = existing
            } else {
                let created = LocalFolderBrowserViewModel(
                    rootURL: rootURL,
                    currentPath: directoryPath,
                    sourceID: source.id,
                    mediaThumbnailProvider: appEnvironment.mediaThumbnailProvider
                )
                cachedViewModels[directoryPath] = created
                vm = created
            }
            await vm.prepareForDisplay(at: directoryPath)
            viewModel = vm
            appEnvironment.browsePathStore.syncCurrentPath(
                directoryPath,
                for: .localFolder(source.id),
                rootPath: rootURL.path
            )
        }
        .sheet(isPresented: $showAddToListSheet) {
            if let viewModel {
                AddToListSheet(
                    items: viewModel.selectedItems,
                    source: .localFolder(source.id),
                    connection: nil,
                    fileRepository: viewModel.listRegistrationFileRepository
                )
                .environment(\.appEnvironment, appEnvironment)
                .onDisappear {
                    viewModel.clearSelection()
                    viewModel.isSelectMode = false
                }
            }
        }
    }

    @ToolbarContentBuilder
    private func toolbarItems(viewModel: LocalFolderBrowserViewModel) -> some ToolbarContent {
        @Bindable var prefs = appEnvironment.viewPreferences

        if viewModel.isSelectMode {
            ToolbarItem(placement: .navigationBarLeading) {
                Text("\(viewModel.selectedPaths.count)件を選択")
                    .foregroundStyle(.secondary)
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("完了") {
                    viewModel.toggleSelectMode()
                }
            }
            ToolbarItem(placement: .bottomBar) {
                Spacer()
            }
            ToolbarItem(placement: .bottomBar) {
                Button {
                    showAddToListSheet = true
                } label: {
                    Label("リストに追加", systemImage: "plus.rectangle.on.rectangle")
                }
                .disabled(viewModel.selectedItems.isEmpty)
            }
            ToolbarItem(placement: .bottomBar) {
                Spacer()
            }
        } else {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("選択") {
                    viewModel.toggleSelectMode()
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Picker("表示形式", selection: $prefs.viewMode) {
                        ForEach(ViewMode.allCases, id: \.self) { mode in
                            Label(mode.displayName, systemImage: mode.systemImage).tag(mode)
                        }
                    }
                    if !prefs.viewMode.isListMode {
                        Divider()
                        Section("グリッドサイズ") {
                            Button("極小") { prefs.gridCellWidth = 80 }
                            Button("小") { prefs.gridCellWidth = 110 }
                            Button("中") { prefs.gridCellWidth = 150 }
                            Button("大") { prefs.gridCellWidth = 200 }
                            Button("極大") { prefs.gridCellWidth = 260 }
                        }
                    }
                } label: {
                    Image(systemName: prefs.viewMode.systemImage)
                }
            }
        }
    }

    @ViewBuilder
    private func fileContent(viewModel: LocalFolderBrowserViewModel) -> some View {
        Group {
            switch appEnvironment.viewPreferences.viewMode {
            case .list, .listDetail:
                listContent(viewModel: viewModel)
            case .gridTitled, .gridNoTitle, .gridDetail:
                gridContent(viewModel: viewModel)
            }
        }
        .overlay {
            if viewModel.isLoading {
                ProgressView()
            } else if let errorMessage = viewModel.errorMessage {
                ContentUnavailableView("読み込みに失敗", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else if viewModel.items.isEmpty {
                ContentUnavailableView("ファイルがありません", systemImage: "folder")
            }
        }
    }

    @ViewBuilder
    private func listContent(viewModel: LocalFolderBrowserViewModel) -> some View {
        let showDetail = appEnvironment.viewPreferences.viewMode == .listDetail
        List(viewModel.items) { item in
            if viewModel.isSelectMode && (item.isMedia || item.isDirectory) {
                Button {
                    viewModel.toggleSelection(for: item)
                } label: {
                    HStack {
                        Image(systemName: viewModel.selectedPaths.contains(item.path)
                            ? "checkmark.circle.fill"
                            : "circle")
                        .foregroundStyle(viewModel.selectedPaths.contains(item.path)
                            ? Color.accentColor
                            : Color.secondary)
                        LocalFileRowView(
                            item: item,
                            thumbnail: viewModel.thumbnail(for: item),
                            showDetail: showDetail
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .task {
                    await viewModel.loadThumbnail(for: item)
                }
            } else {
                Button {
                    open(item)
                } label: {
                    LocalFileRowView(
                        item: item,
                        thumbnail: viewModel.thumbnail(for: item),
                        showDetail: showDetail
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .task {
                    await viewModel.loadThumbnail(for: item)
                }
            }
        }
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func gridContent(viewModel: LocalFolderBrowserViewModel) -> some View {
        let gridItems = [GridItem(.adaptive(minimum: appEnvironment.viewPreferences.gridCellWidth), spacing: 8)]
        ScrollView {
            LazyVGrid(columns: gridItems, spacing: 8) {
                ForEach(viewModel.items) { item in
                    if viewModel.isSelectMode && (item.isMedia || item.isDirectory) {
                        Button {
                            viewModel.toggleSelection(for: item)
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: viewModel.selectedPaths.contains(item.path)
                                    ? "checkmark.circle.fill"
                                    : "circle")
                                .foregroundStyle(viewModel.selectedPaths.contains(item.path)
                                    ? Color.accentColor
                                    : Color.secondary)
                                localGridCell(
                                    for: item,
                                    thumbnail: viewModel.thumbnail(for: item)
                                )
                            }
                        }
                        .buttonStyle(.plain)
                        .task {
                            await viewModel.loadThumbnail(for: item)
                        }
                    } else {
                        Button {
                            open(item)
                        } label: {
                            localGridCell(
                                for: item,
                                thumbnail: viewModel.thumbnail(for: item)
                            )
                        }
                        .buttonStyle(.plain)
                        .task {
                            await viewModel.loadThumbnail(for: item)
                        }
                    }
                }
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private func localGridCell(for item: DirectoryItem, thumbnail: UIImage?) -> some View {
        switch appEnvironment.viewPreferences.viewMode {
        case .list, .listDetail:
            EmptyView()
        case .gridTitled:
            LocalGridTitledCellView(item: item, thumbnail: thumbnail)
        case .gridNoTitle:
            LocalGridNoTitleCellView(item: item, thumbnail: thumbnail)
        case .gridDetail:
            LocalGridDetailCellView(item: item, thumbnail: thumbnail)
        }
    }

    private func open(_ item: DirectoryItem) {
        if item.isDirectory {
            appEnvironment.browsePathStore.enterDirectory(
                item.path,
                for: .localFolder(source.id),
                rootPath: rootURL.path
            )
            navigationPath.append(item.path)
        } else if item.isPDF {
            selectedRoute = MediaViewerPageSource(
                source: .localFolder(source.id),
                items: [item],
                connection: nil,
                startPositionSeconds: 0,
                imagePagingOrder: .preserveInput,
                readingDirection: .leftToRight
            ).route(for: item)
        } else if item.isImage {
            selectedRoute = MediaViewerPageSource
                .localFolder(sourceID: source.id, items: viewModel?.items ?? [item])
                .route(for: item)
        } else if item.isVideo {
            selectedRoute = MediaViewerPageSource
                .localFolder(sourceID: source.id, items: viewModel?.items ?? [item])
                .route(for: item)
        }
    }

    private func currentFolderName(_ viewModel: LocalFolderBrowserViewModel) -> String {
        let url = URL(fileURLWithPath: viewModel.currentPath)
        return url.lastPathComponent.isEmpty ? rootURL.lastPathComponent : url.lastPathComponent
    }

}

private struct LocalFileRowView: View {
    let item: DirectoryItem
    let thumbnail: UIImage?
    var showDetail: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 50, height: 50)
                        .cornerRadius(6)
                        .clipped()
                } else {
                    Image(systemName: iconName)
                        .font(item.isDirectory ? .system(size: 30) : .title2)
                        .foregroundStyle(iconColor)
                        .frame(width: 50, height: 50)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                HStack {
                    if let size = item.size, !item.isDirectory {
                        Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    }
                    if showDetail, let date = item.modifiedAt {
                        Spacer()
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if item.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var iconName: String {
        switch item.itemType {
        case .directory: return "folder.fill"
        case .video: return "play.rectangle.fill"
        case .image: return "photo.fill"
        case .pdf: return "doc.richtext.fill"
        case .other: return "doc.fill"
        }
    }

    private var iconColor: Color {
        switch item.itemType {
        case .directory: return Constants.Theme.folderBlue
        case .video: return .blue
        case .image: return .green
        case .pdf: return .red
        case .other: return .secondary
        }
    }
}

private struct LocalGridTitledCellView: View {
    let item: DirectoryItem
    let thumbnail: UIImage?

    var body: some View {
        VStack(spacing: 4) {
            MediaThumbnailView(
                thumbnail: thumbnail,
                placeholderSystemImage: item.itemType.placeholderIcon,
                placeholderColor: item.itemType.placeholderColor,
                placeholderFontSize: 48
            )
            .aspectRatio(16 / 9, contentMode: .fit)
            .cornerRadius(6)
            Text(item.name)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, minHeight: Constants.Grid.cellTitleHeight, maxHeight: Constants.Grid.cellTitleHeight, alignment: .top)
        }
    }
}

private struct LocalGridNoTitleCellView: View {
    let item: DirectoryItem
    let thumbnail: UIImage?

    var body: some View {
        MediaThumbnailView(
            thumbnail: thumbnail,
            placeholderSystemImage: item.itemType.placeholderIcon,
            placeholderColor: item.itemType.placeholderColor,
            placeholderFontSize: 48
        )
        .aspectRatio(16 / 9, contentMode: .fit)
        .cornerRadius(6)
    }
}

private struct LocalGridDetailCellView: View {
    let item: DirectoryItem
    let thumbnail: UIImage?

    var body: some View {
        VStack(spacing: 4) {
            MediaThumbnailView(
                thumbnail: thumbnail,
                placeholderSystemImage: item.itemType.placeholderIcon,
                placeholderColor: item.itemType.placeholderColor,
                placeholderFontSize: 48
            )
            .aspectRatio(16 / 9, contentMode: .fit)
            .cornerRadius(6)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .font(.caption)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(.primary)
                if let size = item.size, !item.isDirectory {
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let date = item.modifiedAt {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: Constants.Grid.cellDetailInfoHeight, maxHeight: Constants.Grid.cellDetailInfoHeight, alignment: .topLeading)
        }
    }
}

fileprivate extension DirectoryItem.ItemType {
    var placeholderIcon: String {
        switch self {
        case .directory: return "folder.fill"
        case .video: return "film"
        case .image: return "photo"
        case .pdf: return "doc.richtext"
        case .other: return "doc"
        }
    }

    var placeholderColor: Color {
        switch self {
        case .directory: return Constants.Theme.folderBlue
        case .pdf: return .red
        default: return .secondary
        }
    }
}

struct LocalImageViewerView: View {
    @Environment(\.appEnvironment) private var appEnvironment
    @Environment(\.dismiss) private var dismiss

    let items: [DirectoryItem]
    let source: ContentSource?
    let readingDirection: ReadingDirection
    @State private var currentIndex: Int
    @State private var image: UIImage?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showAddToListSheet = false
    @State private var prefetchedImages: [String: UIImage] = [:]
    @State private var loadRequestID = UUID()

    init(
        items: [DirectoryItem],
        initialItem: DirectoryItem,
        source: ContentSource? = nil,
        readingDirection: ReadingDirection = .rightToLeft
    ) {
        self.items = items
        self.source = source
        self.readingDirection = readingDirection
        self._currentIndex = State(initialValue: items.firstIndex(where: { $0.path == initialItem.path }) ?? 0)
    }

    private var currentItem: DirectoryItem? {
        items.indices.contains(currentIndex) ? items[currentIndex] : nil
    }

    private func item(at index: Int) -> DirectoryItem? {
        items.indices.contains(index) ? items[index] : nil
    }

    private var canNavigateBackward: Bool {
        currentIndex > items.startIndex
    }

    private var canNavigateForward: Bool {
        currentIndex < items.index(before: items.endIndex)
    }

    var body: some View {
        MediaImageScreen(
            title: currentItem?.name ?? "",
            readingDirection: readingDirection,
            currentPageIndex: currentIndex,
            totalPageCount: items.count,
            pageText: items.count > 1 ? "\(currentIndex + 1) / \(items.count)" : nil,
            canNavigateBackward: canNavigateBackward,
            canNavigateForward: canNavigateForward,
            hasImage: image != nil,
            errorMessage: errorMessage,
            onClose: { dismiss() },
            onAddToList: source == nil ? nil : {
                showAddToListSheet = true
            },
            onPageSeek: { targetIndex in
                await switchToItem(at: targetIndex)
            },
            onNavigateBackward: canNavigateBackward ? {
                await switchToItem(at: currentIndex - 1)
            } : nil,
            onNavigateForward: canNavigateForward ? {
                await switchToItem(at: currentIndex + 1)
            } : nil
        ) {
            imageContent
        }
        .task(id: currentIndex) {
            await loadImage()
        }
        .sheet(isPresented: $showAddToListSheet) {
            if let source, let item = currentItem {
                AddToListSheet(items: [item], source: source, connection: nil)
                    .environment(\.appEnvironment, appEnvironment)
            }
        }
    }

    private func switchToItem(at index: Int) async {
        guard items.indices.contains(index) else { return }
        loadRequestID = UUID()
        if let item = item(at: index),
           let cachedImage = prefetchedImages[item.path] {
            image = cachedImage
        } else {
            image = nil
        }
        currentIndex = index
        errorMessage = nil
    }

    @ViewBuilder
    private var imageContent: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
        } else if isLoading {
            ProgressView()
                .tint(.white)
        } else {
            Color.clear
        }
    }

    private func loadImage() async {
        guard let currentItem else { return }
        let requestID = UUID()
        loadRequestID = requestID
        isLoading = true
        errorMessage = nil
        if let cachedImage = prefetchedImages[currentItem.path] {
            guard loadRequestID == requestID else { return }
            image = cachedImage
            isLoading = false
            trimPrefetchedImages(keepingPaths: [currentItem.path, item(at: currentIndex + 1)?.path].compactMap { $0 })
            await prefetchNextImage(after: currentIndex)
            return
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: currentItem.path))
            let loadedImage = UIImage(data: data)
            guard loadRequestID == requestID else { return }
            image = loadedImage
            if let loadedImage {
                prefetchedImages[currentItem.path] = loadedImage
                isLoading = false
                trimPrefetchedImages(keepingPaths: [currentItem.path, item(at: currentIndex + 1)?.path].compactMap { $0 })
                await prefetchNextImage(after: currentIndex)
            } else {
                errorMessage = "画像を読み込めませんでした"
                isLoading = false
            }
        } catch {
            guard loadRequestID == requestID else { return }
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    private func prefetchNextImage(after index: Int) async {
        guard let nextItem = item(at: index + 1),
              prefetchedImages[nextItem.path] == nil else { return }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: nextItem.path))
            if let loadedImage = UIImage(data: data) {
                prefetchedImages[nextItem.path] = loadedImage
                trimPrefetchedImages(
                    keepingPaths: [
                        currentItem?.path,
                        nextItem.path
                    ].compactMap { $0 }
                )
            }
        } catch {
            // 先読み失敗は表示本体に影響させない
        }
    }

    private func trimPrefetchedImages(keepingPaths: [String]) {
        let keep = Set(keepingPaths)
        prefetchedImages = prefetchedImages.filter { keep.contains($0.key) }
    }
}

struct LocalVideoPlayerView: View {
    @Environment(\.appEnvironment) private var appEnvironment
    @Environment(\.dismiss) private var dismiss

    let items: [DirectoryItem]
    let source: ContentSource?

    @State private var currentIndex: Int
    @State private var controller = LocalVideoPlayerController()
    @State private var showAddToListSheet = false

    init(items: [DirectoryItem], initialItem: DirectoryItem, source: ContentSource? = nil) {
        self.items = items
        self.source = source
        self._currentIndex = State(
            initialValue: items.firstIndex(where: { $0.path == initialItem.path }) ?? 0
        )
    }

    private var currentItem: DirectoryItem? {
        items.indices.contains(currentIndex) ? items[currentIndex] : nil
    }

    var body: some View {
        MediaVideoScreen(
            title: currentItem?.name ?? "",
            pageText: items.count > 1 ? "\(currentIndex + 1) / \(items.count)" : nil,
            isPlaying: controller.isPlaying,
            isMuted: controller.isMuted,
            progress: videoProgress,
            currentPositionSeconds: controller.currentPositionSeconds,
            durationSeconds: controller.durationSeconds,
            canNavigateBackward: currentIndex > items.startIndex,
            canNavigateForward: currentIndex < items.index(before: items.endIndex),
            errorMessage: controller.errorMessage,
            shareURL: currentItem.map { URL(fileURLWithPath: $0.path) },
            onClose: {
                await saveWatchHistory()
                controller.stop()
                dismiss()
            },
            onAddToList: source == nil ? nil : {
                showAddToListSheet = true
            },
            onNavigateBackward: currentIndex > items.startIndex ? {
                await switchToItem(at: currentIndex - 1)
            } : nil,
            onNavigateForward: currentIndex < items.index(before: items.endIndex) ? {
                await switchToItem(at: currentIndex + 1)
            } : nil,
            onPlayPause: {
                controller.togglePlayPause()
            },
            onSkipBackwardLong: {
                controller.skip(seconds: -60)
            },
            onSkipBackwardShort: {
                controller.skip(seconds: -10)
            },
            onSkipForwardShort: {
                controller.skip(seconds: 10)
            },
            onSkipForwardLong: {
                controller.skip(seconds: 60)
            },
            onSeekChanged: { seconds in
                controller.seek(to: seconds)
            },
            onSeekEnded: {},
            onToggleMute: {
                controller.toggleMute()
            }
        ) {
            LocalVLCPlayerView(player: controller.player)
                .id(currentIndex)
                .ignoresSafeArea()
        }
        .onAppear {
            loadCurrentItem()
        }
        .onDisappear {
            Task {
                await saveWatchHistory()
            }
            controller.stop()
        }
        .sheet(isPresented: $showAddToListSheet) {
            if let source, let item = currentItem {
                AddToListSheet(items: [item], source: source, connection: nil)
                    .environment(\.appEnvironment, appEnvironment)
            }
        }
    }

    private func loadCurrentItem() {
        guard let currentItem else { return }
        controller.load(url: URL(fileURLWithPath: currentItem.path))
    }

    private func switchToItem(at index: Int) async {
        guard items.indices.contains(index) else { return }
        await saveWatchHistory()
        controller.stop()
        currentIndex = index
        loadCurrentItem()
    }

    private var videoProgress: Double {
        guard controller.durationSeconds > 0 else { return 0 }
        return min(max(controller.currentPositionSeconds / controller.durationSeconds, 0), 1)
    }

    private func saveWatchHistory() async {
        guard let source, let currentItem else { return }
        await appEnvironment.playbackHistoryService.saveProgress(
            source: source,
            connection: nil,
            item: currentItem,
            currentPositionSeconds: controller.currentPositionSeconds,
            durationSeconds: controller.durationSeconds,
            thumbnailData: nil
        )
    }
}

@MainActor
@Observable
final class LocalVideoPlayerController: NSObject {
    var isPlaying = false
    var isMuted = false
    var currentPositionSeconds: Double = 0
    var durationSeconds: Double = 0
    var errorMessage: String?

    let player = VLCMediaPlayer()

    override init() {
        super.init()
        player.delegate = self
    }

    func load(url: URL) {
        errorMessage = nil
        let media = VLCMedia(url: url)
        player.media = media
        player.play()
    }

    func togglePlayPause() {
        if player.isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying = player.isPlaying
    }

    func toggleMute() {
        isMuted.toggle()
        player.audio?.isMuted = isMuted
    }

    func skip(seconds: Double) {
        let newMs = Int32(max(0, currentPositionSeconds + seconds) * 1000)
        player.time = VLCTime(int: newMs)
    }

    func seek(to seconds: Double) {
        let ms = Int32(max(0, seconds) * 1000)
        player.time = VLCTime(int: ms)
    }

    func stop() {
        player.stop()
        player.media = nil
        currentPositionSeconds = 0
        durationSeconds = 0
        isPlaying = false
    }
}

@MainActor
extension LocalVideoPlayerController: VLCMediaPlayerDelegate {
    func mediaPlayerStateChanged(_ aNotification: Notification) {
        isPlaying = player.isPlaying
        if player.state == .error {
            errorMessage = "再生エラーが発生しました"
        }
    }

    func mediaPlayerTimeChanged(_ aNotification: Notification) {
        let ms = player.time.intValue
        currentPositionSeconds = Double(ms) / 1000.0
        if let lengthMs = player.media?.length.intValue, lengthMs > 0 {
            durationSeconds = Double(lengthMs) / 1000.0
        }
    }
}

private struct LocalVLCPlayerView: UIViewRepresentable {
    let player: VLCMediaPlayer

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        player.drawable = view
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        player.drawable = uiView
    }
}
