import SwiftUI

// MARK: - MainTab

enum MainTab: Hashable {
    case browse
    case history
    case list(UUID)
}

// MARK: - TabNavigator

struct TabNavigator {

    /// 全タブを順序付きで返す（browse → history → list...）
    static func allTabs(lists: [MediaList]) -> [MainTab] {
        var tabs: [MainTab] = [.browse, .history]
        tabs += lists.map { .list($0.id) }
        return tabs
    }

    /// current から offset 個隣のタブを返す。境界外は nil
    static func adjacentTab(to current: MainTab, in tabs: [MainTab], offset: Int) -> MainTab? {
        guard let index = tabs.firstIndex(of: current) else { return nil }
        let newIndex = index + offset
        guard newIndex >= 0, newIndex < tabs.count else { return nil }
        return tabs[newIndex]
    }
}

// MARK: - HomeView

struct HomeView: View {

    @Environment(\.appEnvironment) private var appEnvironment

    // 接続先管理
    @State private var connectionsViewModel: HomeViewModel?
    @State private var localFoldersViewModel: LocalFolderSourcesViewModel?
    @State private var showConnectionAdd = false
    @State private var showFolderPicker = false
    @State private var connectionToEdit: RemoteConnection?
    @State private var connectionToDelete: RemoteConnection?
    @State private var localFolderToDelete: LocalFolderSource?
    @State private var selectedSource: ContentSource?
    @State private var showSettings = false

    // タブ管理
    @State private var selectedTab: MainTab = .browse
    // スワイプ遷移
    @State private var dragOffset: CGFloat = 0
    @State private var targetTab: MainTab? = nil
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @Namespace private var tabIndicator

#if DEBUG && targetEnvironment(simulator)
    private static let simulatorVideosSourceID = UUID(uuidString: "00000000-0000-0000-0000-000000000017")!
    private static var simulatorVideosRootURL: URL {
        let path = ProcessInfo.processInfo.environment["PFILE_SIMULATOR_VIDEOS_ROOT"] ?? "/Volumes/videos"
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private var simulatorVideosSource: LocalFolderSource {
        LocalFolderSource(
            id: Self.simulatorVideosSourceID,
            displayName: "Simulator Videos",
            bookmarkData: Data()
        )
    }
#endif

    // リスト管理
    @State private var listsViewModel: MediaListsViewModel?
    @State private var showCreateListAlert = false
    @State private var showDeleteListsSheet = false
    @State private var newListName = ""
    @State private var renameTarget: MediaList?
    @State private var renameText = ""

    private var currentScopeID: String? {
        selectedSource?.id
    }

    private func selectSource(_ source: ContentSource) {
        selectedSource = source
        selectedTab = .browse
        columnVisibility = .detailOnly
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebarContent
                .navigationTitle("PFile")
        } detail: {
            detailContent
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environment(\.appEnvironment, appEnvironment)
        }
        .sheet(isPresented: $showConnectionAdd) {
            Task { await connectionsViewModel?.loadConnections() }
        } content: {
            ConnectionAddView()
                .environment(\.appEnvironment, appEnvironment)
        }
        .sheet(isPresented: $showFolderPicker, onDismiss: {
            Task { await localFoldersViewModel?.loadSources() }
        }) {
            FolderPickerView { url in
                Task {
                    _ = await localFoldersViewModel?.addFolder(from: url)
                }
                showFolderPicker = false
            } onCancel: {
                showFolderPicker = false
            }
        }
        .sheet(item: $connectionToEdit, onDismiss: {
            Task { await connectionsViewModel?.loadConnections() }
        }) { connection in
            ConnectionEditView(connection: connection)
                .environment(\.appEnvironment, appEnvironment)
        }
        .alert("新しいリスト", isPresented: $showCreateListAlert) {
            TextField("リスト名", text: $newListName)
            Button("作成") {
                let name = newListName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                newListName = ""
                Task {
                    await listsViewModel?.createList(name: name)
                    if let last = listsViewModel?.lists.last {
                        selectedTab = .list(last.id)
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
        .sheet(isPresented: $showDeleteListsSheet) {
            if let vm = listsViewModel {
                HomeDeleteListsSheet(viewModel: vm, selectedTab: $selectedTab)
            }
        }
        .alert("接続先を削除", isPresented: Binding(
            get: { connectionToDelete != nil },
            set: { if !$0 { connectionToDelete = nil } }
        )) {
            Button("削除", role: .destructive) {
                guard let connection = connectionToDelete else { return }
                if selectedSource == .remote(connection.id) {
                    selectedSource = nil
                }
                connectionToDelete = nil
                Task { await connectionsViewModel?.delete(connection) }
            }
            Button("キャンセル", role: .cancel) {
                connectionToDelete = nil
            }
        } message: {
            Text("接続先を削除します。この操作は取り消せません。")
        }
        .alert("ローカルフォルダを削除", isPresented: Binding(
            get: { localFolderToDelete != nil },
            set: { if !$0 { localFolderToDelete = nil } }
        )) {
            Button("削除", role: .destructive) {
                guard let localFolder = localFolderToDelete else { return }
                if selectedSource == .localFolder(localFolder.id) {
                    selectedSource = nil
                }
                localFolderToDelete = nil
                Task { await localFoldersViewModel?.delete(localFolder) }
            }
            Button("キャンセル", role: .cancel) {
                localFolderToDelete = nil
            }
        } message: {
            Text("ローカルフォルダを削除します。この操作は取り消せません。")
        }
        .alert(
            "ローカルフォルダ追加エラー",
            isPresented: Binding(
                get: { localFoldersViewModel?.errorMessage != nil },
                set: { if !$0 { localFoldersViewModel?.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(localFoldersViewModel?.errorMessage ?? "")
        }
        .task {
            let cvm = HomeViewModel(remoteConnectionRepository: appEnvironment.remoteConnectionRepository)
            connectionsViewModel = cvm
            await cvm.loadConnections()

            let lfvm = LocalFolderSourcesViewModel(repository: appEnvironment.localFolderSourceRepository)
            localFoldersViewModel = lfvm
            await lfvm.loadSources()

            let lvm = MediaListsViewModel(
                repository: appEnvironment.mediaListRepository,
                scopeID: currentScopeID,
                showsAllWhenScopeMissing: false
            )
            listsViewModel = lvm
            await lvm.load()
        }
        .task {
            await appEnvironment.purchaseService.configure()
        }
        .onChange(of: selectedSource) { _, _ in
            Task {
                await listsViewModel?.updateScope(currentScopeID)
                if case .list(let id) = selectedTab,
                   !(listsViewModel?.lists.contains(where: { $0.id == id }) ?? false) {
                    selectedTab = .browse
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .appDataDidRestore)) { _ in
            Task {
                await reloadRestoredAppData()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .mediaListsDidChange)) { _ in
            Task {
                await listsViewModel?.updateScope(currentScopeID)
                if case .list(let id) = selectedTab,
                   !(listsViewModel?.lists.contains(where: { $0.id == id }) ?? false) {
                    selectedTab = .browse
                }
            }
        }
    }

    // MARK: - Sidebar（ソース一覧）

    @ViewBuilder
    private var sidebarContent: some View {
        if let viewModel = connectionsViewModel {
            List {
                Section {
                    if let localFoldersViewModel {
                        if localFoldersViewModel.sources.isEmpty {
                            localFolderEmptyStateRow
                        }
#if DEBUG && targetEnvironment(simulator)
                        simulatorVideosButton
#endif
                        ForEach(localFoldersViewModel.sources) { source in
                            Button {
                                selectSource(.localFolder(source.id))
                            } label: {
                                LocalFolderSourceRowView(source: source)
                            }
                            .listRowBackground(
                                selectedSource == .localFolder(source.id)
                                    ? Color.accentColor.opacity(0.15)
                                    : nil
                            )
                            .contextMenu {
                                Button(role: .destructive) {
                                    localFolderToDelete = source
                                } label: {
                                    Label("削除", systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    localFolderToDelete = source
                                } label: {
                                    Label("削除", systemImage: "trash")
                                }
                            }
                        }
                    }
                    localSourceButton(.photoLibrary)
                } header: {
                    sectionHeader(title: "ローカル", buttonTitle: "ローカルフォルダを追加") {
                        showFolderPicker = true
                    }
                } footer: {
                    Text("フォトライブラリは固定項目です。ローカルフォルダは Files から追加し、長押しまたはスワイプで削除できます。")
                }

                Section {
                    ForEach(viewModel.connections) { connection in
                        Button {
                            selectSource(.remote(connection.id))
                        } label: {
                            ConnectionRowView(connection: connection)
                        }
                        .listRowBackground(
                            selectedSource == .remote(connection.id)
                                ? Color.accentColor.opacity(0.15)
                                : nil
                        )
                        .contextMenu {
                            Button {
                                connectionToEdit = connection
                            } label: {
                                Label("編集", systemImage: "pencil")
                            }

                            Button(role: .destructive) {
                                connectionToDelete = connection
                            } label: {
                                Label("削除", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                connectionToDelete = connection
                            } label: {
                                Label("削除", systemImage: "trash")
                            }

                            Button {
                                connectionToEdit = connection
                            } label: {
                                Label("編集", systemImage: "pencil")
                            }
                            .tint(.orange)
                        }
                    }
                } header: {
                    sectionHeader(title: "ネットワーク", buttonTitle: "接続先を追加") {
                        showConnectionAdd = true
                    }
                } footer: {
                    Text("接続先は長押しまたはスワイプで編集・削除できます。")
                }
            }
            .overlay {
                if viewModel.isLoading {
                    ProgressView()
                }
            }
        } else {
            ProgressView()
        }
    }

    @ViewBuilder
    private func localSourceButton(_ source: ContentSource) -> some View {
        Button {
            selectSource(source)
        } label: {
            SourceRowView(source: source)
        }
        .listRowBackground(
            selectedSource == source
                ? Color.accentColor.opacity(0.15)
                : nil
        )
    }

    @MainActor
    private func reloadRestoredAppData() async {
        await connectionsViewModel?.loadConnections()
        await localFoldersViewModel?.loadSources()
        await listsViewModel?.updateScope(currentScopeID)

        if let selectedSource {
            switch selectedSource {
            case .remote(let id):
                if !(connectionsViewModel?.connections.contains(where: { $0.id == id }) ?? false) {
                    self.selectedSource = nil
                    selectedTab = .browse
                }
            case .localFolder(let id):
#if DEBUG && targetEnvironment(simulator)
                if id == Self.simulatorVideosSourceID {
                    break
                }
#endif
                if !(localFoldersViewModel?.sources.contains(where: { $0.id == id }) ?? false) {
                    self.selectedSource = nil
                    selectedTab = .browse
                }
            case .photoLibrary:
                break
            }
        }

        if case .list(let id) = selectedTab,
           !(listsViewModel?.lists.contains(where: { $0.id == id }) ?? false) {
            selectedTab = .browse
        }
    }

    // MARK: - Detail（横スクロールタブ + コンテンツ）

    @ViewBuilder
    private var detailContent: some View {
        if selectedSource == nil {
            sourcePickerContent
        } else {
            VStack(spacing: 0) {
                mainTabBar
                mainContent
                if shouldShowAdBanner {
                    homeAdBanner
                }
            }
            .background(Constants.Theme.panelBackground)
        }
    }

    private var shouldShowAdBanner: Bool {
        appEnvironment.purchaseService.shouldShowAds
    }

    private var homeAdBanner: some View {
        HStack {
            Spacer(minLength: 0)
            AdBannerView()
                .frame(width: 320, height: 50)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(.bar)
    }

    // MARK: - ソース選択画面（未選択時のホーム画面）

    @ViewBuilder
    private var sourcePickerContent: some View {
        List {
            Section {
                if let localFoldersViewModel {
                    if localFoldersViewModel.sources.isEmpty {
                        localFolderEmptyStateRow
                    }
#if DEBUG && targetEnvironment(simulator)
                    simulatorVideosButton
#endif
                    ForEach(localFoldersViewModel.sources) { source in
                        Button {
                            selectSource(.localFolder(source.id))
                        } label: {
                            LocalFolderSourceRowView(source: source)
                        }
                    }
                }
                localSourcePickerButton(.photoLibrary)
            } header: {
                sectionHeader(title: "ローカル", buttonTitle: "ローカルフォルダを追加") {
                    showFolderPicker = true
                }
            } footer: {
                Text("Filesアプリからフォルダを選ぶと、ここに追加されます。")
            }

            Section {
                if let connectionsViewModel {
                    ForEach(connectionsViewModel.connections) { connection in
                        Button {
                            selectSource(.remote(connection.id))
                        } label: {
                            ConnectionRowView(connection: connection)
                        }
                    }
                }
            } header: {
                sectionHeader(title: "ネットワーク", buttonTitle: "接続先を追加") {
                    showConnectionAdd = true
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("PFile")
        .navigationBarTitleDisplayMode(.large)
    }

    @ViewBuilder
    private func localSourcePickerButton(_ source: ContentSource) -> some View {
        Button {
            selectSource(source)
        } label: {
            SourceRowView(source: source)
        }
    }

    private var localFolderEmptyStateRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("ローカルフォルダはまだ追加されていません")
                .font(.subheadline)
            Text("「ローカルフォルダを追加」から選んだフォルダが、ここに表示されます。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

#if DEBUG && targetEnvironment(simulator)
    private var simulatorVideosButton: some View {
        Button {
            selectSource(.localFolder(Self.simulatorVideosSourceID))
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Simulator Videos")
                    Text(Self.simulatorVideosRootURL.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "iphone")
                    .foregroundStyle(.tint)
            }
        }
        .listRowBackground(
            selectedSource == .localFolder(Self.simulatorVideosSourceID)
                ? Color.accentColor.opacity(0.15)
                : nil
        )
    }

    private var simulatorVideosBrowserView: some View {
        LocalFolderBrowserView(
            source: simulatorVideosSource,
            directRootURL: Self.simulatorVideosRootURL
        )
        .id(Self.simulatorVideosSourceID)
    }
#endif

    private func sectionHeader(title: String, buttonTitle: String, action: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            Button(buttonTitle, action: action)
                .font(.caption.weight(.semibold))
                .buttonStyle(.plain)
        }
        .textCase(nil)
    }

    // MARK: - 横スクロールタブバー

    // SCSS参考: アイコン1.5em(27px) + テキスト18px + 上下パディング各5px ≈ 55px
    // 「もっともっと余白を増やして欲しい」→ さらに大きく
    private let tabBarHeight: CGFloat = Constants.Layout.mainTabBarHeight

    @ViewBuilder
    private var mainTabBar: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .bottom, spacing: 0) {
                        fixedTabButton(.browse, title: "ブラウズ", systemImage: "externaldrive")
                        fixedTabButton(.history, title: "履歴", systemImage: "clock")

                        if let listsViewModel {
                            ForEach(listsViewModel.lists) { list in
                                listTabButton(list: list)
                                    .id(list.id)
                            }
                        }

                        Menu {
                            Button {
                                showCreateListAlert = true
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
                                .font(.title2)
                                .foregroundStyle(Constants.Theme.tabCyan.opacity(0.7))
                                .frame(width: 72, height: tabBarHeight)
                        }
                        .disabled(currentScopeID == nil)
                    }
                }
                .onChange(of: selectedTab) { _, newTab in
                    if case .list(let id) = newTab {
                        withAnimation { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }

            // 設定ボタン（スクロール範囲外の右端に固定）
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.title2)
                    .foregroundStyle(Color.primary.opacity(0.8))
                    .frame(width: 72, height: tabBarHeight)
            }
        }
        .frame(height: tabBarHeight)
        .background(Constants.Theme.panelBackground)
    }

    @ViewBuilder
    private func fixedTabButton(_ tab: MainTab, title: String, systemImage: String) -> some View {
        let isSelected = selectedTab == tab
        Button {
            withAnimation(.spring(response: 0.33, dampingFraction: 0.75)) {
                selectedTab = tab
            }
        } label: {
            VStack(spacing: 6) {
                Spacer(minLength: 0)
                Image(systemName: systemImage)
                    .font(.title2)
                Text(title)
                    .font(.body)
                    .fontWeight(isSelected ? .bold : .regular)
                // インジケーター枠は常に確保し、選択時のみ実体を表示
                ZStack {
                    Color.clear.frame(width: 50, height: 4)
                    if isSelected {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Constants.Theme.tabCyan)
                            .frame(width: 50, height: 4)
                            .matchedGeometryEffect(id: "tabIndicator", in: tabIndicator)
                    }
                }
            }
            .foregroundStyle(isSelected ? Constants.Theme.tabCyan : Color.primary)
            .padding(.bottom, 10)
            .padding(.horizontal, 28)
            .frame(height: tabBarHeight)
        }
    }

    @ViewBuilder
    private func listTabButton(list: MediaList) -> some View {
        let isSelected = selectedTab == .list(list.id)
        Button {
            withAnimation(.spring(response: 0.33, dampingFraction: 0.75)) {
                selectedTab = .list(list.id)
            }
        } label: {
            VStack(spacing: 6) {
                Spacer(minLength: 0)
                Text(list.name)
                    .font(.body)
                    .fontWeight(isSelected ? .bold : .regular)
                ZStack {
                    Color.clear.frame(width: 50, height: 4)
                    if isSelected {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Constants.Theme.tabCyan)
                            .frame(width: 50, height: 4)
                            .matchedGeometryEffect(id: "tabIndicator", in: tabIndicator)
                    }
                }
            }
            .foregroundStyle(isSelected ? Constants.Theme.tabCyan : Color.primary)
            .padding(.bottom, 10)
            .padding(.horizontal, 28)
            .frame(height: tabBarHeight)
        }
        .contextMenu {
            Button {
                renameText = list.name
                renameTarget = list
            } label: {
                Label("名前を変更", systemImage: "pencil")
            }
            Button(role: .destructive) {
                Task {
                    await listsViewModel?.deleteList(list)
                    if case .list(let id) = selectedTab, id == list.id {
                        selectedTab = .browse
                    }
                }
            } label: {
                Label("削除", systemImage: "trash")
            }
        }
    }

    // MARK: - タブコンテンツ

    /// ドラッグ中の各タブの水平オフセットを返す
    private func tabOffset(for tab: MainTab, containerWidth: CGFloat) -> CGFloat {
        if tab == selectedTab { return dragOffset }
        if tab == targetTab {
            return dragOffset > 0
                ? dragOffset - containerWidth   // 前タブ（左から来る）
                : dragOffset + containerWidth   // 次タブ（右から来る）
        }
        return 0
    }

    /// ドラッグ中に表示すべきタブかどうか
    private func tabVisible(for tab: MainTab) -> Bool {
        tab == selectedTab || tab == targetTab
    }

    /// コンテンツエリアの水平スワイプジェスチャー
    private func swipeGesture(containerWidth: CGFloat) -> some Gesture {
        let lists = listsViewModel?.lists ?? []
        let tabs = TabNavigator.allTabs(lists: lists)

        return DragGesture(minimumDistance: 20)
            .onChanged { value in
                let h = value.translation.width
                let v = value.translation.height
                // 縦スクロールを優先: 水平成分が縦より大きいときのみ処理
                // ドラッグ開始後は軸をロックしてジャークを防ぐ
                guard abs(h) > abs(v) || dragOffset != 0 else { return }

                // ジェスチャー開始時のみターゲットを決定（方向反転で意図しないフリップを防ぐ）
                if dragOffset == 0 {
                    let direction = h < 0 ? 1 : -1
                    targetTab = TabNavigator.adjacentTab(to: selectedTab, in: tabs, offset: direction)
                }

                // ターゲットがないときはゴムバンド（抵抗をかける）
                if targetTab == nil {
                    dragOffset = h / 4
                } else {
                    dragOffset = h
                }
            }
            .onEnded { value in
                let h = value.translation.width
                let predictedH = value.predictedEndTranslation.width
                let threshold = containerWidth * 0.3

                if let next = targetTab,
                   (h < -threshold || predictedH < -containerWidth * 0.6) {
                    // 次タブへ確定（左スワイプ）
                    withAnimation(.spring(response: 0.33, dampingFraction: 0.8), completionCriteria: .logicallyComplete) {
                        dragOffset = -containerWidth
                    } completion: {
                        selectedTab = next
                        dragOffset = 0
                        targetTab = nil
                    }
                } else if let prev = targetTab,
                          (h > threshold || predictedH > containerWidth * 0.6) {
                    // 前タブへ確定（右スワイプ）
                    withAnimation(.spring(response: 0.33, dampingFraction: 0.8), completionCriteria: .logicallyComplete) {
                        dragOffset = containerWidth
                    } completion: {
                        selectedTab = prev
                        dragOffset = 0
                        targetTab = nil
                    }
                } else {
                    // スプリングバック
                    withAnimation(.spring(response: 0.33, dampingFraction: 0.8)) {
                        dragOffset = 0
                        targetTab = nil
                    }
                }
            }
    }

    @ViewBuilder
    private var mainContent: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack {
                // ブラウズタブ
                Group {
                    switch selectedSource {
                    case .remote(let connectionID):
                        if let connection = connectionsViewModel?.connections.first(where: { $0.id == connectionID }) {
                            FileBrowserView(
                                connection: connection,
                                isActive: selectedTab == .browse,
                                onConnectionUnavailable: {
                                    guard selectedSource == .remote(connection.id) else { return }
                                    selectedSource = nil
                                    selectedTab = .browse
                                },
                                onReturnHome: {
                                    guard selectedSource == .remote(connection.id) else { return }
                                    selectedSource = nil
                                    selectedTab = .browse
                                }
                            )
                                .id(connection.id)
                        } else {
                            ContentUnavailableView("接続先を選択", systemImage: "externaldrive.connected.to.line.below")
                        }
                    case .localFolder(let sourceID):
#if DEBUG && targetEnvironment(simulator)
                        if sourceID == Self.simulatorVideosSourceID {
                            simulatorVideosBrowserView
                        } else if let source = localFoldersViewModel?.sources.first(where: { $0.id == sourceID }) {
                            LocalFolderBrowserView(source: source)
                                .id(source.id)
                        } else {
                            ContentUnavailableView("ローカルフォルダを選択", systemImage: "internaldrive")
                        }
#else
                        if let source = localFoldersViewModel?.sources.first(where: { $0.id == sourceID }) {
                            LocalFolderBrowserView(source: source)
                                .id(source.id)
                        } else {
                            ContentUnavailableView("ローカルフォルダを選択", systemImage: "internaldrive")
                        }
#endif
                    case .photoLibrary:
                        PhotoLibraryBrowserView(isActive: selectedTab == .browse)
                    case nil:
                        ContentUnavailableView("ソースを選択", systemImage: "square.on.square")
                    }
                }
                .opacity(tabVisible(for: .browse) ? 1 : 0)
                .allowsHitTesting(selectedTab == .browse)
                .offset(x: tabOffset(for: .browse, containerWidth: width))

                // 履歴タブ
                WatchHistoryListView(
                    isActive: selectedTab == .history,
                    sourceID: currentScopeID,
                    onReturnHome: returnToHome
                )
                    .safeAreaInset(edge: .top, spacing: 0) {
                        Constants.Theme.panelBackground
                            .frame(height: Constants.Layout.breadcrumbBarHeight)
                    }
                    .opacity(tabVisible(for: .history) ? 1 : 0)
                    .allowsHitTesting(selectedTab == .history)
                    .offset(x: tabOffset(for: .history, containerWidth: width))

                // リストタブ（全リストを独立したインスタンスとして常時保持）
                if let listsViewModel {
                    ForEach(listsViewModel.lists) { list in
                        MediaListDetailView(
                            list: list,
                            isActive: selectedTab == .list(list.id),
                            onReturnHome: returnToHome
                        )
                            .safeAreaInset(edge: .top, spacing: 0) {
                                Color(.systemBackground)
                                    .frame(height: Constants.Layout.breadcrumbBarHeight)
                            }
                            .opacity(tabVisible(for: .list(list.id)) ? 1 : 0)
                            .allowsHitTesting(selectedTab == .list(list.id))
                            .offset(x: tabOffset(for: .list(list.id), containerWidth: width))
                    }
                }
            }
            .clipped()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Constants.Theme.panelBackground)
            .gesture(swipeGesture(containerWidth: width))
        }
    }

    private func returnToHome() async {
        selectedSource = nil
        selectedTab = .browse
    }

}

private struct LocalFolderSourceRowView: View {
    let source: LocalFolderSource

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(source.displayName)
                Text("Files のフォルダ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "internaldrive")
                .foregroundStyle(.tint)
        }
    }
}

private struct HomeDeleteListsSheet: View {

    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: MediaListsViewModel
    @Binding var selectedTab: MainTab

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

        if case .list(let id) = selectedTab, selectedListIds.contains(id) {
            selectedTab = .browse
        }

        dismiss()
    }
}

// MARK: - ConnectionRowView

private struct ConnectionRowView: View {
    let connection: RemoteConnection

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(connection.displayName)
                Text(connection.serviceType.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: iconName)
                .foregroundStyle(.tint)
        }
    }

    private var iconName: String {
        switch connection.serviceType {
        case .smb:                      return "externaldrive.connected.to.line.below"
        case .ftp, .ftps, .sftp:       return "server.rack"
        case .webdav:                   return "globe"
        case .dropbox, .googleDrive, .oneDrive: return "cloud"
        }
    }
}

// MARK: - SourceRowView

private struct SourceRowView: View {
    let source: ContentSource

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(source.displayName)
                HStack(spacing: 6) {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if source == .photoLibrary {
                        Text("固定")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.12))
                            .clipShape(Capsule())
                    }
                }
            }
        } icon: {
            sourceIcon
        }
    }

    private var subtitle: String {
        switch source {
        case .remote:
            return "ネットワーク接続"
        case .localFolder(_):
            return "Files のフォルダを開く"
        case .photoLibrary:
            return "写真と動画を表示"
        }
    }

    @ViewBuilder
    private var sourceIcon: some View {
        switch source {
        case .remote:
            Image(systemName: "externaldrive.connected.to.line.below")
                .foregroundStyle(.tint)
        case .localFolder(_):
            Image(systemName: "internaldrive")
                .foregroundStyle(.tint)
        case .photoLibrary:
            PhotoLibraryIconView()
        }
    }
}

private struct PhotoLibraryIconView: View {
    private let petalColors: [Color] = [
        .red,
        .orange,
        .yellow,
        .green,
        .mint,
        .blue,
        .indigo,
        .pink
    ]

    var body: some View {
        ZStack {
            ForEach(Array(petalColors.enumerated()), id: \.offset) { index, color in
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [color.opacity(0.95), color.opacity(0.7)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 10, height: 10)
                    .offset(y: -8)
                    .rotationEffect(.degrees(Double(index) * 45))
            }

            Circle()
                .fill(.white)
                .frame(width: 7, height: 7)
        }
        .frame(width: 22, height: 22)
        .shadow(color: .black.opacity(0.08), radius: 1, y: 0.5)
    }
}
