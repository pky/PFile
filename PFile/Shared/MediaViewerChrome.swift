import SwiftUI
import AVKit
import MediaPlayer
import UIKit

enum VideoPlayerHomeButtonSettings {
    static let key = "Settings.showVideoHomeButtonAlways"
    static let defaultValue = false

    static var isAlwaysVisible: Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? defaultValue
    }

    static func save(_ isVisible: Bool) {
        UserDefaults.standard.set(isVisible, forKey: key)
    }
}

enum VideoPlayerShareButtonSettings {
    static let key = "Settings.showVideoShareButton"
    static let defaultValue = true

    static var isVisible: Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? defaultValue
    }

    static func save(_ isVisible: Bool) {
        UserDefaults.standard.set(isVisible, forKey: key)
    }
}

enum VideoPlayerAirPlayButtonSettings {
    static let key = "Settings.showVideoAirPlayButton"
    static let defaultValue = true

    static var isVisible: Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? defaultValue
    }

    static func save(_ isVisible: Bool) {
        UserDefaults.standard.set(isVisible, forKey: key)
    }
}

enum VideoPlayerClockSettings {
    static let key = "Settings.showVideoClock"
    static let defaultValue = false

    static var isVisible: Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? defaultValue
    }

    static func save(_ isVisible: Bool) {
        UserDefaults.standard.set(isVisible, forKey: key)
    }
}

struct MediaViewerVolumeControl: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "speaker.fill")
                .font(.system(size: 18))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
            MediaViewerSystemVolumeSlider()
                .frame(height: 18)
            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 14)
        }
    }
}

struct MediaViewerBrightnessControl: View {
    @State private var brightness = UIScreen.main.brightness

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sun.max.fill")
                .font(.system(size: 18))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
            Slider(
                value: Binding(
                    get: { brightness },
                    set: { newValue in
                        brightness = newValue
                        UIScreen.main.brightness = newValue
                    }
                ),
                in: 0...1
            )
            .tint(.white)
            .frame(height: 18)
            Image(systemName: "sun.max.fill")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 14)
        }
        .onAppear {
            brightness = UIScreen.main.brightness
        }
    }
}

struct MediaViewerTopBar: View {
    let title: String
    let onClose: () -> Void
    let onReturnHome: (() -> Void)?
    let orientationLabel: String?
    let onOrientationToggle: (() -> Void)?
    let onAddToList: (() -> Void)?
    let shareURL: URL?
    let showShareButton: Bool
    let showAirPlayButton: Bool

    init(
        title: String,
        onClose: @escaping () -> Void,
        onReturnHome: (() -> Void)? = nil,
        orientationLabel: String? = nil,
        onOrientationToggle: (() -> Void)? = nil,
        onAddToList: (() -> Void)? = nil,
        shareURL: URL? = nil,
        showShareButton: Bool = false,
        showAirPlayButton: Bool = false
    ) {
        self.title = title
        self.onClose = onClose
        self.onReturnHome = onReturnHome
        self.orientationLabel = orientationLabel
        self.onOrientationToggle = onOrientationToggle
        self.onAddToList = onAddToList
        self.shareURL = shareURL
        self.showShareButton = showShareButton
        self.showAirPlayButton = showAirPlayButton
    }

    var body: some View {
        HStack {
            HStack(spacing: 8) {
                MediaViewerIconButton(systemImage: "xmark", action: onClose)
                if let onReturnHome {
                    MediaViewerIconButton(systemImage: "house.fill", action: onReturnHome)
                }
            }
            .padding(.leading, 16)
            .padding(.top, 8)

            Spacer()

            Text(title)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
                .padding(.top, 8)

            HStack(spacing: 8) {
                if let orientationLabel,
                   let onOrientationToggle {
                    MediaViewerLabeledButton(
                        systemImage: "rotate.right.fill",
                        text: orientationLabel,
                        action: onOrientationToggle
                    )
                }
                if let onAddToList {
                    MediaViewerIconButton(systemImage: "text.badge.plus", action: onAddToList)
                }
                if showShareButton, let shareURL {
                    MediaViewerShareButton(url: shareURL)
                }
                if showAirPlayButton {
                    MediaViewerAirPlayButton()
                        .frame(width: 44, height: 44)
                } else if orientationLabel == nil && onAddToList == nil && shareURL == nil {
                    Color.clear
                        .frame(width: 44, height: 44)
                }
            }
            .padding(.trailing, 16)
            .padding(.top, 8)
        }
        .background(
            LinearGradient(
                colors: [.black.opacity(0.5), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}

struct MediaViewerBottomPanel<Content: View>: View {
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
            .contentShape(Rectangle())
            .gesture(DragGesture())
    }
}

struct MediaViewerShareButton: View {
    let url: URL

    var body: some View {
        ShareLink(item: url) {
            Image(systemName: "square.and.arrow.up")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.4))
                .clipShape(Circle())
        }
    }
}

struct MediaViewerAirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = true
        view.tintColor = .white
        view.activeTintColor = .white
        view.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        view.layer.cornerRadius = 22
        view.clipsToBounds = true
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

struct MediaViewerClockOverlay: View {
    let isControlsVisible: Bool
    @State private var now = Date()

    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack {
            HStack {
                Spacer()
                Text(now.formatted(date: .omitted, time: .shortened))
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(.black.opacity(0.45))
                    .clipShape(Capsule())
            }
            .padding(.top, isControlsVisible ? 58 : 12)
            .padding(.trailing, 16)
            Spacer()
        }
        .allowsHitTesting(false)
        .onReceive(timer) { now = $0 }
    }
}

struct MediaViewerIconButton: View {
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.4))
                .clipShape(Circle())
        }
    }
}

struct MediaViewerLabeledButton: View {
    let systemImage: String
    let text: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                Text(text)
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(.black.opacity(0.4))
            .clipShape(Capsule())
        }
    }
}

struct MediaViewerSystemVolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView()
        view.showsRouteButton = false
        view.tintColor = .white
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

struct MediaViewerImageControls: View {
    let canNavigateBackward: Bool
    let canNavigateForward: Bool
    let isZoomOutEnabled: Bool
    let isZoomToggleEnabled: Bool
    let zoomSystemImage: String
    let zoomText: String
    let pageProgress: Double?
    let pageText: String?
    let onPageSeekChanged: ((Double) -> Void)?
    let onPageSeekEnded: (() -> Void)?
    let onNavigateBackward: () -> Void
    let onResetZoom: () -> Void
    let onToggleZoom: () -> Void
    let onNavigateForward: () -> Void

    var body: some View {
        MediaViewerBottomPanel {
            VStack(spacing: 16) {
                HStack(spacing: 36) {
                    imageControlButton(
                        systemImage: "backward.end.fill",
                        isEnabled: canNavigateBackward,
                        action: onNavigateBackward
                    )
                    imageControlButton(
                        systemImage: "minus.magnifyingglass",
                        isEnabled: isZoomOutEnabled,
                        action: onResetZoom
                    )
                    imageControlButton(
                        systemImage: zoomSystemImage,
                        isEnabled: isZoomToggleEnabled,
                        action: onToggleZoom
                    )
                    imageControlButton(
                        systemImage: "forward.end.fill",
                        isEnabled: canNavigateForward,
                        action: onNavigateForward
                    )
                }

                if let pageProgress,
                   let onPageSeekChanged,
                   let onPageSeekEnded {
                    MediaViewerSeekBar(
                        progress: pageProgress,
                        onChanged: onPageSeekChanged,
                        onEnded: onPageSeekEnded
                    )
                }

                HStack {
                    Text(zoomText)
                        .monospacedDigit()
                    Spacer()
                    if let pageText {
                        Text(pageText)
                    }
                }
                .font(.caption)
                .foregroundStyle(.white)
            }
        }
    }

    @ViewBuilder
    private func imageControlButton(
        systemImage: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: systemImage.contains("magnifyingglass") ? 22 : 24))
                .foregroundStyle(isEnabled ? .white : .white.opacity(0.3))
                .frame(width: 44, height: 44)
        }
        .disabled(!isEnabled)
    }
}

struct MediaViewerVideoControls<VolumeControl: View>: View {
    let isPlaying: Bool
    let isMuted: Bool
    let progress: Double
    let currentTimeText: String
    let durationText: String
    let showsPlaybackTime: Bool
    let pageText: String?
    let onSkipBackwardLong: () -> Void
    let onSkipBackwardShort: () -> Void
    let onPlayPause: () -> Void
    let onSkipForwardShort: () -> Void
    let onSkipForwardLong: () -> Void
    let onSeekChanged: (Double) -> Void
    let onSeekEnded: () -> Void
    let onToggleMute: () -> Void
    let volumeControl: VolumeControl

    init(
        isPlaying: Bool,
        isMuted: Bool,
        progress: Double,
        currentTimeText: String,
        durationText: String,
        showsPlaybackTime: Bool,
        pageText: String?,
        onSkipBackwardLong: @escaping () -> Void,
        onSkipBackwardShort: @escaping () -> Void,
        onPlayPause: @escaping () -> Void,
        onSkipForwardShort: @escaping () -> Void,
        onSkipForwardLong: @escaping () -> Void,
        onSeekChanged: @escaping (Double) -> Void,
        onSeekEnded: @escaping () -> Void,
        onToggleMute: @escaping () -> Void,
        @ViewBuilder volumeControl: () -> VolumeControl
    ) {
        self.isPlaying = isPlaying
        self.isMuted = isMuted
        self.progress = progress
        self.currentTimeText = currentTimeText
        self.durationText = durationText
        self.showsPlaybackTime = showsPlaybackTime
        self.pageText = pageText
        self.onSkipBackwardLong = onSkipBackwardLong
        self.onSkipBackwardShort = onSkipBackwardShort
        self.onPlayPause = onPlayPause
        self.onSkipForwardShort = onSkipForwardShort
        self.onSkipForwardLong = onSkipForwardLong
        self.onSeekChanged = onSeekChanged
        self.onSeekEnded = onSeekEnded
        self.onToggleMute = onToggleMute
        self.volumeControl = volumeControl()
    }

    var body: some View {
        MediaViewerBottomPanel {
            VStack(spacing: 16) {
                HStack(spacing: 36) {
                    videoControlButton(systemImage: "gobackward.60", action: onSkipBackwardLong)
                    videoControlButton(systemImage: "gobackward.10", action: onSkipBackwardShort)
                    Button(action: onPlayPause) {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(.white)
                            .frame(width: 60, height: 60)
                    }
                    videoControlButton(systemImage: "goforward.10", action: onSkipForwardShort)
                    videoControlButton(systemImage: "goforward.60", action: onSkipForwardLong)
                }

                MediaViewerSeekBar(progress: progress, onChanged: onSeekChanged, onEnded: onSeekEnded)

                HStack(spacing: 8) {
                    Button(action: onToggleMute) {
                        Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                    }
                    volumeControl
                }

                MediaViewerBrightnessControl()

                if showsPlaybackTime || pageText != nil {
                    HStack {
                        if showsPlaybackTime {
                            Text(currentTimeText)
                                .monospacedDigit()
                            Text("/")
                            Text(durationText)
                                .monospacedDigit()
                        }
                        Spacer()
                        if let pageText {
                            Text(pageText)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.white)
                }
            }
        }
    }

    @ViewBuilder
    private func videoControlButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 24))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
        }
    }
}

private struct MediaViewerSeekBar: View {
    let progress: Double
    let onChanged: (Double) -> Void
    let onEnded: () -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.3))
                    .frame(height: 4)

                Capsule()
                    .fill(.white)
                    .frame(width: geo.size.width * CGFloat(progress), height: 4)

                Circle()
                    .fill(.white)
                    .frame(width: 14, height: 14)
                    .offset(x: geo.size.width * CGFloat(progress) - 7)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let ratio = min(max(value.location.x / max(geo.size.width, 1), 0), 1)
                        onChanged(ratio)
                    }
                    .onEnded { _ in
                        onEnded()
                    }
            )
        }
        .frame(height: 20)
    }
}

struct MediaVideoScreen<Renderer: View>: View {
    let title: String
    let pageText: String?
    let isPlaying: Bool
    let isMuted: Bool
    let progress: Double
    let currentPositionSeconds: Double
    let durationSeconds: Double
    let canNavigateBackward: Bool
    let canNavigateForward: Bool
    let errorMessage: String?
    let shareURL: URL?
    let onClose: () async -> Void
    let onReturnHome: (() async -> Void)?
    let onAddToList: (() -> Void)?
    let onNavigateBackward: (() async -> Void)?
    let onNavigateForward: (() async -> Void)?
    let onPlayPause: () -> Void
    let onSkipBackwardLong: () -> Void
    let onSkipBackwardShort: () -> Void
    let onSkipForwardShort: () -> Void
    let onSkipForwardLong: () -> Void
    let onSeekChanged: (Double) -> Void
    let onSeekEnded: () -> Void
    let onToggleMute: () -> Void
    let renderer: Renderer

    @State private var showControls = true
    @State private var hideTask: Task<Void, Never>?
    @State private var isDraggingSeek = false
    @State private var scrubPositionSeconds: Double = 0
    @State private var committedSeekPositionSeconds: Double?
    @State private var slideOffsetX: CGFloat = 0
    @State private var orientationMode = OrientationService.shared.mode
    @AppStorage(VideoPlayerHomeButtonSettings.key) private var showHomeButtonAlways = VideoPlayerHomeButtonSettings.defaultValue
    @AppStorage(VideoPlayerShareButtonSettings.key) private var showShareButton = VideoPlayerShareButtonSettings.defaultValue
    @AppStorage(VideoPlayerAirPlayButtonSettings.key) private var showAirPlayButton = VideoPlayerAirPlayButtonSettings.defaultValue
    @AppStorage(VideoPlayerClockSettings.key) private var showClock = VideoPlayerClockSettings.defaultValue

    init(
        title: String,
        pageText: String?,
        isPlaying: Bool,
        isMuted: Bool,
        progress: Double,
        currentPositionSeconds: Double,
        durationSeconds: Double,
        canNavigateBackward: Bool,
        canNavigateForward: Bool,
        errorMessage: String?,
        shareURL: URL? = nil,
        onClose: @escaping () async -> Void,
        onReturnHome: (() async -> Void)? = nil,
        onAddToList: (() -> Void)?,
        onNavigateBackward: (() async -> Void)?,
        onNavigateForward: (() async -> Void)?,
        onPlayPause: @escaping () -> Void,
        onSkipBackwardLong: @escaping () -> Void,
        onSkipBackwardShort: @escaping () -> Void,
        onSkipForwardShort: @escaping () -> Void,
        onSkipForwardLong: @escaping () -> Void,
        onSeekChanged: @escaping (Double) -> Void,
        onSeekEnded: @escaping () -> Void,
        onToggleMute: @escaping () -> Void,
        @ViewBuilder renderer: () -> Renderer
    ) {
        self.title = title
        self.pageText = pageText
        self.isPlaying = isPlaying
        self.isMuted = isMuted
        self.progress = progress
        self.currentPositionSeconds = currentPositionSeconds
        self.durationSeconds = durationSeconds
        self.canNavigateBackward = canNavigateBackward
        self.canNavigateForward = canNavigateForward
        self.errorMessage = errorMessage
        self.shareURL = shareURL
        self.onClose = onClose
        self.onReturnHome = onReturnHome
        self.onAddToList = onAddToList
        self.onNavigateBackward = onNavigateBackward
        self.onNavigateForward = onNavigateForward
        self.onPlayPause = onPlayPause
        self.onSkipBackwardLong = onSkipBackwardLong
        self.onSkipBackwardShort = onSkipBackwardShort
        self.onSkipForwardShort = onSkipForwardShort
        self.onSkipForwardLong = onSkipForwardLong
        self.onSeekChanged = onSeekChanged
        self.onSeekEnded = onSeekEnded
        self.onToggleMute = onToggleMute
        self.renderer = renderer()
    }

    var body: some View {
        GeometryReader { proxy in
            let displayPositionSeconds = committedSeekPositionSeconds ?? (isDraggingSeek ? scrubPositionSeconds : currentPositionSeconds)
            let seekBarProgress = durationSeconds > 0
                ? min(max(displayPositionSeconds / durationSeconds, 0), 1)
                : progress
            let effectiveShareURL = showShareButton ? shareURL : nil

            ZStack {
                Color.black.ignoresSafeArea()

                renderer
                    .offset(x: slideOffsetX)

                if showClock {
                    MediaViewerClockOverlay(isControlsVisible: showControls)
                }

                if !showControls {
                    VStack {
                        HStack {
                            MediaViewerIconButton(systemImage: "xmark") {
                                closePlayer()
                            }
                            if showHomeButtonAlways, onReturnHome != nil {
                                MediaViewerIconButton(systemImage: "house.fill") {
                                    returnHome()
                                }
                            }

                            Spacer()
                        }
                        .padding(.leading, 16)
                        .padding(.top, 8)
                        Spacer()
                    }
                }

                VStack(spacing: 0) {
                    MediaViewerTopBar(
                        title: title,
                        onClose: closePlayer,
                        onReturnHome: onReturnHome == nil ? nil : returnHome,
                        orientationLabel: orientationLabel,
                        onOrientationToggle: {
                            cycleOrientationMode()
                            resetHideTimer()
                        },
                        onAddToList: onAddToList,
                        shareURL: effectiveShareURL,
                        showShareButton: effectiveShareURL != nil,
                        showAirPlayButton: showAirPlayButton
                    )

                    Spacer()

                    MediaViewerVideoControls(
                        isPlaying: isPlaying,
                        isMuted: isMuted,
                        progress: seekBarProgress,
                        currentTimeText: formatTime(displayPositionSeconds),
                        durationText: formatTime(durationSeconds),
                        showsPlaybackTime: !showClock,
                        pageText: pageText,
                        onSkipBackwardLong: {
                            onSkipBackwardLong()
                            resetHideTimer()
                        },
                        onSkipBackwardShort: {
                            onSkipBackwardShort()
                            resetHideTimer()
                        },
                        onPlayPause: {
                            onPlayPause()
                            resetHideTimer()
                        },
                        onSkipForwardShort: {
                            onSkipForwardShort()
                            resetHideTimer()
                        },
                        onSkipForwardLong: {
                            onSkipForwardLong()
                            resetHideTimer()
                        },
                        onSeekChanged: { ratio in
                            let safeDuration = max(durationSeconds, 1)
                            let seconds = safeDuration * ratio
                            isDraggingSeek = true
                            scrubPositionSeconds = seconds
                            committedSeekPositionSeconds = seconds
                            hideTask?.cancel()
                            onSeekChanged(seconds)
                        },
                        onSeekEnded: {
                            onSeekEnded()
                            isDraggingSeek = false
                            resetHideTimer()
                        },
                        onToggleMute: {
                            onToggleMute()
                            resetHideTimer()
                        }
                    ) {
                        MediaViewerVolumeControl()
                    }
                }
                .opacity(showControls ? 1 : 0)
                .allowsHitTesting(showControls)
                .animation(.easeInOut(duration: 0.25), value: showControls)

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.white)
                        .padding()
                        .background(.black.opacity(0.7))
                        .cornerRadius(8)
                }
            }
            .statusBarHidden()
            .contentShape(Rectangle())
            .onChange(of: currentPositionSeconds) { _, newValue in
                guard let committed = committedSeekPositionSeconds else { return }
                if abs(newValue - committed) < 0.5 {
                    committedSeekPositionSeconds = nil
                }
            }
            .onTapGesture {
                toggleControls()
            }
            .gesture(
                DragGesture(minimumDistance: 40)
                    .onEnded { value in
                        let controlAreaMinY = proxy.size.height - 220
                        guard value.startLocation.y < controlAreaMinY else { return }
                        let horizontal = abs(value.translation.width)
                        let vertical = abs(value.translation.height)
                        guard horizontal > vertical * 1.5 else { return }
                        if value.translation.width < -40, canNavigateForward {
                            navigate(isForward: true)
                        } else if value.translation.width > 40, canNavigateBackward {
                            navigate(isForward: false)
                        }
                    }
            )
            .onAppear {
                orientationMode = OrientationService.shared.mode
                if isPlaying {
                    resetHideTimer()
                }
            }
            .onChange(of: isPlaying) { _, newValue in
                if newValue, showControls {
                    resetHideTimer()
                } else if !newValue {
                    hideTask?.cancel()
                }
            }
            .onDisappear {
                hideTask?.cancel()
            }
        }
    }

    private func closePlayer() {
        hideTask?.cancel()
        Task {
            await onClose()
        }
    }

    private func returnHome() {
        guard let onReturnHome else { return }
        hideTask?.cancel()
        Task {
            await onReturnHome()
        }
    }

    private func toggleControls() {
        if showControls {
            hideTask?.cancel()
            withAnimation { showControls = false }
        } else {
            withAnimation { showControls = true }
            resetHideTimer()
        }
    }

    private func resetHideTimer() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, isPlaying else { return }
            withAnimation { showControls = false }
        }
    }

    private func navigate(isForward: Bool) {
        let action = isForward ? onNavigateForward : onNavigateBackward
        guard let action else { return }

        let screenWidth = UIScreen.main.bounds.width
        let exitEdge: CGFloat = isForward ? -screenWidth : screenWidth

        hideTask?.cancel()
        Task { @MainActor in
            withAnimation(.easeInOut(duration: 0.2)) {
                slideOffsetX = exitEdge
            }
            try? await Task.sleep(for: .milliseconds(200))

            await action()
            slideOffsetX = -exitEdge

            withAnimation(.easeInOut(duration: 0.2)) {
                slideOffsetX = 0
            }
            resetHideTimer()
        }
    }

    private var orientationLabel: String {
        switch orientationMode {
        case .portrait:
            return "縦"
        case .landscape:
            return "横"
        case .system:
            return "自動"
        }
    }

    private func cycleOrientationMode() {
        let nextMode: OrientationMode
        switch orientationMode {
        case .portrait:
            nextMode = .landscape
        case .landscape:
            nextMode = .system
        case .system:
            nextMode = .portrait
        }
        orientationMode = nextMode
        OrientationService.shared.setMode(nextMode)
    }

    private func formatTime(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        } else {
            return String(format: "%d:%02d", m, s)
        }
    }
}

struct MediaImageScreen<Renderer: View>: View {
    private enum SwipeTransitionDirection {
        case left
        case right
    }

    let title: String
    let readingDirection: ReadingDirection
    let currentPageIndex: Int?
    let totalPageCount: Int?
    let pageText: String?
    let canNavigateBackward: Bool
    let canNavigateForward: Bool
    let hasImage: Bool
    let errorMessage: String?
    let onClose: () -> Void
    let onAddToList: (() -> Void)?
    let onPageSeek: ((Int) async -> Void)?
    let onNavigateBackward: (() async -> Void)?
    let onNavigateForward: (() async -> Void)?
    let renderer: Renderer

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var slideOffsetX: CGFloat = 0
    @State private var isDraggingPageSeek = false
    @State private var scrubPageIndex: Int?

    init(
        title: String,
        readingDirection: ReadingDirection,
        currentPageIndex: Int?,
        totalPageCount: Int?,
        pageText: String?,
        canNavigateBackward: Bool,
        canNavigateForward: Bool,
        hasImage: Bool,
        errorMessage: String?,
        onClose: @escaping () -> Void,
        onAddToList: (() -> Void)?,
        onPageSeek: ((Int) async -> Void)?,
        onNavigateBackward: (() async -> Void)?,
        onNavigateForward: (() async -> Void)?,
        @ViewBuilder renderer: () -> Renderer
    ) {
        self.title = title
        self.readingDirection = readingDirection
        self.currentPageIndex = currentPageIndex
        self.totalPageCount = totalPageCount
        self.pageText = pageText
        self.canNavigateBackward = canNavigateBackward
        self.canNavigateForward = canNavigateForward
        self.hasImage = hasImage
        self.errorMessage = errorMessage
        self.onClose = onClose
        self.onAddToList = onAddToList
        self.onPageSeek = onPageSeek
        self.onNavigateBackward = onNavigateBackward
        self.onNavigateForward = onNavigateForward
        self.renderer = renderer()
    }

    var body: some View {
        let effectivePageIndex = scrubPageIndex ?? currentPageIndex
        let effectivePageText: String? = {
            guard let effectivePageIndex, let totalPageCount else { return pageText }
            return "\(effectivePageIndex + 1) / \(totalPageCount)"
        }()
        let pageProgress: Double? = {
            guard let effectivePageIndex, let totalPageCount, totalPageCount > 1 else { return nil }
            let normalized = Double(effectivePageIndex) / Double(totalPageCount - 1)
            switch readingDirection {
            case .rightToLeft:
                return 1 - normalized
            case .leftToRight:
                return normalized
            }
        }()

        ZStack {
            Color.black.ignoresSafeArea()

            renderer
                .scaleEffect(scale)
                .offset(x: slideOffsetX)
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in
                            scale = lastScale * value
                        }
                        .onEnded { _ in
                            lastScale = scale
                            if scale < 1 {
                                withAnimation {
                                    scale = 1
                                }
                                lastScale = 1
                            }
                        }
                )
                .onTapGesture(count: 2) {
                    withAnimation {
                        scale = scale > 1 ? 1 : 2
                        lastScale = scale
                    }
                }

            VStack {
                MediaViewerTopBar(
                    title: title,
                    onClose: onClose,
                    onAddToList: onAddToList
                )
                Spacer()
                MediaViewerImageControls(
                    canNavigateBackward: canNavigateBackward,
                    canNavigateForward: canNavigateForward,
                    isZoomOutEnabled: scale > 1,
                    isZoomToggleEnabled: hasImage,
                    zoomSystemImage: scale > 1 ? "1.magnifyingglass" : "2.magnifyingglass",
                    zoomText: scale > 1 ? "\(Int(scale.rounded()))x" : "1x",
                    pageProgress: pageProgress,
                    pageText: effectivePageText,
                    onPageSeekChanged: pageProgress == nil ? nil : { ratio in
                        guard let totalPageCount, totalPageCount > 1 else { return }
                        let clamped = min(max(ratio, 0), 1)
                        let normalizedIndex: Double
                        switch readingDirection {
                        case .rightToLeft:
                            normalizedIndex = (1 - clamped) * Double(totalPageCount - 1)
                        case .leftToRight:
                            normalizedIndex = clamped * Double(totalPageCount - 1)
                        }
                        let targetIndex = Int(normalizedIndex.rounded())
                        isDraggingPageSeek = true
                        scrubPageIndex = min(max(targetIndex, 0), totalPageCount - 1)
                    },
                    onPageSeekEnded: pageProgress == nil ? nil : {
                        guard let targetIndex = scrubPageIndex,
                              targetIndex != currentPageIndex,
                              let onPageSeek else {
                            isDraggingPageSeek = false
                            scrubPageIndex = nil
                            return
                        }
                        isDraggingPageSeek = false
                        scrubPageIndex = nil
                        Task {
                            await onPageSeek(targetIndex)
                        }
                    },
                    onNavigateBackward: {
                        navigate(isForward: false)
                    },
                    onResetZoom: {
                        withAnimation {
                            scale = 1
                            lastScale = 1
                        }
                    },
                    onToggleZoom: {
                        withAnimation {
                            scale = scale > 1 ? 1 : 2
                            lastScale = scale
                        }
                    },
                    onNavigateForward: {
                        navigate(isForward: true)
                    }
                )
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
        .contentShape(Rectangle())
        .onChange(of: currentPageIndex) { _, _ in
            guard !isDraggingPageSeek else { return }
            scrubPageIndex = nil
        }
        .gesture(
            DragGesture(minimumDistance: 40)
                .onEnded { value in
                    guard scale == 1 else { return }
                    let horizontal = abs(value.translation.width)
                    let vertical = abs(value.translation.height)
                    guard horizontal > vertical * 1.5 else { return }
                    switch readingDirection {
                    case .rightToLeft:
                        if value.translation.width < -40, canNavigateBackward {
                            navigate(isForward: false, transitionDirection: .left)
                        } else if value.translation.width > 40, canNavigateForward {
                            navigate(isForward: true, transitionDirection: .right)
                        }
                    case .leftToRight:
                        if value.translation.width < -40, canNavigateForward {
                            navigate(isForward: true, transitionDirection: .left)
                        } else if value.translation.width > 40, canNavigateBackward {
                            navigate(isForward: false, transitionDirection: .right)
                        }
                    }
                }
        )
    }

    private func navigate(
        isForward: Bool,
        transitionDirection: SwipeTransitionDirection? = nil
    ) {
        let action = isForward ? onNavigateForward : onNavigateBackward
        guard let action else { return }

        let screenWidth = UIScreen.main.bounds.width
        let exitEdge: CGFloat
        switch transitionDirection {
        case .left:
            exitEdge = -screenWidth
        case .right:
            exitEdge = screenWidth
        case nil:
            switch readingDirection {
            case .rightToLeft:
                exitEdge = isForward ? -screenWidth : screenWidth
            case .leftToRight:
                exitEdge = isForward ? screenWidth : -screenWidth
            }
        }

        Task { @MainActor in
            withAnimation(.easeInOut(duration: 0.2)) {
                slideOffsetX = exitEdge
            }
            try? await Task.sleep(for: .milliseconds(200))

            await action()
            withAnimation(.none) {
                scale = 1
                lastScale = 1
                slideOffsetX = -exitEdge
            }
            withAnimation(.easeInOut(duration: 0.2)) {
                slideOffsetX = 0
            }
        }
    }
}
