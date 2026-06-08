import SwiftUI
import PDFKit

struct LocalPDFViewerView: View {
    @Environment(\.dismiss) private var dismiss

    let item: DirectoryItem
    let source: ContentSource
    let readingDirection: ReadingDirection

    var body: some View {
        PDFViewerScreen(
            title: item.name,
            documentURL: URL(fileURLWithPath: item.path),
            readingDirection: readingDirection,
            errorMessage: nil,
            isLoading: false,
            onClose: { dismiss() }
        )
    }
}

struct RemotePDFViewerView: View {
    @Environment(\.appEnvironment) private var appEnvironment
    @Environment(\.dismiss) private var dismiss

    let connection: RemoteConnection
    let item: DirectoryItem
    let source: ContentSource
    let readingDirection: ReadingDirection

    @State private var documentURL: URL?
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        PDFViewerScreen(
            title: item.name,
            documentURL: documentURL,
            readingDirection: readingDirection,
            errorMessage: errorMessage,
            isLoading: isLoading,
            onClose: { dismiss() }
        )
        .task(id: item.path) {
            await prepareDocument()
        }
        .onDisappear {
            if let documentURL {
                try? FileManager.default.removeItem(at: documentURL)
            }
        }
    }

    private func prepareDocument() async {
        isLoading = true
        errorMessage = nil

        do {
            let repo = try SMBFileRepository(
                connection: connection,
                clientManager: appEnvironment.smbClientManager
            )
            let localURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("pdf")
            try await repo.download(from: item.path, to: localURL, progress: nil)
            documentURL = localURL
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }
}

private struct PDFViewerScreen: View {
    let title: String
    let documentURL: URL?
    let readingDirection: ReadingDirection
    let errorMessage: String?
    let isLoading: Bool
    let onClose: () -> Void

    @StateObject private var pdfBridge = PDFViewBridge()
    @State private var currentPageIndex = 0
    @State private var pageCount = 0
    @State private var targetPageIndex: Int?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            Group {
                if let documentURL {
                    PDFDocumentView(
                        pdfBridge: pdfBridge,
                        documentURL: documentURL,
                        readingDirection: readingDirection,
                        currentPageIndex: $currentPageIndex,
                        pageCount: $pageCount,
                        targetPageIndex: $targetPageIndex
                    )
                    .background(Color.white)
                } else if isLoading {
                    ProgressView()
                        .tint(.white)
                } else {
                    Color.clear
                }
            }

            VStack(spacing: 0) {
                MediaViewerTopBar(
                    title: title,
                    onClose: onClose,
                    onAddToList: nil
                )

                Spacer()

                if pageCount > 0 {
                    PDFViewerBottomPanel {
                        VStack(spacing: 16) {
                            if pageCount > 1 {
                                PDFThumbnailStripView(pdfBridge: pdfBridge)
                                    .frame(height: 56)
                            }

                            HStack {
                                Text("PDF")
                                Spacer()
                                Text("\(currentPageIndex + 1) / \(pageCount)")
                            }
                            .font(.caption)
                            .foregroundStyle(.white)
                        }
                    }
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.white)
                    .padding()
                    .background(.black.opacity(0.7))
                    .cornerRadius(8)
            }
        }
        .statusBarHidden()
    }
}

private struct PDFViewerBottomPanel<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
            .background(
                LinearGradient(
                    colors: [.clear, .black.opacity(0.65)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
    }
}

private final class PDFViewBridge: ObservableObject {
    @Published var pdfView: PDFView?
}

private struct PDFThumbnailStripView: UIViewRepresentable {
    @ObservedObject var pdfBridge: PDFViewBridge

    func makeUIView(context: Context) -> PDFThumbnailView {
        let thumbnailView = PDFThumbnailView()
        thumbnailView.layoutMode = .horizontal
        thumbnailView.backgroundColor = .clear
        thumbnailView.thumbnailSize = CGSize(width: 28, height: 40)
        thumbnailView.pdfView = pdfBridge.pdfView
        return thumbnailView
    }

    func updateUIView(_ uiView: PDFThumbnailView, context: Context) {
        uiView.pdfView = pdfBridge.pdfView
    }
}

private struct PDFDocumentView: UIViewRepresentable {
    @ObservedObject var pdfBridge: PDFViewBridge
    let documentURL: URL
    let readingDirection: ReadingDirection
    @Binding var currentPageIndex: Int
    @Binding var pageCount: Int
    @Binding var targetPageIndex: Int?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            currentPageIndex: $currentPageIndex,
            pageCount: $pageCount,
            targetPageIndex: $targetPageIndex
        )
    }

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePage
        pdfView.displayDirection = .horizontal
        pdfView.displaysAsBook = false
        context.coordinator.applyReadingDirection(readingDirection, to: pdfView)
        pdfView.usePageViewController(true, withViewOptions: nil)
        pdfView.backgroundColor = .black
        pdfBridge.pdfView = pdfView
        context.coordinator.pdfView = pdfView
        context.coordinator.loadDocumentIfNeeded(from: documentURL)
        return pdfView
    }

    func updateUIView(_ pdfView: PDFView, context: Context) {
        if pdfBridge.pdfView !== pdfView {
            pdfBridge.pdfView = pdfView
        }
        context.coordinator.applyReadingDirection(readingDirection, to: pdfView)
        context.coordinator.loadDocumentIfNeeded(from: documentURL)
        context.coordinator.moveToRequestedPageIfNeeded()
    }

    final class Coordinator: NSObject {
        @Binding private var currentPageIndex: Int
        @Binding private var pageCount: Int
        @Binding private var targetPageIndex: Int?

        weak var pdfView: PDFView?
        private var observedDocumentURL: URL?
        private var notificationToken: NSObjectProtocol?
        private var appliedReadingDirection: ReadingDirection?

        init(
            currentPageIndex: Binding<Int>,
            pageCount: Binding<Int>,
            targetPageIndex: Binding<Int?>
        ) {
            self._currentPageIndex = currentPageIndex
            self._pageCount = pageCount
            self._targetPageIndex = targetPageIndex
        }

        deinit {
            if let notificationToken {
                NotificationCenter.default.removeObserver(notificationToken)
            }
        }

        func loadDocumentIfNeeded(from url: URL) {
            guard observedDocumentURL != url else { return }
            observedDocumentURL = url
            pdfView?.document = PDFDocument(url: url)
            pageCount = pdfView?.document?.pageCount ?? 0
            currentPageIndex = 0
            observePageChanges()
        }

        func applyReadingDirection(_ readingDirection: ReadingDirection, to pdfView: PDFView) {
            guard appliedReadingDirection != readingDirection else { return }
            appliedReadingDirection = readingDirection
            pdfView.displaysRTL = readingDirection == .rightToLeft
        }

        func moveToRequestedPageIfNeeded() {
            guard let targetPageIndex,
                  let pdfView,
                  let document = pdfView.document,
                  document.pageCount > 0 else { return }
            let safeIndex = min(max(targetPageIndex, 0), document.pageCount - 1)
            if let page = document.page(at: safeIndex) {
                pdfView.go(to: page)
            }
            self.targetPageIndex = nil
        }

        private func observePageChanges() {
            if let notificationToken {
                NotificationCenter.default.removeObserver(notificationToken)
            }
            notificationToken = NotificationCenter.default.addObserver(
                forName: Notification.Name.PDFViewPageChanged,
                object: pdfView,
                queue: .main
            ) { [weak self] _ in
                guard let self,
                      let pdfView = self.pdfView,
                      let document = pdfView.document,
                      let page = pdfView.currentPage else { return }
                self.pageCount = document.pageCount
                self.currentPageIndex = document.index(for: page)
            }
        }
    }
}
