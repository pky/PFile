import SwiftUI

struct MediaListsView: View {

    @Environment(\.appEnvironment) private var appEnvironment

    // リスト一覧
    @State private var listsViewModel: MediaListsViewModel?
    @State private var selectedListId: UUID?

    // 選択リストのファイル一覧
    @State private var detailViewModel: MediaListDetailViewModel?
    @State private var connections: [UUID: RemoteConnection] = [:]
    @State private var selectedRoute: MediaViewerRoute?

    // アラート
    @State private var showCreateAlert = false
    @State private var newListName = ""
    @State private var renameTarget: MediaList?
    @State private var renameText = ""

    // シート
    @State private var showTabOrderSheet = false
    @State private var showListManageSheet = false
    @State private var showDeleteListsSheet = false

    private var selectedList: MediaList? {
        guard let listsViewModel, let selectedListId else { return nil }
        return listsViewModel.lists.first { $0.id == selectedListId }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let listsViewModel {
                if listsViewModel.lists.isEmpty {
                    emptyState
                } else {
                    tabBar(viewModel: listsViewModel)
                    Divider()
                    fileList
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("リスト")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarItems() }
        .task {
            // 接続情報をまず読み込む
            await loadConnections()

            let vm = MediaListsViewModel(repository: appEnvironment.mediaListRepository)
            listsViewModel = vm
            await vm.load()

            if let first = vm.lists.first {
                await selectList(first)
            }
        }
        .onChange(of: selectedListId) { _, newId in
            guard let newId,
                  let list = listsViewModel?.lists.first(where: { $0.id == newId }) else { return }
            Task { await selectList(list) }
        }
        // アラート
        .alert("新しいリスト", isPresented: $showCreateAlert) {
            TextField("リスト名", text: $newListName)
            Button("作成") {
                let name = newListName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                newListName = ""
                Task {
                    await listsViewModel?.createList(name: name)
                    if let newList = listsViewModel?.lists.last {
                        await selectList(newList)
                    }
                }
            }
            Button("キャンセル", role: .cancel) { newListName = "" }
        }
        .alert("名前を変更", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("リスト名", text: $renameText)
            Button("変更") {
                guard let target = renameTarget,
                      !renameText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                let name = renameText
                renameTarget = nil
                Task { await listsViewModel?.renameList(target, to: name) }
            }
            Button("キャンセル", role: .cancel) { renameTarget = nil }
        }
        // シート
        .sheet(isPresented: $showListManageSheet) {
            if let vm = listsViewModel {
                ListManageSheet(viewModel: vm, selectedListId: $selectedListId)
            }
        }
        .sheet(isPresented: $showDeleteListsSheet) {
            if let vm = listsViewModel {
                DeleteListsSheet(viewModel: vm, selectedListId: $selectedListId)
            }
        }
        .sheet(isPresented: $showTabOrderSheet) {
            TabOrderSheet()
        }
        .onReceive(NotificationCenter.default.publisher(for: .mediaListsDidChange)) { _ in
            Task {
                await listsViewModel?.load()
                if let selectedListId,
                   !(listsViewModel?.lists.contains(where: { $0.id == selectedListId }) ?? false) {
                    let next = listsViewModel?.lists.first
                    self.selectedListId = next?.id
                    if let next {
                        await selectList(next)
                    } else {
                        detailViewModel = nil
                    }
                }
            }
        }
        // 動画・画像再生
        .fullScreenCover(item: $selectedRoute) { route in
            MediaViewerContainerView(route: route)
                .environment(\.appEnvironment, appEnvironment)
        }
    }

    // MARK: - 横スクロールタブバー

    @ViewBuilder
    private func tabBar(viewModel: MediaListsViewModel) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(viewModel.lists) { list in
                        tabButton(list: list, viewModel: viewModel)
                            .id(list.id)
                    }
                }
            }
            .onChange(of: selectedListId) { _, newId in
                if let id = newId {
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
        .frame(height: 44)
        .background(Color(.systemBackground))
    }

    @ViewBuilder
    private func tabButton(list: MediaList, viewModel: MediaListsViewModel) -> some View {
        let isSelected = selectedListId == list.id
        Button {
            selectedListId = list.id
        } label: {
            VStack(spacing: 0) {
                Text(list.name)
                    .font(.subheadline)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    .padding(.horizontal, 16)
                    .frame(maxHeight: .infinity)
                Rectangle()
                    .fill(isSelected ? Color.accentColor : Color.clear)
                    .frame(height: 2)
            }
        }
        .frame(height: 44)
        .contextMenu {
            Button {
                renameText = list.name
                renameTarget = list
            } label: {
                Label("名前を変更", systemImage: "pencil")
            }
            Button(role: .destructive) {
                Task {
                    await viewModel.deleteList(list)
                    if selectedListId == list.id {
                        let next = viewModel.lists.first
                        selectedListId = next?.id
                        if let next { await selectList(next) }
                    }
                }
            } label: {
                Label("削除", systemImage: "trash")
            }
        }
    }

    // MARK: - ファイル一覧

    @ViewBuilder
    private var fileList: some View {
        if let detailViewModel {
            List {
                ForEach(detailViewModel.files) { file in
                    Button {
                        selectedRoute = MediaViewerPageSource
                            .files(
                                sourceID: file.sourceID,
                                allFiles: detailViewModel.files,
                                connectionResolver: { sourceConnection(for: $0) }
                            )?
                            .route(for: file)
                    } label: {
                        fileRow(file: file, thumbnail: detailViewModel.thumbnail(for: file))
                    }
                    .task(id: file.id) {
                        await detailViewModel.loadThumbnail(for: file)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            Task { await detailViewModel.removeFile(file) }
                        } label: {
                            Label("削除", systemImage: "trash")
                        }
                    }
                }
            }
            .overlay {
                if detailViewModel.isLoading {
                    ProgressView()
                } else if detailViewModel.files.isEmpty {
                    ContentUnavailableView(
                        "ファイルがありません",
                        systemImage: "photo.on.rectangle",
                        description: Text("ファイルブラウザからリストに追加してください")
                    )
                }
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func fileRow(file: MediaFile, thumbnail: UIImage?) -> some View {
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
                Text(file.displaySubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func sourceConnection(for file: MediaFile) -> RemoteConnection? {
        if let connection = connections[file.connectionId] {
            return connection
        }
        guard file.sourceID.hasPrefix("remote:") else { return nil }
        let rawID = String(file.sourceID.dropFirst("remote:".count))
        guard let uuid = UUID(uuidString: rawID) else { return nil }
        return connections[uuid]
    }

    // MARK: - 空の状態

    @ViewBuilder
    private var emptyState: some View {
        ContentUnavailableView(
            "リストがありません",
            systemImage: "list.bullet",
            description: Text("右上のメニューからリストを作成してください")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - ツールバー

    @ToolbarContentBuilder
    private func toolbarItems() -> some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button {
                showListManageSheet = true
            } label: {
                Image(systemName: "list.bullet.indent")
            }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Button {
                showTabOrderSheet = true
            } label: {
                Image(systemName: "gearshape")
            }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Menu {
                Button {
                    showCreateAlert = true
                } label: {
                    Label("リストを作成", systemImage: "plus")
                }
                Button(role: .destructive) {
                    showDeleteListsSheet = true
                } label: {
                    Label("リストを削除", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    // MARK: - ヘルパー

    private func selectList(_ list: MediaList) async {
        selectedListId = list.id
        let vm = MediaListDetailViewModel(list: list, repository: appEnvironment.mediaListRepository)
        detailViewModel = vm
        await vm.load()
    }

    private func loadConnections() async {
        guard let all = try? await appEnvironment.remoteConnectionRepository.fetchAll() else { return }
        connections = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    }
}

// MARK: - ListManageSheet（並び替え・削除）

private struct ListManageSheet: View {

    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: MediaListsViewModel
    @Binding var selectedListId: UUID?

    var body: some View {
        NavigationStack {
            List {
                ForEach(viewModel.lists) { list in
                    Text(list.name)
                }
                .onMove { source, dest in
                    Task { await viewModel.moveLists(from: source, to: dest) }
                }
                .onDelete { offsets in
                    for index in offsets {
                        let list = viewModel.lists[index]
                        Task {
                            await viewModel.deleteList(list)
                            if selectedListId == list.id {
                                selectedListId = viewModel.lists.first?.id
                            }
                        }
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("リストを管理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }
                }
            }
        }
    }
}

private struct DeleteListsSheet: View {

    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: MediaListsViewModel
    @Binding var selectedListId: UUID?

    @State private var selectedListIds: Set<UUID> = []
    @State private var showDeleteConfirmation = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(viewModel.lists) { list in
                    Button {
                        toggleSelection(for: list.id)
                    } label: {
                        HStack {
                            Image(systemName: selectedListIds.contains(list.id)
                                ? "checkmark.circle.fill"
                                : "circle")
                            .foregroundStyle(selectedListIds.contains(list.id)
                                ? Color.accentColor
                                : Color.secondary)
                            Text(list.name)
                                .foregroundStyle(.primary)
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle("リストを削除")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("削除", role: .destructive) {
                        showDeleteConfirmation = true
                    }
                    .disabled(selectedListIds.isEmpty)
                }
            }
        }
        .alert("選択したリストを削除", isPresented: $showDeleteConfirmation) {
            Button("削除", role: .destructive) {
                Task { await deleteSelectedLists() }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("選択したリストを削除します。この操作は取り消せません。")
        }
    }

    private func toggleSelection(for listId: UUID) {
        if selectedListIds.contains(listId) {
            selectedListIds.remove(listId)
        } else {
            selectedListIds.insert(listId)
        }
    }

    private func deleteSelectedLists() async {
        let deletingLists = viewModel.lists.filter { selectedListIds.contains($0.id) }
        for list in deletingLists {
            await viewModel.deleteList(list)
        }

        if let selectedListId, selectedListIds.contains(selectedListId) {
            self.selectedListId = viewModel.lists.first?.id
        }

        dismiss()
    }
}
