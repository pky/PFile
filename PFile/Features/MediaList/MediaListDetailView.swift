import SwiftUI

struct MediaListDetailView: View {

    @Environment(\.appEnvironment) private var appEnvironment
    @Environment(\.editMode) private var systemEditMode
    let list: MediaList
    var isActive: Bool = true
    var onReturnHome: (() async -> Void)? = nil

    @State private var viewModel: MediaListDetailViewModel?
    @State private var selectedRoute: MediaViewerRoute?
    @State private var showRenameAlert = false
    @State private var renameText = ""
    @State private var editMode: EditMode = .inactive
    @State private var selectedFileIDs: Set<UUID> = []

    var body: some View {
        Group {
            if let viewModel {
                content(viewModel: viewModel)
            } else {
                ProgressView()
            }
        }
        .navigationTitle(list.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isActive {
                if let viewModel {
                    toolbarItems(viewModel: viewModel)
                }
                if isEditing {
                    ToolbarItem(placement: .bottomBar) {
                        Button(role: .destructive) {
                            Task { await removeSelectedFiles() }
                        } label: {
                            Text(selectedFileIDs.isEmpty
                                ? "リストから削除"
                                : "リストから削除(\(selectedFileIDs.count))")
                        }
                        .disabled(selectedFileIDs.isEmpty)
                    }
                }
            }
        }
        .task {
            guard isActive else { return }
            let vm = makeViewModel()
            viewModel = vm
            await vm.load()
        }
        .alert("名前を変更", isPresented: $showRenameAlert) {
            TextField("リスト名", text: $renameText)
            Button("変更") {
                guard !renameText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                let name = renameText
                Task {
                    try? await appEnvironment.mediaListRepository.renameList(list, to: name)
                    NotificationCenter.default.post(name: .mediaListsDidChange, object: nil)
                }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("リスト名を変更します。")
        }
        .fullScreenCover(item: $selectedRoute) { route in
            MediaViewerContainerView(route: route, onReturnHome: onReturnHome)
                .environment(\.appEnvironment, appEnvironment)
        }
        .environment(\.editMode, $editMode)
        .onChange(of: editMode) { _, newValue in
            if newValue != .active {
                selectedFileIDs.removeAll()
            }
        }
        .onChange(of: isActive) { _, newValue in
            guard newValue else { return }
            Task {
                await loadWhenActivated()
            }
        }
        .onChange(of: viewModel?.files.map(\.id) ?? []) { _, newIDs in
            selectedFileIDs = selectedFileIDs.intersection(Set(newIDs))
        }
        .onChange(of: viewModel?.sortKey) { _, _ in
            viewModel?.applySortChange()
        }
        .onChange(of: viewModel?.sortOrder) { _, _ in
            viewModel?.applySortChange()
        }
    }

    // MARK: - Toolbar

    @MainActor
    private func makeViewModel() -> MediaListDetailViewModel {
        MediaListDetailViewModel(
            list: list,
            repository: appEnvironment.mediaListRepository,
            remoteConnectionRepository: appEnvironment.remoteConnectionRepository,
            mediaThumbnailProvider: appEnvironment.mediaThumbnailProvider
        )
    }

    @MainActor
    private func loadWhenActivated() async {
        let vm: MediaListDetailViewModel
        if let existingViewModel = viewModel {
            vm = existingViewModel
        } else {
            let newViewModel = makeViewModel()
            viewModel = newViewModel
            vm = newViewModel
        }
        await vm.load()
    }

    @ToolbarContentBuilder
    private func toolbarItems(viewModel: MediaListDetailViewModel) -> some ToolbarContent {
        @Bindable var prefs = appEnvironment.viewPreferences
        @Bindable var detailViewModel = viewModel
        ToolbarItem(placement: .navigationBarTrailing) {
            if !isEditing {
                Button {
                    renameText = list.name
                    showRenameAlert = true
                } label: {
                    Image(systemName: "pencil")
                }
            }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Menu {
                Picker("表示形式", selection: $prefs.viewMode) {
                    ForEach(ViewMode.allCases, id: \.self) { mode in
                        Label(mode.displayName, systemImage: mode.systemImage).tag(mode)
                    }
                }
                Divider()
                Picker("並び順", selection: $detailViewModel.sortKey) {
                    ForEach(MediaListSortKey.allCases, id: \.self) { key in
                        Text(key.displayName).tag(key)
                    }
                }
                Picker("順序", selection: $detailViewModel.sortOrder) {
                    ForEach(SortOrder.allCases, id: \.self) { order in
                        Text(order.displayName).tag(order)
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
        ToolbarItem(placement: .navigationBarTrailing) {
            if !viewModel.files.isEmpty {
                EditButton()
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func content(viewModel: MediaListDetailViewModel) -> some View {
        switch appEnvironment.viewPreferences.viewMode {
        case .list, .listDetail:
            listContent(viewModel: viewModel)
        case .gridTitled, .gridNoTitle, .gridDetail:
            gridContent(viewModel: viewModel)
        }
    }

    // MARK: - リスト表示

    @ViewBuilder
    private func listContent(viewModel: MediaListDetailViewModel) -> some View {
        let showDetail = appEnvironment.viewPreferences.viewMode == .listDetail
        List(selection: $selectedFileIDs) {
            ForEach(viewModel.files) { file in
                Group {
                    if isEditing {
                        MediaFileRowView(
                            file: file,
                            thumbnail: viewModel.thumbnail(for: file),
                            showDetail: showDetail
                        )
                    } else {
                        Button {
                            openFile(file)
                        } label: {
                            MediaFileRowView(
                                file: file,
                                thumbnail: viewModel.thumbnail(for: file),
                                showDetail: showDetail
                            )
                        }
                        .foregroundStyle(.primary)
                    }
                }
                .task(id: file.id) {
                    await viewModel.loadThumbnail(for: file)
                }
                .tag(file.id)
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    if !isEditing {
                        Button(role: .destructive) {
                            Task { await viewModel.removeFile(file) }
                        } label: {
                            Label("削除", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .overlay { emptyOrLoadingOverlay(viewModel: viewModel) }
        .refreshable { await viewModel.load() }
    }

    // MARK: - グリッド表示

    @ViewBuilder
    private func gridContent(viewModel: MediaListDetailViewModel) -> some View {
        let gridItems = [GridItem(.adaptive(minimum: appEnvironment.viewPreferences.gridCellWidth), spacing: 8)]
        ScrollView {
            LazyVGrid(columns: gridItems, spacing: 8) {
                ForEach(viewModel.files) { file in
                    Button {
                        if isEditing {
                            toggleSelection(for: file)
                        } else {
                            openFile(file)
                        }
                    } label: {
                        gridCell(
                            file: file,
                            viewModel: viewModel,
                            isSelected: selectedFileIDs.contains(file.id)
                        )
                    }
                    .foregroundStyle(.primary)
                    .task(id: file.id) {
                        await viewModel.loadThumbnail(for: file)
                    }
                    .contextMenu {
                        if !isEditing {
                            Button(role: .destructive) {
                                Task { await viewModel.removeFile(file) }
                            } label: {
                                Label("削除", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .padding(8)
        }
        .overlay { emptyOrLoadingOverlay(viewModel: viewModel) }
        .refreshable { await viewModel.load() }
    }

    // MARK: - グリッドセル

    @ViewBuilder
    private func gridCell(file: MediaFile, viewModel: MediaListDetailViewModel, isSelected: Bool) -> some View {
        let thumbnail = viewModel.thumbnail(for: file)
        let placeholder = file.itemTypeRaw == "video" ? "play.rectangle.fill" : "photo.fill"
        switch appEnvironment.viewPreferences.viewMode {
        case .list, .listDetail:
            EmptyView()
        case .gridTitled:
            gridCellBody(isSelected: isSelected) {
                VStack(spacing: 4) {
                    MediaThumbnailView(thumbnail: thumbnail, placeholderSystemImage: placeholder)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .cornerRadius(6)
                    Text(file.name)
                        .font(.caption)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, minHeight: Constants.Grid.cellTitleHeight, maxHeight: Constants.Grid.cellTitleHeight, alignment: .top)
                }
            }
        case .gridNoTitle:
            gridCellBody(isSelected: isSelected) {
                MediaThumbnailView(thumbnail: thumbnail, placeholderSystemImage: placeholder)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .cornerRadius(6)
            }
        case .gridDetail:
            gridCellBody(isSelected: isSelected) {
                VStack(spacing: 4) {
                    MediaThumbnailView(thumbnail: thumbnail, placeholderSystemImage: placeholder)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .cornerRadius(6)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(file.name)
                            .font(.caption)
                            .lineLimit(2)
                            .foregroundStyle(.primary)
                        HStack(spacing: 4) {
                            Text(file.addedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: .autoupdatingCurrent)))
                            if let size = file.fileSize {
                                Text("·")
                                Text(size, format: .byteCount(style: .file))
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, minHeight: Constants.Grid.cellDetailInfoHeight, maxHeight: Constants.Grid.cellDetailInfoHeight, alignment: .topLeading)
                }
            }
        }
    }

    @ViewBuilder
    private func gridCellBody<Content: View>(isSelected: Bool, @ViewBuilder content: () -> Content) -> some View {
        ZStack(alignment: .topTrailing) {
            content()
            if isEditing {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .padding(6)
            }
        }
        .padding(4)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Overlay

    @ViewBuilder
    private func emptyOrLoadingOverlay(viewModel: MediaListDetailViewModel) -> some View {
        if viewModel.isLoading {
            ProgressView()
        } else if viewModel.files.isEmpty {
            ContentUnavailableView(
                "ファイルがありません",
                systemImage: "photo.on.rectangle",
                description: Text("ファイルブラウザからリストに追加してください")
            )
        }
    }

    // MARK: - Helpers

    private func openFile(_ file: MediaFile) {
        guard let viewModel else { return }
        Task {
            let resolvedFile = await viewModel.resolvePlayableFile(
                file,
                smbClientManager: appEnvironment.smbClientManager
            )
            var startPosition: Double = 0
            let resumePlayback = UserDefaults.standard.object(forKey: "Settings.resumePlayback") as? Bool ?? true
            if resumePlayback, resolvedFile.itemTypeRaw == "video" {
                startPosition = (try? await appEnvironment.watchHistoryRepository.fetchLastPosition(
                    sourceID: resolvedFile.sourceID,
                    filePath: resolvedFile.path
                )) ?? 0
            }
            selectedRoute = MediaViewerPageSource
                .files(
                    sourceID: resolvedFile.sourceID,
                    allFiles: viewModel.files,
                    connectionResolver: { viewModel.sourceConnection(for: $0) },
                    startPositionSeconds: startPosition
                )?
                .route(for: resolvedFile)
        }
    }

    private var isEditing: Bool {
        editMode == .active || systemEditMode?.wrappedValue == .active
    }

    private func toggleSelection(for file: MediaFile) {
        if selectedFileIDs.contains(file.id) {
            selectedFileIDs.remove(file.id)
        } else {
            selectedFileIDs.insert(file.id)
        }
    }

    private func removeSelectedFiles() async {
        guard let viewModel else { return }
        let filesToRemove = viewModel.files.filter { selectedFileIDs.contains($0.id) }
        guard !filesToRemove.isEmpty else { return }
        await viewModel.removeFiles(filesToRemove)
        selectedFileIDs.removeAll()
        editMode = .inactive
    }
}

// MARK: - MediaFileRowView

private struct MediaFileRowView: View {
    let file: MediaFile
    let thumbnail: UIImage?
    var showDetail: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            MediaThumbnailView(
                thumbnail: thumbnail,
                placeholderSystemImage: file.itemTypeRaw == "video" ? "play.rectangle.fill" : "photo.fill",
                width: 80,
                height: 45
            )
            .cornerRadius(6)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if showDetail {
                    Text(file.displaySubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }
}
