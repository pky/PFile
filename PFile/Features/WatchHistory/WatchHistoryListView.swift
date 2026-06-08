import SwiftUI

struct WatchHistoryListView: View {

    @Environment(\.appEnvironment) private var appEnvironment
    var isActive: Bool = true
    var sourceID: String? = nil
    var onReturnHome: (() async -> Void)? = nil
    @State private var viewModel: WatchHistoryListViewModel?
    @State private var selectedRoute: MediaViewerRoute?

    var body: some View {
        Group {
            if let viewModel {
                content(viewModel: viewModel)
            } else {
                ProgressView()
            }
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isActive, let viewModel {
                toolbarItems(viewModel: viewModel)
            }
        }
        .task {
            guard isActive else { return }
            let vm = makeViewModel()
            viewModel = vm
            await vm.load(sourceID: sourceID)
        }
        .onChange(of: sourceID) { _, newValue in
            guard let viewModel else { return }
            Task {
                await viewModel.load(sourceID: newValue)
            }
        }
        .onChange(of: isActive) { _, newValue in
            guard newValue else { return }
            Task {
                await loadWhenActivated()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .playbackHistoryDidChange)) { notification in
            guard isActive, let viewModel else { return }
            let changedSourceID = notification.userInfo?["sourceID"] as? String
            guard changedSourceID == nil || changedSourceID == sourceID else { return }
            Task {
                await viewModel.load(sourceID: sourceID)
            }
        }
        .fullScreenCover(item: $selectedRoute, onDismiss: {
            guard let viewModel else { return }
            Task {
                await viewModel.load(sourceID: sourceID)
            }
        }) { route in
            MediaViewerContainerView(route: route, onReturnHome: onReturnHome)
                .environment(\.appEnvironment, appEnvironment)
        }
    }

    // MARK: - Toolbar

    @MainActor
    private func makeViewModel() -> WatchHistoryListViewModel {
        WatchHistoryListViewModel(
            watchHistoryRepository: appEnvironment.watchHistoryRepository,
            remoteConnectionRepository: appEnvironment.remoteConnectionRepository,
            mediaThumbnailProvider: appEnvironment.mediaThumbnailProvider
        )
    }

    @MainActor
    private func loadWhenActivated() async {
        let vm: WatchHistoryListViewModel
        if let existingViewModel = viewModel {
            vm = existingViewModel
        } else {
            let newViewModel = makeViewModel()
            viewModel = newViewModel
            vm = newViewModel
        }
        await vm.load(sourceID: sourceID)
    }

    @ToolbarContentBuilder
    private func toolbarItems(viewModel: WatchHistoryListViewModel) -> some ToolbarContent {
        @Bindable var prefs = appEnvironment.viewPreferences
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

    // MARK: - Content

    @ViewBuilder
    private func content(viewModel: WatchHistoryListViewModel) -> some View {
        switch appEnvironment.viewPreferences.viewMode {
        case .list, .listDetail:
            listContent(viewModel: viewModel)
        case .gridTitled, .gridNoTitle, .gridDetail:
            gridContent(viewModel: viewModel)
        }
    }

    // MARK: - リスト表示

    @ViewBuilder
    private func listContent(viewModel: WatchHistoryListViewModel) -> some View {
        let showDetail = appEnvironment.viewPreferences.viewMode == .listDetail
        List {
            ForEach(viewModel.histories) { history in
                Button {
                    openHistory(history, viewModel: viewModel)
                } label: {
                    HistoryRowView(
                        history: history,
                        thumbnail: viewModel.thumbnail(for: history),
                        showDetail: showDetail
                    )
                }
                .foregroundStyle(.primary)
                .task(id: history.id) {
                    await viewModel.loadThumbnail(for: history)
                }
            }
            .onDelete { indexSet in
                for index in indexSet {
                    Task { await viewModel.delete(viewModel.histories[index]) }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .overlay { emptyOverlay(isEmpty: viewModel.histories.isEmpty && !viewModel.isLoading) }
        .refreshable { await viewModel.load(sourceID: sourceID) }
    }

    // MARK: - グリッド / コラム表示

    @ViewBuilder
    private func gridContent(viewModel: WatchHistoryListViewModel) -> some View {
        let gridItems = [GridItem(.adaptive(minimum: appEnvironment.viewPreferences.gridCellWidth), spacing: 8)]
        ScrollView {
            LazyVGrid(columns: gridItems, spacing: 8) {
                ForEach(viewModel.histories) { history in
                    Button { openHistory(history, viewModel: viewModel) } label: {
                        historyGridCell(
                            history: history,
                            thumbnail: viewModel.thumbnail(for: history),
                            viewMode: appEnvironment.viewPreferences.viewMode
                        )
                    }
                    .foregroundStyle(.primary)
                    .task(id: history.id) {
                        await viewModel.loadThumbnail(for: history)
                    }
                }
            }
            .padding(8)
        }
        .overlay { emptyOverlay(isEmpty: viewModel.histories.isEmpty && !viewModel.isLoading) }
        .refreshable { await viewModel.load(sourceID: sourceID) }
    }

    @ViewBuilder
    private func historyGridCell(history: WatchHistory, thumbnail: UIImage?, viewMode: ViewMode) -> some View {
        switch viewMode {
        case .list, .listDetail:
            EmptyView()
        case .gridTitled:
            VStack(spacing: 4) {
                MediaThumbnailView(thumbnail: thumbnail)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipped()
                    .cornerRadius(6)
                Text(history.fileName)
                    .font(.caption)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, minHeight: Constants.Grid.cellTitleHeight, maxHeight: Constants.Grid.cellTitleHeight, alignment: .top)
            }
        case .gridNoTitle:
            MediaThumbnailView(thumbnail: thumbnail)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipped()
                .cornerRadius(6)
        case .gridDetail:
            VStack(spacing: 4) {
                MediaThumbnailView(thumbnail: thumbnail)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipped()
                    .cornerRadius(6)
                VStack(alignment: .leading, spacing: 1) {
                    Text(history.fileName)
                        .font(.caption)
                        .lineLimit(2)
                        .foregroundStyle(.primary)
                    if let duration = history.durationSeconds, duration > 0 {
                        Text(formatPosition(history.lastPositionSeconds, of: duration))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Text(history.watchedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: Constants.Grid.cellDetailInfoHeight, maxHeight: Constants.Grid.cellDetailInfoHeight, alignment: .topLeading)
            }
        }
    }

    @ViewBuilder
    private func emptyOverlay(isEmpty: Bool) -> some View {
        if isEmpty {
            ContentUnavailableView(
                emptyTitle,
                systemImage: "clock",
                description: Text(emptyDescription)
            )
        }
    }

    private var emptyTitle: String {
        guard let source = sourceID.flatMap(ContentSource.from(id:)) else {
            return "視聴履歴なし"
        }
        switch source {
        case .photoLibrary:
            return "フォトライブラリの履歴なし"
        case .localFolder:
            return "ローカルフォルダの履歴なし"
        case .remote:
            return "この接続先の履歴なし"
        }
    }

    private var emptyDescription: String {
        guard let source = sourceID.flatMap(ContentSource.from(id:)) else {
            return "動画を再生するとここに履歴が表示されます。"
        }
        switch source {
        case .photoLibrary:
            return "フォトライブラリの動画を再生するとここに履歴が表示されます。"
        case .localFolder:
            return "このローカルフォルダの動画を再生するとここに履歴が表示されます。"
        case .remote:
            return "この接続先の動画を再生するとここに履歴が表示されます。"
        }
    }

    private var navigationTitle: String {
        guard let source = sourceID.flatMap(ContentSource.from(id:)) else {
            return "履歴"
        }
        switch source {
        case .photoLibrary:
            return "フォトの履歴"
        case .localFolder:
            return "ローカルの履歴"
        case .remote:
            if let name = viewModel?.histories.first?.connection?.displayName, !name.isEmpty {
                return name
            }
            return "接続先の履歴"
        }
    }

    private func openHistory(_ history: WatchHistory, viewModel: WatchHistoryListViewModel) {
        Task {
            let resolvedHistory = await viewModel.resolvePlayableHistory(
                history,
                smbClientManager: appEnvironment.smbClientManager
            )
            selectedRoute = MediaViewerPageSource.history(resolvedHistory)?.route(for: resolvedHistory)
        }
    }
}

// MARK: - HistoryRowView

private struct HistoryRowView: View {
    let history: WatchHistory
    let thumbnail: UIImage?
    var showDetail: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            MediaThumbnailView(thumbnail: thumbnail, width: 80, height: 45)
                .cornerRadius(6)

            VStack(alignment: .leading, spacing: 4) {
                Text(history.fileName)
                    .lineLimit(1)
                HStack {
                    Text(sourceLabel(for: history))
                    Spacer()
                    if let duration = history.durationSeconds, duration > 0 {
                        Text(formatPosition(history.lastPositionSeconds, of: duration))
                            .monospacedDigit()
                    }
                    Text(history.watchedAt, style: .relative)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if showDetail {
                    Text(history.watchedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Helpers

private func formatPosition(_ position: Double, of duration: Double) -> String {
    let pos = Int(position)
    let dur = Int(duration)
    let posStr = pos >= 3600
        ? String(format: "%d:%02d:%02d", pos / 3600, (pos % 3600) / 60, pos % 60)
        : String(format: "%d:%02d", pos / 60, pos % 60)
    let durStr = dur >= 3600
        ? String(format: "%d:%02d:%02d", dur / 3600, (dur % 3600) / 60, dur % 60)
        : String(format: "%d:%02d", dur / 60, dur % 60)
    return "\(posStr) / \(durStr)"
}

private func sourceLabel(for history: WatchHistory) -> String {
    if let source = ContentSource.from(id: history.sourceID) {
        switch source {
        case .photoLibrary:
            return "フォトライブラリ"
        case .localFolder:
            return "ローカルフォルダ"
        case .remote:
            return history.connection?.displayName ?? "ネットワーク"
        }
    }
    return history.connection?.displayName ?? "視聴履歴"
}
