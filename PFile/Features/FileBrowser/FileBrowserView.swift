import SwiftUI

// MARK: - FileBrowserView（NavigationStack ラッパー）

struct FileBrowserView: View {

    @Environment(\.appEnvironment) private var appEnvironment
    @Environment(\.scenePhase) private var scenePhase
    let connection: RemoteConnection
    var isActive: Bool = true
    var onConnectionUnavailable: (() -> Void)? = nil
    var onReturnHome: (() async -> Void)? = nil

    @State private var navigationPath: [String] = []
    @State private var hasRestoredNavigationPath = false
    @State private var cachedViewModels: [String: FileBrowserViewModel] = [:]
    @State private var didEnterBackground = false

    private var source: ContentSource {
        .remote(connection.id)
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            DirectoryContentView(
                connection: connection,
                source: source,
                directoryPath: connection.startPath,
                navigationPath: $navigationPath,
                cachedViewModels: $cachedViewModels,
                isActive: isActive,
                onReturnHome: onReturnHome
            )
            .navigationDestination(for: String.self) { dirPath in
                DirectoryContentView(
                    connection: connection,
                    source: source,
                    directoryPath: dirPath,
                    navigationPath: $navigationPath,
                    cachedViewModels: $cachedViewModels,
                    onReturnHome: onReturnHome
                )
                .environment(\.appEnvironment, appEnvironment)
            }
        }
        .task(id: connection.id) {
            guard !hasRestoredNavigationPath else { return }
            let restoredPath = appEnvironment.browsePathStore.restoreDeepestPath(
                for: source,
                rootPath: connection.startPath
            ) ?? connection.startPath
            navigationPath = BrowsePathStore.navigationPath(
                from: connection.startPath,
                to: restoredPath
            )
            hasRestoredNavigationPath = true
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                didEnterBackground = true
                cachedViewModels.values.forEach { $0.prepareForBackground() }
            case .active:
                guard didEnterBackground, isActive, hasRestoredNavigationPath else { return }
                didEnterBackground = false
                Task {
                    let currentPath = navigationPath.last ?? connection.startPath
                    guard let viewModel = cachedViewModels[currentPath] else { return }
                    let isAvailable = await viewModel.refreshConnectionIfNeeded(forceReconnect: true)
                    if !isAvailable {
                        onConnectionUnavailable?()
                    }
                }
            case .inactive:
                break
            @unknown default:
                break
            }
        }
    }
}

// MARK: - DirectoryContentView（各階層のコンテンツ）

private struct DirectoryContentView: View {

    @Environment(\.appEnvironment) private var appEnvironment
    let connection: RemoteConnection
    let source: ContentSource
    let directoryPath: String
    @Binding var navigationPath: [String]
    @Binding var cachedViewModels: [String: FileBrowserViewModel]
    var isActive: Bool = true
    var onReturnHome: (() async -> Void)? = nil

    @State private var viewModel: FileBrowserViewModel?
    @State private var selectedRoute: MediaViewerRoute?
    @State private var showAddToListSheet = false
    @State private var showSearchSheet = false

    var body: some View {
        Group {
            if let viewModel {
                fileContent(viewModel: viewModel)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(viewModel.map { currentFolderName(viewModel: $0) } ?? connection.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(Constants.Theme.panelBackground, for: .navigationBar)
        .background(Constants.Theme.panelBackground.ignoresSafeArea())
        .toolbar {
            if isActive, let viewModel {
                toolbarItems(viewModel: viewModel)
            }
        }
        .task(id: directoryPath) {
            let vm: FileBrowserViewModel
            if let existing = cachedViewModels[directoryPath] {
                vm = existing
            } else {
                guard let repo = try? SMBFileRepository(
                    connection: connection,
                    clientManager: appEnvironment.smbClientManager
                ) else { return }
                let created = FileBrowserViewModel(
                    connection: connection,
                    fileRepository: repo,
                    mediaThumbnailProvider: appEnvironment.mediaThumbnailProvider,
                    thumbnailService: appEnvironment.thumbnailService,
                    smbClientManager: appEnvironment.smbClientManager,
                    mediaListRepository: appEnvironment.mediaListRepository,
                    startPath: directoryPath
                )
                cachedViewModels[directoryPath] = created
                vm = created
                await created.loadDirectory()
            }
            viewModel = vm
            appEnvironment.browsePathStore.syncCurrentPath(
                directoryPath,
                for: source,
                rootPath: connection.startPath
            )
            await vm.loadRegisteredPaths()
        }
        .fullScreenCover(item: $selectedRoute, onDismiss: {
            Task { await viewModel?.loadRegisteredPaths() }
        }) { route in
            MediaViewerContainerView(route: route, onReturnHome: onReturnHome)
                .environment(\.appEnvironment, appEnvironment)
        }
        .sheet(isPresented: $showAddToListSheet) {
            if let viewModel {
                AddToListSheet(
                    items: viewModel.selectedItems,
                    source: .remote(connection.id),
                    connection: connection,
                    fileRepository: viewModel.listRegistrationFileRepository
                )
                    .environment(\.appEnvironment, appEnvironment)
                    .onDisappear {
                        viewModel.clearSelection()
                        viewModel.isSelectMode = false
                        Task { await viewModel.loadRegisteredPaths() }
                    }
            }
        }
        .sheet(isPresented: $showSearchSheet) {
            if let viewModel {
                FileBrowserSearchSheet(
                    viewModel: viewModel,
                    rootPath: directoryPath,
                    connection: connection,
                    source: source,
                    onReturnHome: onReturnHome,
                    onNavigateToDirectory: { item in
                        appEnvironment.browsePathStore.enterDirectory(
                            item.path,
                            for: source,
                            rootPath: connection.startPath
                        )
                        navigationPath.append(item.path)
                    }
                )
                .environment(\.appEnvironment, appEnvironment)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let viewModel, viewModel.isSelectMode {
                selectModeBottomBar(viewModel: viewModel)
            }
        }
    }

    // MARK: - ツールバー

    @ToolbarContentBuilder
    private func toolbarItems(viewModel: FileBrowserViewModel) -> some ToolbarContent {
        @Bindable var vm = viewModel
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
        } else {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showSearchSheet = true
                } label: {
                    Image(systemName: "magnifyingglass")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        vm.showUnregisteredOnly = false
                    } label: {
                        Label("すべて表示", systemImage: vm.showUnregisteredOnly ? "" : "checkmark")
                    }
                    Button {
                        vm.showUnregisteredOnly = true
                        Task { await viewModel.loadRegisteredPaths() }
                    } label: {
                        Label("リスト未登録のみ", systemImage: vm.showUnregisteredOnly ? "checkmark" : "")
                    }
                } label: {
                    Image(systemName: vm.showUnregisteredOnly ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("選択") {
                    viewModel.toggleSelectMode()
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Picker("並び順", selection: $vm.sortKey) {
                        ForEach(SortKey.allCases, id: \.self) { key in
                            Text(key.displayName).tag(key)
                        }
                    }
                    Picker("順序", selection: $vm.sortOrder) {
                        Text("昇順").tag(SortOrder.ascending)
                        Text("降順").tag(SortOrder.descending)
                    }
                    Divider()
                    Toggle("フォルダを先頭に", isOn: $vm.foldersFirst)
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .onChange(of: viewModel.sortKey) { _, _ in
                    Task { await viewModel.applySortChange() }
                }
                .onChange(of: viewModel.sortOrder) { _, _ in
                    Task { await viewModel.applySortChange() }
                }
                .onChange(of: viewModel.foldersFirst) { _, _ in
                    Task { await viewModel.applySortChange() }
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

    // MARK: - 選択モードボトムバー

    @ViewBuilder
    private func selectModeBottomBar(viewModel: FileBrowserViewModel) -> some View {
        HStack {
            Spacer()
            Button {
                showAddToListSheet = true
            } label: {
                Label("リストに追加", systemImage: "plus.rectangle.on.rectangle")
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
            }
            .disabled(viewModel.selectedPaths.isEmpty)
            Spacer()
        }
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder
    private func fileContent(viewModel: FileBrowserViewModel) -> some View {
        Group {
            switch appEnvironment.viewPreferences.viewMode {
            case .list, .listDetail:
                listContent(viewModel: viewModel)
            case .gridTitled, .gridNoTitle, .gridDetail:
                gridContent(viewModel: viewModel)
            }
        }
        .refreshable {
            await viewModel.loadDirectory()
        }
    }

    // MARK: - リスト表示

    @ViewBuilder
    private func listContent(viewModel: FileBrowserViewModel) -> some View {
        let showDetail = appEnvironment.viewPreferences.viewMode == .listDetail
        List {
            ForEach(viewModel.filteredItems) { item in
                if viewModel.isSelectMode && (item.isMedia || item.isDirectory) {
                    selectableRow(item: item, viewModel: viewModel) {
                        FileRowView(item: item, thumbnail: viewModel.thumbnail(for: item), showDetail: showDetail)
                    }
                    .task(id: item.path) {
                        await viewModel.loadThumbnail(for: item)
                    }
                } else {
                    itemButton(item: item, viewModel: viewModel) {
                        FileRowView(item: item, thumbnail: viewModel.thumbnail(for: item), showDetail: showDetail)
                    }
                    .task(id: item.path) {
                        await viewModel.loadThumbnail(for: item)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .overlay { emptyOrLoadingOverlay(viewModel: viewModel) }
    }

    // MARK: - グリッド / コラム表示

    @ViewBuilder
    private func gridContent(viewModel: FileBrowserViewModel) -> some View {
        let gridItems = [GridItem(.adaptive(minimum: appEnvironment.viewPreferences.gridCellWidth), spacing: 8)]
        ScrollView {
            LazyVGrid(columns: gridItems, spacing: 8) {
                ForEach(viewModel.filteredItems) { item in
                    if viewModel.isSelectMode && (item.isMedia || item.isDirectory) {
                        selectableRow(item: item, viewModel: viewModel) {
                            gridCell(item: item, viewModel: viewModel)
                        }
                        .task(id: item.path) {
                            await viewModel.loadThumbnail(for: item)
                        }
                    } else {
                        itemButton(item: item, viewModel: viewModel) {
                            gridCell(item: item, viewModel: viewModel)
                        }
                        .task(id: item.path) {
                            await viewModel.loadThumbnail(for: item)
                        }
                    }
                }
            }
            .padding(8)
        }
        .overlay { emptyOrLoadingOverlay(viewModel: viewModel) }
    }

    // MARK: - グリッドセル

    @ViewBuilder
    private func gridCell(item: DirectoryItem, viewModel: FileBrowserViewModel) -> some View {
        switch appEnvironment.viewPreferences.viewMode {
        case .list, .listDetail:
            EmptyView()
        case .gridTitled:
            GridTitledCellView(item: item, thumbnail: viewModel.thumbnail(for: item))
        case .gridNoTitle:
            GridNoTitleCellView(item: item, thumbnail: viewModel.thumbnail(for: item))
        case .gridDetail:
            GridDetailCellView(item: item, thumbnail: viewModel.thumbnail(for: item))
        }
    }

    // MARK: - 選択モード行ラッパー

    @ViewBuilder
    private func selectableRow<Content: View>(
        item: DirectoryItem,
        viewModel: FileBrowserViewModel,
        @ViewBuilder content: () -> Content
    ) -> some View {
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
                content()
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - 共通ボタンラッパー

    @ViewBuilder
    private func itemButton<Content: View>(
        item: DirectoryItem,
        viewModel: FileBrowserViewModel,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if item.isDirectory {
            Button {
                appEnvironment.browsePathStore.enterDirectory(
                    item.path,
                    for: source,
                    rootPath: connection.startPath
                )
                navigationPath.append(item.path)
            } label: {
                content()
            }
            .buttonStyle(.plain)
        } else if item.isVideo {
            Button {
                openVideo(item, pageItems: viewModel.filteredItems)
            } label: {
                content()
            }
            .buttonStyle(.plain)
        } else if item.isPDF {
            Button {
                selectedRoute = MediaViewerPageSource(
                    source: source,
                    items: [item],
                    connection: connection,
                    startPositionSeconds: 0,
                    imagePagingOrder: .preserveInput,
                    readingDirection: .leftToRight
                ).route(for: item)
            } label: {
                content()
            }
            .buttonStyle(.plain)
        } else if item.isImage {
            Button {
                selectedRoute = MediaViewerPageSource
                    .remote(connection: connection, items: viewModel.filteredItems)
                    .route(for: item)
            } label: {
                content()
            }
            .buttonStyle(.plain)
        } else {
            content()
        }
    }

    // MARK: - 動画オープン（再生位置復元）

    private func openVideo(_ item: DirectoryItem, pageItems: [DirectoryItem]) {
        Task {
            let resumePlayback = UserDefaults.standard.object(forKey: "Settings.resumePlayback") as? Bool ?? true
            var startPosition: Double = 0
            if resumePlayback {
                startPosition = (try? await appEnvironment.watchHistoryRepository.fetchLastPosition(
                    sourceID: source.id,
                    filePath: item.path,
                    fileId: item.fileId
                )) ?? 0
            }
            let pageSource = MediaViewerPageSource(
                source: source,
                items: pageItems,
                connection: connection,
                startPositionSeconds: startPosition,
                imagePagingOrder: .naturalName,
                readingDirection: .rightToLeft
            )
            selectedRoute = pageSource.route(for: item)
        }
    }

    // MARK: - Overlay

    @ViewBuilder
    private func emptyOrLoadingOverlay(viewModel: FileBrowserViewModel) -> some View {
        if viewModel.isLoading {
            ProgressView()
        } else if let errorMessage = viewModel.errorMessage {
            ContentUnavailableView {
                Label("接続できません", systemImage: "externaldrive.badge.exclamationmark")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("再接続") {
                    Task { await viewModel.reconnect() }
                }
            }
        } else if viewModel.items.isEmpty {
            ContentUnavailableView("ファイルがありません", systemImage: "folder")
        }
    }

    // MARK: - Helpers

    private var isRoot: Bool {
        directoryPath == connection.startPath
    }

    private func currentFolderName(viewModel: FileBrowserViewModel) -> String {
        viewModel.breadcrumbs.last ?? connection.displayName
    }
}

// MARK: - FileRowView（リスト用）

private struct FileBrowserSearchSheet: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appEnvironment) private var appEnvironment

    let viewModel: FileBrowserViewModel
    let rootPath: String
    let connection: RemoteConnection
    let source: ContentSource
    let onReturnHome: (() async -> Void)?
    let onNavigateToDirectory: (DirectoryItem) -> Void

    @State private var searchText = ""
    @State private var isSelectMode = false
    @State private var selectedPaths: Set<String> = []
    @State private var selectedRoute: MediaViewerRoute?
    @State private var showAddToListSheet = false
    @State private var recursiveItems: [DirectoryItem] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var filteredItems: [DirectoryItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return recursiveItems }
        return recursiveItems.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var selectedItems: [DirectoryItem] {
        filteredItems.filter { selectedPaths.contains($0.path) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(filteredItems) { item in
                    Group {
                        if isSelectMode && (item.isMedia || item.isDirectory) {
                            Button {
                                toggleSelection(for: item)
                            } label: {
                                HStack {
                                    Image(systemName: selectedPaths.contains(item.path) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selectedPaths.contains(item.path) ? Color.accentColor : Color.secondary)
                                    FileRowView(item: item, thumbnail: viewModel.thumbnail(for: item), showDetail: true)
                                }
                            }
                            .buttonStyle(.plain)
                        } else {
                            Button {
                                handleTap(item)
                            } label: {
                                FileRowView(item: item, thumbnail: viewModel.thumbnail(for: item), showDetail: true)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .task(id: item.path) {
                        await viewModel.loadThumbnail(for: item)
                    }
                }
            }
            .searchable(text: $searchText, prompt: "このフォルダ内を検索")
            .navigationTitle("検索")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                await loadRecursiveItems()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if isSelectMode {
                        Button("完了") {
                            isSelectMode = false
                            selectedPaths.removeAll()
                        }
                    } else {
                        Button("選択") {
                            isSelectMode = true
                        }
                        .disabled(filteredItems.isEmpty)
                    }
                }
            }
            .overlay {
                if isLoading {
                    ProgressView()
                } else if let errorMessage {
                    ContentUnavailableView(
                        "検索に失敗しました",
                        systemImage: "exclamationmark.triangle",
                        description: Text(errorMessage)
                    )
                } else if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && filteredItems.isEmpty {
                    ContentUnavailableView(
                        "一致する項目がありません",
                        systemImage: "magnifyingglass",
                        description: Text("検索条件を変更してください")
                    )
                } else if filteredItems.isEmpty {
                    ContentUnavailableView(
                        "検索対象がありません",
                        systemImage: "magnifyingglass",
                        description: Text("このフォルダ配下に動画または画像がありません")
                    )
                }
            }
            .safeAreaInset(edge: .bottom) {
                if isSelectMode {
                    HStack {
                        Spacer()
                        Button {
                            showAddToListSheet = true
                        } label: {
                            Label("リストに追加", systemImage: "plus.rectangle.on.rectangle")
                                .padding(.horizontal, 20)
                                .padding(.vertical, 12)
                                .background(Color.accentColor)
                                .foregroundStyle(.white)
                                .clipShape(Capsule())
                        }
                        .disabled(selectedItems.isEmpty)
                        Spacer()
                    }
                    .padding(.vertical, 8)
                    .background(.bar)
                }
            }
        }
        .sheet(isPresented: $showAddToListSheet) {
            AddToListSheet(
                items: selectedItems,
                source: .remote(connection.id),
                connection: connection,
                fileRepository: viewModel.listRegistrationFileRepository
            )
            .environment(\.appEnvironment, appEnvironment)
        }
        .fullScreenCover(item: $selectedRoute) { route in
            MediaViewerContainerView(route: route, onReturnHome: onReturnHome)
                .environment(\.appEnvironment, appEnvironment)
        }
    }

    private func toggleSelection(for item: DirectoryItem) {
        if selectedPaths.contains(item.path) {
            selectedPaths.remove(item.path)
        } else {
            selectedPaths.insert(item.path)
        }
    }

    private func handleTap(_ item: DirectoryItem) {
        if item.isDirectory {
            dismiss()
            onNavigateToDirectory(item)
            return
        }
        if item.isVideo {
            openVideo(item)
            return
        }
        if item.isPDF {
            selectedRoute = MediaViewerPageSource(
                source: source,
                items: [item],
                connection: connection,
                startPositionSeconds: 0,
                imagePagingOrder: .preserveInput,
                readingDirection: .leftToRight
            ).route(for: item)
            return
        }
        if item.isImage {
            selectedRoute = MediaViewerPageSource
                .remote(connection: connection, items: filteredItems)
                .route(for: item)
        }
    }

    private func openVideo(_ item: DirectoryItem) {
        Task {
            let resumePlayback = UserDefaults.standard.object(forKey: "Settings.resumePlayback") as? Bool ?? true
            var startPosition: Double = 0
            if resumePlayback {
                startPosition = (try? await appEnvironment.watchHistoryRepository.fetchLastPosition(
                    sourceID: source.id,
                    filePath: item.path,
                    fileId: item.fileId
                )) ?? 0
            }
            let pageSource = MediaViewerPageSource(
                source: source,
                items: filteredItems,
                connection: connection,
                startPositionSeconds: startPosition,
                imagePagingOrder: .naturalName,
                readingDirection: .rightToLeft
            )
            selectedRoute = pageSource.route(for: item)
        }
    }

    private func loadRecursiveItems() async {
        isLoading = true
        defer { isLoading = false }
        let repo = viewModel.listRegistrationFileRepository

        do {
            let seedItems: [DirectoryItem]
            if viewModel.currentPath == rootPath, !viewModel.items.isEmpty {
                seedItems = viewModel.items
            } else {
                seedItems = try await repo.listDirectory(at: rootPath)
            }

            recursiveItems = await collectSearchableItems(from: seedItems, repository: repo)
            errorMessage = nil
        } catch {
            recursiveItems = viewModel.items.filter(\.isMedia)
            errorMessage = nil
        }
    }

    private func collectSearchableItems(
        from items: [DirectoryItem],
        repository: any FileRepository
    ) async -> [DirectoryItem] {
        var results: [DirectoryItem] = []
        var visitedPaths = Set<String>()

        func visit(_ item: DirectoryItem) async {
            guard visitedPaths.insert(item.path).inserted else { return }

            if item.isMedia {
                results.append(item)
                return
            }

            guard item.isDirectory else { return }

            do {
                let children = try await repository.listDirectory(at: item.path)
                for child in children {
                    await visit(child)
                }
            } catch {
                // 1つの子ディレクトリ取得失敗で検索全体を落とさない
            }
        }

        for item in items {
            await visit(item)
        }

        return results
    }
}

private struct FileRowView: View {
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
        }
    }

    private var iconName: String {
        switch item.itemType {
        case .directory: return "folder.fill"
        case .video:     return "play.rectangle.fill"
        case .image:     return "photo.fill"
        case .pdf:       return "doc.richtext.fill"
        case .other:     return "doc.fill"
        }
    }

    private var iconColor: Color {
        switch item.itemType {
        case .directory: return Constants.Theme.folderBlue
        case .video:     return .blue
        case .image:     return .green
        case .pdf:       return .red
        case .other:     return .secondary
        }
    }
}

// MARK: - GridTitledCellView（グリッド + タイトル）

private struct GridTitledCellView: View {
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

// MARK: - GridNoTitleCellView（グリッド タイトルなし）

private struct GridNoTitleCellView: View {
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

// MARK: - GridDetailCellView（詳細グリッド: タイトル + サイズ + 更新日時）

private struct GridDetailCellView: View {
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

// MARK: - GridSizePopoverView（セルサイズ変更ポップオーバー）

private struct GridSizePopoverView: View {
    @Binding var cellWidth: CGFloat

    private let minWidth: CGFloat = 80
    private let maxWidth: CGFloat = 280

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("グリッドサイズ")
                .font(.headline)

            HStack {
                Image(systemName: "square.grid.3x3")
                    .foregroundStyle(.secondary)
                Slider(
                    value: $cellWidth,
                    in: minWidth...maxWidth,
                    step: 10
                )
                Image(systemName: "square.grid.2x2")
                    .foregroundStyle(.secondary)
            }

            Text("セル幅: \(Int(cellWidth)) pt")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(minWidth: 280)
    }
}

// MARK: - DirectoryItem.ItemType + Placeholder

fileprivate extension DirectoryItem.ItemType {
    var placeholderIcon: String {
        switch self {
        case .directory: return "folder.fill"
        case .video:     return "film"
        case .image:     return "photo"
        case .pdf:       return "doc.richtext"
        case .other:     return "doc"
        }
    }

    var placeholderColor: Color {
        switch self {
        case .directory: return Constants.Theme.folderBlue
        case .pdf:       return .red
        default:         return .secondary
        }
    }
}
