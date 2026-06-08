import AVKit
import Photos
import SwiftUI

struct PhotoLibraryBrowserView: View {

    @Environment(\.appEnvironment) private var appEnvironment
    var isActive: Bool = true
    @State private var viewModel = PhotoLibraryBrowserViewModel()
    @State private var selectedRoute: MediaViewerRoute?
    @State private var showAddToListSheet = false

    var body: some View {
        Group {
            switch viewModel.authorizationState {
            case .notDetermined:
                permissionPrompt
            case .authorized, .limited:
                assetGrid
            case .denied, .restricted:
                deniedView
            @unknown default:
                deniedView
            }
        }
        .navigationTitle("フォトライブラリ")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isActive {
                toolbarItems
            }
        }
        .task {
            guard isActive else { return }
            await viewModel.prepare()
        }
        .onChange(of: isActive) { _, newValue in
            guard newValue else { return }
            Task {
                await viewModel.prepare()
            }
        }
        .refreshable {
            await viewModel.loadAssets()
        }
        .fullScreenCover(item: $selectedRoute) { route in
            MediaViewerContainerView(route: route)
        }
        .sheet(isPresented: $showAddToListSheet) {
            AddToListSheet(
                items: viewModel.selectedItems,
                source: .photoLibrary,
                connection: nil
            )
        }
    }

    private var permissionPrompt: some View {
        ContentUnavailableView(
            "フォトライブラリへのアクセスが必要です",
            systemImage: "photo.on.rectangle.angled",
            description: Text("写真と動画を表示するためにアクセスを許可してください。")
        )
        .overlay(alignment: .bottom) {
            Button("アクセスを許可") {
                Task {
                    await viewModel.requestAuthorization()
                }
            }
            .buttonStyle(.borderedProminent)
            .padding(.bottom, 32)
        }
    }

    private var deniedView: some View {
        ContentUnavailableView(
            "フォトライブラリを開けません",
            systemImage: "photo.badge.exclamationmark",
            description: Text("設定アプリで写真へのアクセスを許可してください。")
        )
    }

    private var assetGrid: some View {
        Group {
            switch appEnvironment.viewPreferences.viewMode {
            case .list, .listDetail:
                listContent(showDetail: appEnvironment.viewPreferences.viewMode == .listDetail)
            case .gridTitled, .gridNoTitle, .gridDetail:
                gridContent()
            }
        }
        .overlay {
            if viewModel.isLoading {
                ProgressView()
            } else if let errorMessage = viewModel.errorMessage {
                ContentUnavailableView(
                    "読み込みに失敗",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else if viewModel.assets.isEmpty {
                ContentUnavailableView("写真と動画がありません", systemImage: "photo.on.rectangle")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if viewModel.isSelectMode {
                addToListBar
            }
        }
    }

    private var addToListBar: some View {
        HStack {
            Text("\(viewModel.selectedAssetIDs.count)件を選択")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            Button("リストに追加") {
                showAddToListSheet = true
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.selectedItems.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .background(.ultraThinMaterial)
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        @Bindable var prefs = appEnvironment.viewPreferences

        if viewModel.isSelectMode {
            ToolbarItem(placement: .navigationBarLeading) {
                Text("\(viewModel.selectedAssetIDs.count)件を選択")
                    .foregroundStyle(.secondary)
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("完了") {
                    viewModel.toggleSelectMode()
                }
            }
        } else {
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
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Picker("並び順", selection: $viewModel.sortOrder) {
                        ForEach(PhotoLibrarySortOrder.allCases, id: \.self) { order in
                            Text(order.displayName).tag(order)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    viewModel.toggleSelectMode()
                } label: {
                    Image(systemName: "checkmark.circle")
                }
            }
        }
    }

    private func listContent(showDetail: Bool) -> some View {
        List(viewModel.assets) { asset in
            if viewModel.isSelectMode {
                selectableAssetRow(asset: asset) {
                    listRowContent(asset: asset, showDetail: showDetail)
                }
            } else {
                Button {
                    open(asset)
                } label: {
                    listRowContent(asset: asset, showDetail: showDetail)
                }
                .buttonStyle(.plain)
            }
        }
        .scrollContentBackground(.hidden)
    }

    private func gridContent() -> some View {
        let gridItems = [GridItem(.adaptive(minimum: appEnvironment.viewPreferences.gridCellWidth), spacing: 8)]
        return ScrollView {
            LazyVGrid(columns: gridItems, spacing: 8) {
                ForEach(viewModel.assets) { asset in
                    if viewModel.isSelectMode {
                        selectableAssetRow(asset: asset) {
                            photoGridCell(asset: asset)
                        }
                    } else {
                        Button {
                            open(asset)
                        } label: {
                            photoGridCell(asset: asset)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(8)
        }
    }

    private func listRowContent(asset: PhotoAssetItem, showDetail: Bool) -> some View {
        HStack(spacing: 12) {
            PhotoLibraryAssetThumbnailView(asset: asset, width: 88, height: 50)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 4) {
                Text(asset.title)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if showDetail {
                    Text(asset.metadataText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func photoGridCell(asset: PhotoAssetItem) -> some View {
        switch appEnvironment.viewPreferences.viewMode {
        case .list, .listDetail:
            EmptyView()
        case .gridTitled:
            VStack(spacing: 4) {
                PhotoLibraryAssetThumbnailView(asset: asset)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .cornerRadius(6)
                Text(asset.title)
                    .font(.caption)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, minHeight: Constants.Grid.cellTitleHeight, maxHeight: Constants.Grid.cellTitleHeight, alignment: .top)
            }
        case .gridNoTitle:
            PhotoLibraryAssetThumbnailView(asset: asset, showsMetadataBadge: false)
                .aspectRatio(16 / 9, contentMode: .fit)
                .cornerRadius(6)
        case .gridDetail:
            VStack(spacing: 4) {
                PhotoLibraryAssetThumbnailView(asset: asset)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .cornerRadius(6)
                VStack(alignment: .leading, spacing: 1) {
                    Text(asset.title)
                        .font(.caption)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .foregroundStyle(.primary)
                    Text(asset.detailText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, minHeight: Constants.Grid.cellDetailInfoHeight, maxHeight: Constants.Grid.cellDetailInfoHeight, alignment: .topLeading)
            }
        }
    }

    private func selectableAssetRow<Content: View>(
        asset: PhotoAssetItem,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Button {
            viewModel.toggleSelection(for: asset)
        } label: {
            HStack {
                Image(systemName: viewModel.selectedAssetIDs.contains(asset.id)
                    ? "checkmark.circle.fill"
                    : "circle")
                .foregroundStyle(viewModel.selectedAssetIDs.contains(asset.id)
                    ? Color.accentColor
                    : Color.secondary)
                content()
            }
        }
        .buttonStyle(.plain)
    }

    private func open(_ asset: PhotoAssetItem) {
        selectedRoute = MediaViewerPageSource
            .photoLibrary(items: viewModel.mediaItems)
            .route(for: asset.directoryItem)
    }
}

@MainActor
@Observable
final class PhotoLibraryBrowserViewModel {

    var assets: [PhotoAssetItem] = []
    var isLoading = false
    var errorMessage: String?
    var authorizationState: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    var isSelectMode = false
    var selectedAssetIDs: Set<String> = []
    var sortOrder: PhotoLibrarySortOrder = .newest {
        didSet {
            UserDefaults.standard.set(sortOrder.rawValue, forKey: Self.sortOrderDefaultsKey)
            applySort()
        }
    }

    private static let sortOrderDefaultsKey = "PhotoLibrary.sortOrder"

    init() {
        if let raw = UserDefaults.standard.string(forKey: Self.sortOrderDefaultsKey),
           let saved = PhotoLibrarySortOrder(rawValue: raw) {
            sortOrder = saved
        }
    }

    func prepare() async {
        authorizationState = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard authorizationState == .authorized || authorizationState == .limited else { return }
        await loadAssets()
    }

    func requestAuthorization() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        authorizationState = status
        guard status == .authorized || status == .limited else { return }
        await loadAssets()
    }

    func loadAssets() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(
            format: "mediaType == %d OR mediaType == %d",
            PHAssetMediaType.image.rawValue,
            PHAssetMediaType.video.rawValue
        )

        let result = PHAsset.fetchAssets(with: options)
        var loaded: [PhotoAssetItem] = []
        result.enumerateObjects { asset, _, _ in
            let mediaType: PhotoAssetItem.MediaType = asset.mediaType == .video ? .video : .image
            loaded.append(
                PhotoAssetItem(
                    id: asset.localIdentifier,
                    mediaType: mediaType,
                    createdAt: asset.creationDate,
                    duration: asset.duration
                )
            )
        }
        assets = loaded
        applySort()
    }

    func toggleSelectMode() {
        isSelectMode.toggle()
        if !isSelectMode {
            selectedAssetIDs.removeAll()
        }
    }

    func toggleSelection(for asset: PhotoAssetItem) {
        if selectedAssetIDs.contains(asset.id) {
            selectedAssetIDs.remove(asset.id)
        } else {
            selectedAssetIDs.insert(asset.id)
        }
    }

    var selectedItems: [DirectoryItem] {
        assets
            .filter { selectedAssetIDs.contains($0.id) }
            .map(\.directoryItem)
    }

    var videoItems: [DirectoryItem] {
        assets
            .filter { $0.mediaType == .video }
            .map(\.directoryItem)
    }

    var mediaItems: [DirectoryItem] {
        assets.map(\.directoryItem)
    }

    private func applySort() {
        switch sortOrder {
        case .newest:
            assets.sort { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
        case .oldest:
            assets.sort { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
        }
    }
}

enum PhotoLibrarySortOrder: String, CaseIterable {
    case newest
    case oldest

    var displayName: String {
        switch self {
        case .newest:
            return "新しい順"
        case .oldest:
            return "古い順"
        }
    }
}

struct PhotoAssetItem: Identifiable {
    enum MediaType {
        case image
        case video
    }

    let id: String
    let mediaType: MediaType
    let createdAt: Date?
    let duration: TimeInterval?

    var title: String {
        if let createdAt {
            return createdAt.formatted(date: .abbreviated, time: .shortened)
        }
        return mediaType == .video ? "動画" : "画像"
    }

    var detailText: String {
        switch mediaType {
        case .image:
            return "写真"
        case .video:
            return "動画"
        }
    }

    var metadataText: String {
        if let durationText {
            return "\(detailText)・\(durationText)"
        }
        return detailText
    }

    var durationText: String? {
        guard let duration, mediaType == .video else { return nil }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = duration >= 3600 ? [.hour, .minute, .second] : [.minute, .second]
        formatter.zeroFormattingBehavior = [.pad]
        return formatter.string(from: duration)
    }

    var directoryItem: DirectoryItem {
        SourceDirectoryItemAdapter.photoAsset(
            id: id,
            title: title,
            mediaType: mediaType == .video ? .video : .image,
            createdAt: createdAt
        )
    }

    var assetPath: String {
        "phasset://\(id)"
    }

    static func assetID(from path: String) -> String? {
        guard path.hasPrefix("phasset://") else { return nil }
        return String(path.dropFirst("phasset://".count))
    }
}

private struct PhotoLibraryAssetThumbnailView: View {
    let asset: PhotoAssetItem
    var width: CGFloat? = nil
    var height: CGFloat? = nil
    var showsMetadataBadge = true

    @State private var thumbnail: UIImage?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            MediaThumbnailView(
                thumbnail: thumbnail,
                placeholderSystemImage: asset.mediaType == .video ? "film" : "photo",
                width: width,
                height: height
            )
            .background(Color(.systemGray5))

            if showsMetadataBadge && (asset.mediaType == .video || asset.createdAt != nil) {
                HStack(spacing: 6) {
                    if asset.mediaType == .video {
                        Image(systemName: "video.fill")
                    } else {
                        Image(systemName: "photo.fill")
                    }
                    if let createdAt = asset.createdAt {
                        Text(createdAt.formatted(date: .numeric, time: .omitted))
                            .lineLimit(1)
                    }
                }
                .font(.caption2)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .foregroundStyle(.white)
                .background(.black.opacity(0.55))
                .clipShape(Capsule())
                .padding(8)
            }
        }
        .task(id: asset.id) {
            await loadThumbnail()
        }
    }

    private func loadThumbnail() async {
        guard thumbnail == nil else { return }
        guard let phAsset = fetchAsset(with: asset.id) else { return }

        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true

        let image = await requestPhotoImage(
            for: phAsset,
            targetSize: CGSize(width: 400, height: 400),
            contentMode: .aspectFill,
            options: options
        )
        thumbnail = image
    }
}

struct PhotoLibraryImageViewerView: View {
    @Environment(\.dismiss) private var dismiss

    let assetID: String

    @State private var image: UIImage?
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.white)
            } else {
                ProgressView()
                    .tint(.white)
            }

            VStack {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(.black.opacity(0.4))
                            .clipShape(Circle())
                    }
                    .padding()
                    Spacer()
                }
                Spacer()
            }
        }
        .statusBarHidden()
        .task {
            await loadImage()
        }
    }

    private func loadImage() async {
        guard let asset = fetchAsset(with: assetID) else {
            errorMessage = "画像が見つかりません"
            return
        }

        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .none
        options.isNetworkAccessAllowed = true

        let loadedImage = await requestPhotoImage(
            for: asset,
            targetSize: PHImageManagerMaximumSize,
            contentMode: .aspectFit,
            options: options
        )

        if let loadedImage {
            image = loadedImage
        } else {
            errorMessage = "画像を読み込めませんでした"
        }
    }
}

struct PhotoLibraryMediaViewerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appEnvironment) private var appEnvironment

    let items: [DirectoryItem]
    let readingDirection: ReadingDirection

    @State private var currentIndex: Int
    @State private var uiImage: UIImage?
    @State private var player: AVPlayer?
    @State private var errorMessage: String?
    @State private var itemName = "動画"
    @State private var isPlaying = false
    @State private var isMuted = false
    @State private var currentPositionSeconds: Double = 0
    @State private var durationSeconds: Double = 0
    @State private var showAddToListSheet = false
    @State private var prefetchedImages: [String: UIImage] = [:]
    @State private var imageLoadRequestID = UUID()

    @State private var timeObserverToken: Any?

    init(
        items: [DirectoryItem],
        initialItem: DirectoryItem,
        readingDirection: ReadingDirection = .rightToLeft
    ) {
        self.items = items
        self.readingDirection = readingDirection
        self._currentIndex = State(initialValue: items.firstIndex(where: { $0.path == initialItem.path }) ?? 0)
    }

    private var currentItem: DirectoryItem? {
        items.indices.contains(currentIndex) ? items[currentIndex] : nil
    }

    private func item(at index: Int) -> DirectoryItem? {
        items.indices.contains(index) ? items[index] : nil
    }

    private var currentAssetID: String? {
        guard let currentItem else { return nil }
        return PhotoAssetItem.assetID(from: currentItem.path)
    }

    private var canNavigateBackward: Bool {
        currentIndex > items.startIndex
    }

    private var canNavigateForward: Bool {
        currentIndex < items.index(before: items.endIndex)
    }

    var body: some View {
        Group {
            if currentItem?.isVideo == true {
                MediaVideoScreen(
                    title: itemName,
                    pageText: items.count > 1 ? "\(currentIndex + 1) / \(items.count)" : nil,
                    isPlaying: isPlaying,
                    isMuted: isMuted,
                    progress: videoProgress,
                    currentPositionSeconds: currentPositionSeconds,
                    durationSeconds: durationSeconds,
                    canNavigateBackward: canNavigateBackward,
                    canNavigateForward: canNavigateForward,
                    errorMessage: errorMessage,
                    onClose: {
                        await saveWatchHistory()
                        player?.pause()
                        dismiss()
                    },
                    onAddToList: {
                        showAddToListSheet = true
                    },
                    onNavigateBackward: canNavigateBackward ? {
                        await switchVideoToItem(at: currentIndex - 1)
                    } : nil,
                    onNavigateForward: canNavigateForward ? {
                        await switchVideoToItem(at: currentIndex + 1)
                    } : nil,
                    onPlayPause: {
                        toggleVideoPlayPause()
                    },
                    onSkipBackwardLong: {
                        if let player {
                            seek(player: player, to: currentPositionSeconds - 60)
                        }
                    },
                    onSkipBackwardShort: {
                        if let player {
                            seek(player: player, to: currentPositionSeconds - 10)
                        }
                    },
                    onSkipForwardShort: {
                        if let player {
                            seek(player: player, to: currentPositionSeconds + 10)
                        }
                    },
                    onSkipForwardLong: {
                        if let player {
                            seek(player: player, to: currentPositionSeconds + 60)
                        }
                    },
                    onSeekChanged: { seconds in
                        if let player {
                            seek(player: player, to: seconds)
                        }
                    },
                    onSeekEnded: {},
                    onToggleMute: {
                        isMuted.toggle()
                        player?.isMuted = isMuted
                    }
                ) {
                    videoContent
                }
            } else {
                imageScreen
            }
        }
        .task {
            await loadCurrentMedia()
        }
        .onDisappear {
            Task {
                await saveWatchHistory()
            }
            clearActiveMedia()
        }
        .sheet(isPresented: $showAddToListSheet) {
            AddToListSheet(
                items: [currentDirectoryItem],
                source: .photoLibrary,
                connection: nil
            )
            .environment(\.appEnvironment, appEnvironment)
        }
    }

    @ViewBuilder
    private var videoContent: some View {
        if let player, currentItem?.isVideo == true {
            PhotoLibraryAVPlayerView(player: player)
                .ignoresSafeArea()
        } else if let errorMessage {
            Text(errorMessage)
                .foregroundStyle(.white)
        } else {
            ProgressView()
                .tint(.white)
        }
    }

    private var imageScreen: some View {
        MediaImageScreen(
            title: itemName,
            readingDirection: readingDirection,
            currentPageIndex: currentIndex,
            totalPageCount: items.count,
            pageText: items.count > 1 ? "\(currentIndex + 1) / \(items.count)" : nil,
            canNavigateBackward: canNavigateBackward,
            canNavigateForward: canNavigateForward,
            hasImage: uiImage != nil,
            errorMessage: errorMessage,
            onClose: { dismiss() },
            onAddToList: {
                showAddToListSheet = true
            },
            onPageSeek: { targetIndex in
                await switchImageToItem(at: targetIndex)
            },
            onNavigateBackward: canNavigateBackward ? {
                await switchImageToItem(at: currentIndex - 1)
            } : nil,
            onNavigateForward: canNavigateForward ? {
                await switchImageToItem(at: currentIndex + 1)
            } : nil
        ) {
            imageContent
        }
    }

    private func loadCurrentMedia() async {
        errorMessage = nil
        guard let assetID = currentAssetID,
              let asset = fetchAsset(with: assetID) else {
            errorMessage = "メディアが見つかりません"
            return
        }

        itemName = currentItem?.name ?? makeAssetTitle(from: asset, fallback: currentItem?.isVideo == true ? "動画" : "画像")
        clearActiveMedia()

        if currentItem?.isImage == true {
            await loadImage(asset: asset)
            return
        }

        await loadVideo(asset: asset)
    }

    private func loadVideo(asset: PHAsset) async {
        itemName = currentItem?.name ?? makeAssetTitle(from: asset, fallback: "動画")

        let options = PHVideoRequestOptions()
        options.deliveryMode = .automatic
        options.isNetworkAccessAllowed = true

        let avAsset = await withCheckedContinuation { continuation in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                continuation.resume(returning: avAsset)
            }
        }

        guard let avAsset else {
            errorMessage = "動画を読み込めませんでした"
            return
        }

        let item = AVPlayerItem(asset: avAsset)
        let player = AVPlayer(playerItem: item)
        durationSeconds = CMTimeGetSeconds(item.asset.duration).isFinite ? CMTimeGetSeconds(item.asset.duration) : 0
        self.player = player
        observe(player: player)
        player.play()
        isPlaying = true
    }

    private func loadImage(asset: PHAsset) async {
        let requestID = UUID()
        imageLoadRequestID = requestID
        if let currentItem,
           let cachedImage = prefetchedImages[currentItem.path] {
            guard imageLoadRequestID == requestID else { return }
            uiImage = cachedImage
            trimPrefetchedImages(keepingPaths: [currentItem.path, item(at: currentIndex + 1)?.path].compactMap { $0 })
            await prefetchNextImage(after: currentIndex)
            return
        }

        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .none
        options.isNetworkAccessAllowed = true

        let loadedImage = await requestPhotoImage(
            for: asset,
            targetSize: PHImageManagerMaximumSize,
            contentMode: .aspectFit,
            options: options
        )

        guard imageLoadRequestID == requestID else { return }
        if let loadedImage {
            uiImage = loadedImage
            if let currentItem {
                prefetchedImages[currentItem.path] = loadedImage
            }
            trimPrefetchedImages(keepingPaths: [currentItem?.path, item(at: currentIndex + 1)?.path].compactMap { $0 })
            await prefetchNextImage(after: currentIndex)
        } else {
            errorMessage = "画像を読み込めませんでした"
        }
    }

    private func clearActiveMedia() {
        if let timeObserverToken, let player {
            player.removeTimeObserver(timeObserverToken)
        }
        timeObserverToken = nil
        player?.pause()
        player = nil
        uiImage = nil
        currentPositionSeconds = 0
        durationSeconds = 0
        isPlaying = false
    }

    private var currentDirectoryItem: DirectoryItem {
        currentItem ?? DirectoryItem(
            name: itemName,
            path: currentAssetID.map { "phasset://\($0)" } ?? "",
            itemType: .other,
            size: nil,
            modifiedAt: nil,
            createdAt: nil,
            fileId: nil
        )
    }

    private func observe(player: AVPlayer) {
        if let timeObserverToken {
            player.removeTimeObserver(timeObserverToken)
            self.timeObserverToken = nil
        }

        timeObserverToken = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { time in
            currentPositionSeconds = max(0, time.seconds)
            if let currentItem = player.currentItem {
                let duration = currentItem.duration.seconds
                if duration.isFinite {
                    durationSeconds = duration
                }
            }
            isPlaying = player.timeControlStatus == .playing
        }
    }

    private func seek(player: AVPlayer, to seconds: Double) {
        let safe = max(0, min(seconds, durationSeconds > 0 ? durationSeconds : seconds))
        player.seek(to: CMTime(seconds: safe, preferredTimescale: 600))
    }

    private func switchVideoToItem(at index: Int) async {
        guard items.indices.contains(index) else { return }
        await saveWatchHistory()
        clearActiveMedia()
        currentIndex = index
        await loadCurrentMedia()
    }

    private func switchImageToItem(at index: Int) async {
        guard items.indices.contains(index) else { return }
        imageLoadRequestID = UUID()
        clearActiveMedia()
        if let item = item(at: index),
           let cachedImage = prefetchedImages[item.path] {
            uiImage = cachedImage
        }
        currentIndex = index
        await loadCurrentMedia()
    }

    private func prefetchNextImage(after index: Int) async {
        guard let nextItem = item(at: index + 1),
              nextItem.isImage,
              prefetchedImages[nextItem.path] == nil,
              let assetID = PhotoAssetItem.assetID(from: nextItem.path),
              let asset = fetchAsset(with: assetID) else { return }

        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .none
        options.isNetworkAccessAllowed = true

        let loadedImage = await requestPhotoImage(
            for: asset,
            targetSize: PHImageManagerMaximumSize,
            contentMode: .aspectFit,
            options: options
        )

        if let loadedImage {
            prefetchedImages[nextItem.path] = loadedImage
            trimPrefetchedImages(
                keepingPaths: [
                    currentItem?.path,
                    nextItem.path
                ].compactMap { $0 }
            )
        }
    }

    private func trimPrefetchedImages(keepingPaths: [String]) {
        let keep = Set(keepingPaths)
        prefetchedImages = prefetchedImages.filter { keep.contains($0.key) }
    }

    private func toggleVideoPlayPause() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    @ViewBuilder
    private var imageContent: some View {
        if let uiImage, currentItem?.isImage == true {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFit()
        } else if errorMessage == nil {
            ProgressView()
                .tint(.white)
        } else {
            Color.clear
        }
    }

    private func makeAssetTitle(from asset: PHAsset, fallback: String) -> String {
        if let createdAt = asset.creationDate {
            return createdAt.formatted(date: .abbreviated, time: .shortened)
        }
        return fallback
    }

    private var videoProgress: Double {
        guard durationSeconds > 0 else { return 0 }
        return min(max(currentPositionSeconds / durationSeconds, 0), 1)
    }

    private func saveWatchHistory() async {
        guard currentItem?.isVideo == true, let currentItem else { return }
        await appEnvironment.playbackHistoryService.saveProgress(
            source: .photoLibrary,
            connection: nil,
            item: currentItem,
            currentPositionSeconds: currentPositionSeconds,
            durationSeconds: durationSeconds,
            thumbnailData: nil
        )
    }
}

private func fetchAsset(with id: String) -> PHAsset? {
    PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
}

private func requestPhotoImage(
    for asset: PHAsset,
    targetSize: CGSize,
    contentMode: PHImageContentMode,
    options: PHImageRequestOptions
) async -> UIImage? {
    await withCheckedContinuation { continuation in
        var resumed = false
        PHImageManager.default().requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: contentMode,
            options: options
        ) { image, info in
            if resumed { return }
            let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            let hasError = info?[PHImageErrorKey] != nil
            let wasCancelled = (info?[PHImageCancelledKey] as? Bool) ?? false

            if hasError || wasCancelled || !isDegraded {
                resumed = true
                continuation.resume(returning: image)
            }
        }
    }
}

private struct PhotoLibraryAVPlayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.backgroundColor = .black
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ uiView: PlayerView, context: Context) {
        uiView.playerLayer.player = player
    }

    final class PlayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }

        var playerLayer: AVPlayerLayer {
            guard let layer = self.layer as? AVPlayerLayer else {
                fatalError("AVPlayerLayer の取得に失敗しました")
            }
            return layer
        }
    }
}
