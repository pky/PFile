import SwiftUI
import MobileVLCKit
import AVFoundation

struct VideoPlayerView: View {

    @Environment(\.appEnvironment) private var appEnvironment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    let connection: RemoteConnection
    let items: [DirectoryItem]
    var startPositionSeconds: Double = 0
    var onReturnHome: (() async -> Void)? = nil

    @State private var currentIndex: Int
    @State private var viewModel: VideoPlayerViewModel?
    @State private var showAddToListSheet = false
    @State private var didSuspendForBackground = false
    @State private var backgroundResumePositionSeconds: Double = 0

    init(
        connection: RemoteConnection,
        items: [DirectoryItem],
        initialItem: DirectoryItem,
        startPositionSeconds: Double = 0,
        onReturnHome: (() async -> Void)? = nil
    ) {
        self.connection = connection
        self.items = items
        self.startPositionSeconds = startPositionSeconds
        self.onReturnHome = onReturnHome
        self._currentIndex = State(
            initialValue: items.firstIndex(where: { $0.path == initialItem.path }) ?? 0
        )
    }

    private var currentItem: DirectoryItem? {
        items.indices.contains(currentIndex) ? items[currentIndex] : nil
    }

    var body: some View {
        Group {
            if let viewModel {
                MediaVideoScreen(
                    title: currentItem?.name ?? "",
                    pageText: items.count > 1 ? "\(currentIndex + 1) / \(items.count)" : nil,
                    isPlaying: viewModel.isPlaying,
                    isMuted: viewModel.isMuted,
                    progress: videoProgress(viewModel: viewModel),
                    currentPositionSeconds: viewModel.currentPositionSeconds,
                    durationSeconds: viewModel.durationSeconds,
                    canNavigateBackward: currentIndex > items.startIndex,
                    canNavigateForward: currentIndex < items.index(before: items.endIndex),
                    errorMessage: viewModel.errorMessage,
                    onClose: {
                        viewModel.stopPlayback(trigger: "close_button")
                        await viewModel.saveWatchPosition()
                        dismiss()
                    },
                    onReturnHome: onReturnHome == nil ? nil : {
                        viewModel.stopPlayback(trigger: "home_button")
                        await viewModel.saveWatchPosition()
                        await onReturnHome?()
                    },
                    onAddToList: {
                        showAddToListSheet = true
                    },
                    onNavigateBackward: currentIndex > items.startIndex ? {
                        await switchToItem(at: currentIndex - 1)
                    } : nil,
                    onNavigateForward: currentIndex < items.index(before: items.endIndex) ? {
                        await switchToItem(at: currentIndex + 1)
                    } : nil,
                    onPlayPause: {
                        viewModel.togglePlayPause()
                    },
                    onSkipBackwardLong: {
                        viewModel.skip(seconds: -60)
                    },
                    onSkipBackwardShort: {
                        viewModel.skip(seconds: -10)
                    },
                    onSkipForwardShort: {
                        viewModel.skip(seconds: 10)
                    },
                    onSkipForwardLong: {
                        viewModel.skip(seconds: 60)
                    },
                    onSeekChanged: { seconds in
                        viewModel.updateInteractiveSeek(to: seconds)
                    },
                    onSeekEnded: {
                        viewModel.endInteractiveSeek()
                    },
                    onToggleMute: {
                        viewModel.toggleMute()
                    }
                ) {
                    VLCPlayerView(player: viewModel.player) {
                        viewModel.markDrawableReady()
                    }
                        .id(viewModel.playerID)
                        .ignoresSafeArea()
                }
                .overlay {
                    if viewModel.isBuffering {
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(1.5)
                    }
                }
            } else {
                ZStack {
                    Color.black.ignoresSafeArea()
                    ProgressView()
                        .tint(.white)
                }
                .statusBarHidden()
            }
        }
        .onAppear {
            let vm = makeViewModel(startPositionSeconds: startPositionSeconds)
            viewModel = vm
        }
        .onDisappear {
            if let vm = viewModel {
                vm.cancelSetup()
                Task {
                    await vm.saveWatchPosition()
                    vm.tearDownPlayback(trigger: "view_on_disappear")
                }
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                suspendPlaybackForBackground()
            case .active:
                resumePlaybackAfterBackgroundIfNeeded()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
        .sheet(isPresented: $showAddToListSheet) {
            if let item = currentItem {
                AddToListSheet(
                    items: [item],
                    source: .remote(connection.id),
                    connection: connection,
                    suppressSuccessAlert: true
                )
                    .environment(\.appEnvironment, appEnvironment)
            }
        }
    }

    // MARK: - Navigation

    private func switchToItem(at index: Int) async {
        guard items.indices.contains(index) else { return }
        if let oldVm = viewModel {
            oldVm.cancelSetup()
            await oldVm.saveWatchPosition()
            oldVm.tearDownPlayback(trigger: "navigate_next_previous")
        }
        viewModel = nil
        currentIndex = index

        let startPosition = await fetchLastPosition(for: items[index])
        let vm = makeViewModel(startPositionSeconds: startPosition)
        viewModel = vm
    }

    private func suspendPlaybackForBackground() {
        guard let vm = viewModel else { return }
        backgroundResumePositionSeconds = vm.currentPositionSeconds
        didSuspendForBackground = true
        vm.cancelSetup()
        vm.tearDownPlayback(trigger: "scene_background")
        viewModel = nil

        Task {
            await vm.saveWatchPosition(capturesThumbnail: false)
        }
    }

    private func resumePlaybackAfterBackgroundIfNeeded() {
        guard didSuspendForBackground, viewModel == nil, currentItem != nil else { return }
        didSuspendForBackground = false
        let vm = makeViewModel(startPositionSeconds: backgroundResumePositionSeconds)
        viewModel = vm
    }

    private func fetchLastPosition(for item: DirectoryItem) async -> Double {
        let resumePlayback = UserDefaults.standard.object(forKey: "Settings.resumePlayback") as? Bool ?? true
        guard resumePlayback else { return 0 }
        let sourceID = ContentSource.remote(connection.id).id
        return (try? await appEnvironment.watchHistoryRepository.fetchLastPosition(
            sourceID: sourceID,
            filePath: item.path,
            fileId: item.fileId
        )) ?? 0
    }

    private func makeViewModel(startPositionSeconds: Double = 0) -> VideoPlayerViewModel {
        VideoPlayerViewModel(
            connection: connection,
            item: items[currentIndex],
            playbackHistoryService: appEnvironment.playbackHistoryService,
            smbClientManager: appEnvironment.smbClientManager,
            startPositionSeconds: startPositionSeconds
        )
    }

    private func videoProgress(viewModel: VideoPlayerViewModel) -> Double {
        guard viewModel.durationSeconds > 0 else { return 0 }
        return min(max(viewModel.currentPositionSeconds / viewModel.durationSeconds, 0), 1)
    }
}

// MARK: - VLCPlayerView

private struct VLCPlayerView: UIViewRepresentable {

    let player: VLCMediaPlayer
    let onDrawableReady: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false
        player.drawable = view
        notifyDrawableReady(context: context)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        if (player.drawable as? UIView) !== uiView {
            player.drawable = uiView
        }
        notifyDrawableReady(context: context)
    }

    private func notifyDrawableReady(context: Context) {
        guard !context.coordinator.didNotifyDrawableReady else { return }
        context.coordinator.didNotifyDrawableReady = true
        onDrawableReady()
    }

    final class Coordinator {
        var didNotifyDrawableReady = false
    }
}
