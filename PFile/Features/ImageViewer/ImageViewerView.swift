import SwiftUI

struct ImageViewerView: View {

    @Environment(\.appEnvironment) private var appEnvironment
    @Environment(\.dismiss) private var dismiss

    let connection: RemoteConnection
    let items: [DirectoryItem]
    let readingDirection: ReadingDirection

    @State private var currentIndex: Int
    @State private var uiImage: UIImage?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showAddToListSheet = false
    @State private var prefetchedImages: [String: UIImage] = [:]
    @State private var loadRequestID = UUID()

    init(
        connection: RemoteConnection,
        items: [DirectoryItem],
        initialItem: DirectoryItem,
        readingDirection: ReadingDirection = .rightToLeft
    ) {
        self.connection = connection
        self.items = items
        self.readingDirection = readingDirection
        self._currentIndex = State(
            initialValue: items.firstIndex(where: { $0.path == initialItem.path }) ?? 0
        )
    }

    private var currentItem: DirectoryItem? {
        items.indices.contains(currentIndex) ? items[currentIndex] : nil
    }

    private func itemAtIndex(_ index: Int) -> DirectoryItem? {
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
            hasImage: uiImage != nil,
            errorMessage: errorMessage,
            onClose: { dismiss() },
            onAddToList: {
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
            if let item = currentItem {
                AddToListSheet(
                    items: [item],
                    source: .remote(connection.id),
                    connection: connection
                )
                .environment(\.appEnvironment, appEnvironment)
            }
        }
    }

    // MARK: - Navigation

    private func switchToItem(at index: Int) async {
        guard items.indices.contains(index) else { return }
        loadRequestID = UUID()
        if let item = itemAtIndex(index),
           let cachedImage = prefetchedImages[item.path] {
            uiImage = cachedImage
        } else {
            uiImage = nil
        }
        errorMessage = nil
        currentIndex = index
    }

    @ViewBuilder
    private var imageContent: some View {
        if let uiImage {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFit()
        } else if isLoading {
            ProgressView()
                .tint(.white)
        } else {
            Color.clear
        }
    }

    // MARK: - Load

    private func loadImage() async {
        guard let item = currentItem else { return }
        let requestID = UUID()
        loadRequestID = requestID
        isLoading = true
        errorMessage = nil

        if let cachedImage = prefetchedImages[item.path] {
            guard loadRequestID == requestID else { return }
            uiImage = cachedImage
            isLoading = false
            trimPrefetchedImages(keepingPaths: [item.path, itemAtIndex(currentIndex + 1)?.path].compactMap { $0 })
            await prefetchNextImage(after: currentIndex)
            return
        }

        uiImage = nil

        do {
            guard let image = try await loadUIImage(for: item) else {
                guard loadRequestID == requestID else { return }
                errorMessage = "画像を読み込めませんでした"
                isLoading = false
                return
            }
            guard loadRequestID == requestID else { return }
            uiImage = image
            prefetchedImages[item.path] = image
            isLoading = false
            trimPrefetchedImages(keepingPaths: [item.path, itemAtIndex(currentIndex + 1)?.path].compactMap { $0 })
            await prefetchNextImage(after: currentIndex)

        } catch {
            guard loadRequestID == requestID else { return }
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    private func prefetchNextImage(after index: Int) async {
        guard let nextItem = itemAtIndex(index + 1),
              prefetchedImages[nextItem.path] == nil else { return }

        do {
            if let image = try await loadUIImage(for: nextItem) {
                prefetchedImages[nextItem.path] = image
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

    private func loadUIImage(for item: DirectoryItem) async throws -> UIImage? {
        let repo = try SMBFileRepository(
            connection: connection,
            clientManager: appEnvironment.smbClientManager
        )
        let localURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension((item.name as NSString).pathExtension)

        defer {
            try? FileManager.default.removeItem(at: localURL)
        }

        try await repo.download(from: item.path, to: localURL, progress: nil)
        guard let data = try? Data(contentsOf: localURL) else { return nil }
        return UIImage(data: data)
    }

    private func trimPrefetchedImages(keepingPaths: [String]) {
        let keep = Set(keepingPaths)
        prefetchedImages = prefetchedImages.filter { keep.contains($0.key) }
    }
}
