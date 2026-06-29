import Foundation
import UIKit
import AVFoundation
import MobileVLCKit

#if !targetEnvironment(simulator)
import AMSMB2
#endif

struct VideoPlayerCachingPolicy {
    let networkCachingMilliseconds: Int
    let inputCachingMilliseconds: Int

    static func directSMB(fileSize: Int64?) -> VideoPlayerCachingPolicy {
        guard let fileSize, fileSize > 0 else {
            return VideoPlayerCachingPolicy(networkCachingMilliseconds: 500, inputCachingMilliseconds: 3000)
        }

        let gib = Int64(1024 * 1024 * 1024)
        switch fileSize {
        case (8 * gib)...:
            return VideoPlayerCachingPolicy(networkCachingMilliseconds: 1000, inputCachingMilliseconds: 6000)
        case (4 * gib)...:
            return VideoPlayerCachingPolicy(networkCachingMilliseconds: 750, inputCachingMilliseconds: 5000)
        case (2 * gib)...:
            return VideoPlayerCachingPolicy(networkCachingMilliseconds: 500, inputCachingMilliseconds: 4000)
        default:
            return VideoPlayerCachingPolicy(networkCachingMilliseconds: 500, inputCachingMilliseconds: 3000)
        }
    }
}

struct VideoPlayerInteractiveSeekPolicy {
    static let directSMBPreviewEnabled = false
    static let previewIntervalMilliseconds = 300
    static let minimumPreviewDeltaSeconds = 0.25
}

@Observable
final class VideoPlayerViewModel: NSObject {

    private enum StartupPlaybackPath {
        case directSMB
        case smbStream
        case httpProxy
        case avPlayer
    }

    var isPlaying = false
    var isMuted = false
    var currentPositionSeconds: Double = 0
    var durationSeconds: Double = 0
    var errorMessage: String?

    // MP4 / MOV は AVPlayer 経路で再生する。true のとき View は AVPlayerLayer を描画する。
    private(set) var usesAVPlayer = false
    private(set) var avPlayer: AVPlayer?
    // AVPlayer 経路の drag 中スクラブで表示するプレビュー画像。
    private(set) var scrubPreviewImage: UIImage?
    private var scrubPreviewTask: Task<Void, Never>?
    // 一瞬の buffering でスピナーを点滅させないためのデバウンス。
    private var avBufferingDebounceTask: Task<Void, Never>?
    // シーク操作の開始時に再生中だったか。指を離したときの再開判定に使う。
    private var wasPlayingBeforeInteractiveSeek = false
    // AVPlayer 経路でユーザーが再生を望んでいるかの意図。buffering で揺れる isPlaying と違い、
    // 明示的な再生/一時停止だけで変わる。連続シーク中の再開判定をこの値で安定させる。
    private var avIntendsToPlay = false

    private(set) var isBuffering = true
    private var hasEverStartedPlaying = false

    let connection: RemoteConnection
    let item: DirectoryItem

    let player = VLCMediaPlayer()
    let playerID: String

    private let playbackHistoryService: PlaybackHistoryService
    private let smbClientManager: SMBClientManager
    private var setupTask: Task<Void, Never>?
    private var isTearingDownPlayback = false
    private var startupBeganAt: CFAbsoluteTime = 0
    private var proxyReadyAt: CFAbsoluteTime = 0
    private var mediaAttachedAt: CFAbsoluteTime = 0
    private var playRequestedAt: CFAbsoluteTime = 0
    private var startupDidLogPlaying = false
    private var startupPlaybackPath: StartupPlaybackPath?
    private var didFallbackToProxy = false
    private var startupFallbackTask: Task<Void, Never>?
    private var startupTimelineWatchdogTask: Task<Void, Never>?
    private var currentStartupStartPositionSeconds: Double = 0
    private var directSMBStartupRetryCount = 0
    private var isInteractiveSeeking = false
    private var pendingInteractiveSeekSeconds: Double?
    private var lastInteractiveSeekPreviewSeconds: Double?
    private var interactiveSeekPreviewTask: Task<Void, Never>?
    private var interactiveSeekDiagnostics: InteractiveSeekDiagnostics?
    private var interactiveSeekDiagnosticsFinalizeTask: Task<Void, Never>?
    private var lastObservedPlaybackTimeMs: Int32?
    private var lastPlaybackInterruptionLog: String?
    private var isDrawableReady = false
    private var hasObservedPlayableTimeline = false
    private var didLogStartupBufferingBeforeTimeline = false
    private var didRecordPlayerError = false

    private struct InteractiveSeekDiagnostics {
        let startedAt: CFAbsoluteTime
        let startedPlaybackSeconds: Double
        let startedRequestSeconds: Double
        var requestCount = 0
        var firstRequestIssuedAt: CFAbsoluteTime?
        var lastRequestIssuedAt: CFAbsoluteTime?
        var lastRequestedSeconds: Double?
        var finalRequestedSeconds: Double?
        var lastObservedSeconds: Double?
        var firstResponseMs: Int?
        var firstResponseDeltaSeconds: Double?
        var latencyCount = 0
        var totalLatencyMs = 0
        var maxLatencyMs = 0
        var bufferingDuringSeek = false

        mutating func recordRequest(seconds: Double, issuedAt: CFAbsoluteTime) {
            requestCount += 1
            if firstRequestIssuedAt == nil {
                firstRequestIssuedAt = issuedAt
            }
            lastRequestIssuedAt = issuedAt
            lastRequestedSeconds = seconds
        }

        mutating func recordObservation(seconds: Double, observedAt: CFAbsoluteTime) -> (responseMs: Int, deltaSeconds: Double)? {
            lastObservedSeconds = seconds
            let firstResponse = recordFirstResponseIfNeeded(seconds: seconds, observedAt: observedAt)

            guard let lastRequestIssuedAt,
                  let lastRequestedSeconds,
                  abs(seconds - lastRequestedSeconds) <= 1.0 else { return firstResponse }

            let latencyMs = max(0, Int((observedAt - lastRequestIssuedAt) * 1000))
            latencyCount += 1
            totalLatencyMs += latencyMs
            maxLatencyMs = max(maxLatencyMs, latencyMs)
            self.lastRequestIssuedAt = nil
            return firstResponse
        }

        private mutating func recordFirstResponseIfNeeded(
            seconds: Double,
            observedAt: CFAbsoluteTime
        ) -> (responseMs: Int, deltaSeconds: Double)? {
            guard firstResponseMs == nil,
                  let firstRequestIssuedAt,
                  requestCount > 0 else { return nil }

            let movedFromStart = abs(seconds - startedPlaybackSeconds)
            let reachedLastRequest = lastRequestedSeconds.map { abs(seconds - $0) <= 1.0 } ?? false
            guard movedFromStart >= 0.5 || reachedLastRequest else { return nil }

            let responseMs = max(0, Int((observedAt - firstRequestIssuedAt) * 1000))
            firstResponseMs = responseMs
            firstResponseDeltaSeconds = movedFromStart
            return (responseMs, movedFromStart)
        }
    }

#if !targetEnvironment(simulator)
    private var streamingServer: SMBStreamingServer?
    private var streamClient: SMB2Manager?
    private var streamInput: SMBRangeInputStream?
    private var avController: AVPlayerVideoController?
    private var avStreamClient: SMB2Manager?
#endif

    init(
        connection: RemoteConnection,
        item: DirectoryItem,
        playbackHistoryService: PlaybackHistoryService,
        smbClientManager: SMBClientManager,
        startPositionSeconds: Double = 0
    ) {
        self.connection = connection
        self.item = item
        self.playerID = UUID().uuidString
        self.playbackHistoryService = playbackHistoryService
        self.smbClientManager = smbClientManager
        super.init()
        player.delegate = self
        VideoPlayerDiagnostics.playerDidInit(playerID: playerID)
        print("[VideoPlayer] init | playerID: \(playerID) | file: \(item.name)")
        setupMedia(startPositionSeconds: startPositionSeconds)
    }

    deinit {
        print("[VideoPlayer] deinit start | playerID: \(playerID) | file: \(item.name)")
        tearDownPlayback(trigger: "deinit")
        VideoPlayerDiagnostics.playerDidDeinit(playerID: playerID)
        print("[VideoPlayer] deinit end | playerID: \(playerID) | file: \(item.name)")
    }

    func cancelSetup() {
        if setupTask != nil {
            FirebaseSupport.logCrashlytics("[VideoPlayer] cancelSetup | playerID: \(playerID)")
            FirebaseSupport.logEvent("vp_setup_cancelled")
            print("[VideoPlayer] cancelSetup | playerID: \(playerID) | file: \(item.name)")
        }
        startupFallbackTask?.cancel()
        startupFallbackTask = nil
        startupTimelineWatchdogTask?.cancel()
        startupTimelineWatchdogTask = nil
        interactiveSeekDiagnosticsFinalizeTask?.cancel()
        interactiveSeekDiagnosticsFinalizeTask = nil
        interactiveSeekDiagnostics = nil
        setupTask?.cancel()
        setupTask = nil
#if !targetEnvironment(simulator)
        streamingServer?.stop()
        streamingServer = nil
        streamInput?.close()
        streamInput = nil
        let client = streamClient
        streamClient = nil
        Task { try? await client?.disconnectShare() }
        tearDownAVPlayer()
#endif
    }

    func togglePlayPause() {
#if !targetEnvironment(simulator)
        if usesAVPlayer {
            // toggle 前の状態から再生意図を確定する。buffering 中の isPlaying には依存しない。
            avIntendsToPlay = (avController?.isPaused ?? true)
            avController?.togglePlayPause()
            return
        }
#endif
        if player.isPlaying {
            pausePlayback(trigger: "toggle")
        } else {
            playIfReady(trigger: "toggle")
        }
    }

    func toggleMute() {
        isMuted.toggle()
#if !targetEnvironment(simulator)
        if usesAVPlayer {
            avController?.setMuted(isMuted)
            return
        }
#endif
        player.audio?.isMuted = isMuted
    }

    func skip(seconds: Double) {
#if !targetEnvironment(simulator)
        if usesAVPlayer {
            avController?.skip(seconds: seconds)
            return
        }
#endif
        let newMs = Int32(max(0, currentPositionSeconds + seconds) * 1000)
        player.time = VLCTime(int: newMs)
    }

    func seek(to seconds: Double) {
#if !targetEnvironment(simulator)
        if usesAVPlayer {
            avController?.seek(toSeconds: seconds)
            return
        }
#endif
        let ms = Int32(max(0, seconds) * 1000)
        player.time = VLCTime(int: ms)
    }

    func updateInteractiveSeek(to seconds: Double) {
        let clamped = max(0, seconds)
        pendingInteractiveSeekSeconds = clamped
        if !isInteractiveSeeking {
            isInteractiveSeeking = true
            // drag 中は音と映像がずれるので再生を止め、指を離したときに元の状態へ戻す。
            // AVPlayer は buffering で isPlaying が揺れるため、安定した再生意図で判定する。
#if !targetEnvironment(simulator)
            wasPlayingBeforeInteractiveSeek = usesAVPlayer ? avIntendsToPlay : isPlaying
#else
            wasPlayingBeforeInteractiveSeek = isPlaying
#endif
            pauseForInteractiveSeek()
            beginInteractiveSeekDiagnostics(startedSeconds: clamped)
        }

#if !targetEnvironment(simulator)
        if usesAVPlayer {
            scheduleScrubPreview()
            return
        }
#endif

        guard shouldPreviewInteractiveSeekDuringDrag else {
            return
        }
        scheduleInteractiveSeekPreview()
    }

    func endInteractiveSeek() {
        guard isInteractiveSeeking else { return }
        interactiveSeekPreviewTask?.cancel()
        interactiveSeekPreviewTask = nil
        scrubPreviewTask?.cancel()
        scrubPreviewTask = nil
        scrubPreviewImage = nil
#if !targetEnvironment(simulator)
        // 進行中のスクラブ読み出しを切り、再開シークへ SMB セッションを即座に明け渡す。
        avController?.cancelThumbnailGeneration()
#endif
        if let pendingInteractiveSeekSeconds {
            recordInteractiveSeekRequest(seconds: pendingInteractiveSeekSeconds)
            interactiveSeekDiagnostics?.finalRequestedSeconds = pendingInteractiveSeekSeconds
            seek(to: pendingInteractiveSeekSeconds)
        }
        isInteractiveSeeking = false
        pendingInteractiveSeekSeconds = nil
        lastInteractiveSeekPreviewSeconds = nil
        if wasPlayingBeforeInteractiveSeek {
            resumeAfterInteractiveSeek()
        }
        wasPlayingBeforeInteractiveSeek = false
        finalizeInteractiveSeekDiagnosticsAfterDelay()
    }

    private func pauseForInteractiveSeek() {
#if !targetEnvironment(simulator)
        if usesAVPlayer {
            avController?.pause()
            return
        }
#endif
        player.pause()
    }

    private func resumeAfterInteractiveSeek() {
#if !targetEnvironment(simulator)
        if usesAVPlayer {
            avController?.play()
            return
        }
#endif
        playIfReady(trigger: "interactive_seek_end")
    }

    private func scheduleInteractiveSeekPreview() {
        guard interactiveSeekPreviewTask == nil else { return }
        interactiveSeekPreviewTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(VideoPlayerInteractiveSeekPolicy.previewIntervalMilliseconds))
            guard !Task.isCancelled else { return }
            self?.applyInteractiveSeekPreview()
        }
    }

    private func applyInteractiveSeekPreview() {
        interactiveSeekPreviewTask = nil
        guard isInteractiveSeeking,
              let pendingInteractiveSeekSeconds else { return }

        let minimumDelta = VideoPlayerInteractiveSeekPolicy.minimumPreviewDeltaSeconds
        if lastInteractiveSeekPreviewSeconds.map({ abs($0 - pendingInteractiveSeekSeconds) > minimumDelta }) ?? true {
            recordInteractiveSeekRequest(seconds: pendingInteractiveSeekSeconds)
            seek(to: pendingInteractiveSeekSeconds)
            lastInteractiveSeekPreviewSeconds = pendingInteractiveSeekSeconds
        }
    }

#if !targetEnvironment(simulator)
    /// AVPlayer 経路の drag 中スクラブ。実 seek せず、最新ドラッグ位置のキーフレーム画像を表示する。
    /// 1枚生成するたびにタスクを空けて、ドラッグ中は約100ms間隔で最新位置を取り直す。
    private func scheduleScrubPreview() {
        // 生成は常に1本だけ走らせる。ドラッグ中の重複生成が単一 SMB セッションを飽和させないよう、
        // 走っている間は新規 schedule をはじき、完了時に最新位置だけ取り直す。
        guard scrubPreviewTask == nil else { return }
        scrubPreviewTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            await self?.runScrubPreviewLoop()
        }
    }

    private func runScrubPreviewLoop() async {
        defer { scrubPreviewTask = nil }
        // 生成中に指が動いた場合だけ最新位置で取り直す。同じ位置なら抜ける。
        while isInteractiveSeeking, let seconds = pendingInteractiveSeekSeconds,
              let controller = avController {
            let image = await controller.generateThumbnail(atSeconds: seconds)
            guard isInteractiveSeeking else { return }
            if let image { scrubPreviewImage = image }
            if pendingInteractiveSeekSeconds == seconds { return }
        }
    }
#endif

    private var shouldPreviewInteractiveSeekDuringDrag: Bool {
        switch startupPlaybackPath {
        case .directSMB:
            return VideoPlayerInteractiveSeekPolicy.directSMBPreviewEnabled
        case .avPlayer:
            // AVPlayer 経路は drag 中にライブ seek せず、サムネイルスクラブ（2c）で追従させる。
            return false
        case .smbStream, .httpProxy, nil:
            return true
        }
    }

    private func beginInteractiveSeekDiagnostics(startedSeconds: Double) {
        interactiveSeekDiagnosticsFinalizeTask?.cancel()
        interactiveSeekDiagnosticsFinalizeTask = nil
        interactiveSeekDiagnostics = InteractiveSeekDiagnostics(
            startedAt: CFAbsoluteTimeGetCurrent(),
            startedPlaybackSeconds: currentPositionSeconds,
            startedRequestSeconds: startedSeconds
        )
        print("[SeekDiag] begin | playbackSeconds: \(String(format: "%.2f", currentPositionSeconds)) | requestSeconds: \(String(format: "%.2f", startedSeconds)) | playerID: \(playerID) | file: \(item.name)")
    }

    private func recordInteractiveSeekRequest(seconds: Double) {
        guard interactiveSeekDiagnostics != nil else { return }
        interactiveSeekDiagnostics?.recordRequest(
            seconds: seconds,
            issuedAt: CFAbsoluteTimeGetCurrent()
        )
    }

    private func recordInteractiveSeekObservation(seconds: Double) {
        guard interactiveSeekDiagnostics != nil else { return }
        let firstResponse = interactiveSeekDiagnostics?.recordObservation(
            seconds: seconds,
            observedAt: CFAbsoluteTimeGetCurrent()
        )
        if let firstResponse {
            print("[SeekDiag] firstResponse | responseMs: \(firstResponse.responseMs) | deltaSeconds: \(String(format: "%.2f", firstResponse.deltaSeconds)) | observedSeconds: \(String(format: "%.2f", seconds)) | playerID: \(playerID) | file: \(item.name)")
        }
    }

    private func markInteractiveSeekBuffering() {
        guard interactiveSeekDiagnostics != nil else { return }
        interactiveSeekDiagnostics?.bufferingDuringSeek = true
    }

    private func finalizeInteractiveSeekDiagnosticsAfterDelay() {
        interactiveSeekDiagnosticsFinalizeTask?.cancel()
        interactiveSeekDiagnosticsFinalizeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.logInteractiveSeekDiagnosticsSummary()
        }
    }

    private func logInteractiveSeekDiagnosticsSummary() {
        interactiveSeekDiagnosticsFinalizeTask = nil
        guard let diagnostics = interactiveSeekDiagnostics else { return }
        interactiveSeekDiagnostics = nil

        let now = CFAbsoluteTimeGetCurrent()
        let dragMs = Int((now - diagnostics.startedAt) * 1000)
        let avgLatencyMs = diagnostics.latencyCount > 0
            ? diagnostics.totalLatencyMs / diagnostics.latencyCount
            : -1
        let finalRequestedSeconds = diagnostics.finalRequestedSeconds ?? diagnostics.lastRequestedSeconds ?? diagnostics.startedRequestSeconds
        let finalObservedSeconds = diagnostics.lastObservedSeconds ?? currentPositionSeconds
        let finalDeltaSeconds = abs(finalObservedSeconds - finalRequestedSeconds)
        let firstResponseMs = diagnostics.firstResponseMs ?? -1
        let firstResponseDeltaSeconds = diagnostics.firstResponseDeltaSeconds ?? -1
        let line = "[SeekDiag] summary | dragMs: \(dragMs) | seekRequests: \(diagnostics.requestCount) | firstResponseMs: \(firstResponseMs) | firstResponseDeltaSeconds: \(String(format: "%.2f", firstResponseDeltaSeconds)) | latencyCount: \(diagnostics.latencyCount) | avgLatencyMs: \(avgLatencyMs) | maxLatencyMs: \(diagnostics.maxLatencyMs) | bufferingDuringSeek: \(diagnostics.bufferingDuringSeek) | finalRequestedSeconds: \(String(format: "%.2f", finalRequestedSeconds)) | finalObservedSeconds: \(String(format: "%.2f", finalObservedSeconds)) | finalDeltaSeconds: \(String(format: "%.2f", finalDeltaSeconds)) | playerID: \(playerID) | file: \(item.name)"
        let telemetryLine = "[SeekDiag] summary | dragMs: \(dragMs) | seekRequests: \(diagnostics.requestCount) | firstResponseMs: \(firstResponseMs) | firstResponseDeltaSeconds: \(String(format: "%.2f", firstResponseDeltaSeconds)) | latencyCount: \(diagnostics.latencyCount) | avgLatencyMs: \(avgLatencyMs) | maxLatencyMs: \(diagnostics.maxLatencyMs) | bufferingDuringSeek: \(diagnostics.bufferingDuringSeek) | finalRequestedSeconds: \(String(format: "%.2f", finalRequestedSeconds)) | finalObservedSeconds: \(String(format: "%.2f", finalObservedSeconds)) | finalDeltaSeconds: \(String(format: "%.2f", finalDeltaSeconds)) | playerID: \(playerID)"
        print(line)
        FirebaseSupport.logCrashlytics(telemetryLine)
    }

    // MARK: - 視聴履歴保存

    func saveWatchPosition(capturesThumbnail: Bool = true) async {
        let thumbnail = capturesThumbnail ? await captureThumbnailForHistory() : nil
        await playbackHistoryService.saveProgress(
            source: .remote(connection.id),
            connection: connection,
            item: item,
            currentPositionSeconds: currentPositionSeconds,
            durationSeconds: durationSeconds,
            thumbnailData: thumbnail
        )
    }

    func playIfReady(trigger: String) {
        guard player.media != nil else {
            print("[VideoPlayer] play skipped (media not ready) | trigger: \(trigger) | playerID: \(playerID) | file: \(item.name)")
            return
        }
        if playRequestedAt == 0 {
            playRequestedAt = CFAbsoluteTimeGetCurrent()
        }
        logStartupDiag(event: "play_requested", extra: "trigger: \(trigger)")
        print("[VideoPlayer] play | trigger: \(trigger) | playerID: \(playerID) | file: \(item.name)")
        player.play()
    }

    func markDrawableReady() {
        isDrawableReady = true
#if !targetEnvironment(simulator)
        if usesAVPlayer {
            avController?.markDrawableReady()
            return
        }
#endif
        playIfReady(trigger: "drawable_ready")
    }

    func pausePlayback(trigger: String) {
        print("[VideoPlayer] pause | trigger: \(trigger) | playerID: \(playerID) | file: \(item.name)")
#if !targetEnvironment(simulator)
        if usesAVPlayer {
            avController?.pause()
            return
        }
#endif
        player.pause()
    }

    func stopPlayback(trigger: String) {
        print("[VideoPlayer] stop | trigger: \(trigger) | playerID: \(playerID) | file: \(item.name)")
#if !targetEnvironment(simulator)
        if usesAVPlayer {
            avController?.pause()
            return
        }
#endif
        player.stop()
    }

    func tearDownPlayback(trigger: String) {
        print("[VideoPlayer] teardown start | trigger: \(trigger) | playerID: \(playerID) | file: \(item.name)")
        VideoPlayerDiagnostics.logMemory(event: "teardown_start_\(trigger)", playerID: playerID)
        isTearingDownPlayback = true
        startupFallbackTask?.cancel()
        startupFallbackTask = nil
        startupTimelineWatchdogTask?.cancel()
        startupTimelineWatchdogTask = nil
        setupTask?.cancel()
        setupTask = nil
        player.stop()
        player.delegate = nil
        player.media?.delegate = nil
        player.media = nil
#if !targetEnvironment(simulator)
        streamingServer?.stop()
        streamingServer = nil
        streamInput?.close()
        streamInput = nil
        let client = streamClient
        streamClient = nil
        Task { try? await client?.disconnectShare() }
        tearDownAVPlayer()
#endif
        startupPlaybackPath = nil
        didFallbackToProxy = false
        isInteractiveSeeking = false
        isDrawableReady = false
        currentStartupStartPositionSeconds = 0
        interactiveSeekPreviewTask?.cancel()
        interactiveSeekPreviewTask = nil
        scrubPreviewTask?.cancel()
        scrubPreviewTask = nil
        scrubPreviewImage = nil
        interactiveSeekDiagnosticsFinalizeTask?.cancel()
        interactiveSeekDiagnosticsFinalizeTask = nil
        interactiveSeekDiagnostics = nil
        pendingInteractiveSeekSeconds = nil
        lastInteractiveSeekPreviewSeconds = nil
        hasObservedPlayableTimeline = false
        didLogStartupBufferingBeforeTimeline = false
        VideoPlayerDiagnostics.logMemory(event: "teardown_end_\(trigger)", playerID: playerID)
        print("[VideoPlayer] teardown end | trigger: \(trigger) | playerID: \(playerID) | file: \(item.name)")
    }

    private func captureThumbnailForHistory() async -> Data? {
#if !targetEnvironment(simulator)
        if usesAVPlayer {
            guard let image = await avController?.generateThumbnail(atSeconds: currentPositionSeconds) else {
                return nil
            }
            return await MainActor.run { cropTo16x9(image)?.jpegData(compressionQuality: 0.5) }
        }
#endif
        return await MainActor.run { captureCurrentFrame() }
    }

    private func captureCurrentFrame() -> Data? {
        guard let view = player.drawable as? UIView,
              view.bounds.width > 0,
              view.bounds.height > 0 else { return nil }
        let size = view.bounds.size
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: false)
        }
        return cropTo16x9(image)?.jpegData(compressionQuality: 0.5)
    }

    private func cropTo16x9(_ image: UIImage) -> UIImage? {
        let size = image.size
        let targetRatio: CGFloat = 16.0 / 9.0
        let currentRatio = size.width / size.height
        // すでに16:9に近ければそのまま返す
        if abs(currentRatio - targetRatio) < 0.05 {
            return image
        }
        let cropRect: CGRect
        if currentRatio > targetRatio {
            // 横長すぎる → 幅を中央クロップ
            let w = size.height * targetRatio
            cropRect = CGRect(x: (size.width - w) / 2, y: 0, width: w, height: size.height)
        } else {
            // 縦長（VLCフルスクリーンの典型） → 高さを中央クロップ
            let h = size.width / targetRatio
            cropRect = CGRect(x: 0, y: (size.height - h) / 2, width: size.width, height: h)
        }
        let scale = image.scale
        let scaledRect = CGRect(
            x: cropRect.origin.x * scale,
            y: cropRect.origin.y * scale,
            width: cropRect.size.width * scale,
            height: cropRect.size.height * scale
        )
        guard let cgImage = image.cgImage?.cropping(to: scaledRect) else { return image }
        return UIImage(cgImage: cgImage, scale: scale, orientation: .up)
    }

    // MARK: - Private

    private func setupMedia(startPositionSeconds: Double) {
        print("[VideoPlayer] setupMedia | playerID: \(playerID) | startPosition: \(startPositionSeconds)s | file: \(item.name)")
        isTearingDownPlayback = false
        resetStartupDiagnostics()
        logStartupDiag(event: "begin")
#if !targetEnvironment(simulator)
        if Self.isAVPlayerEligible(item) {
            startupPlaybackPath = .avPlayer
            setupTask = Task { [weak self] in
                await self?.prepareAVPlayerMedia(startPositionSeconds: startPositionSeconds)
            }
        } else {
            setupMediaOnDevice(startPositionSeconds: startPositionSeconds)
        }
#else
        setupMediaDirect(startPositionSeconds: startPositionSeconds)
#endif
    }

#if !targetEnvironment(simulator)
    private func setupMediaOnDevice(startPositionSeconds: Double) {
        startupPlaybackPath = .directSMB
        didFallbackToProxy = false
        guard let url = buildSMBURL() else {
            errorMessage = "メディアURLの構築に失敗しました"
            print("[VideoPlayer] Failed to build direct SMB URL | playerID: \(playerID) | file: \(item.name) | path: \(item.path)")
            return
        }
        attachDirectSMBMedia(url: url, startPositionSeconds: startPositionSeconds)
    }

    private func prepareAVPlayerMedia(startPositionSeconds: Double) async {
        do {
            let credential = try smbClientManager.loadCredential(for: connection)
            let shareName = credential.shareName == "/" ? "" : credential.shareName
            let client = try smbClientManager.makeDedicatedClient(for: connection)
            try await client.connectShare(name: shareName)

            let resolvedPath = await resolveSMBStreamPath(client: client, path: item.path)
            let fileSize = try await resolveSMBStreamFileSize(client: client, path: resolvedPath)

            if Task.isCancelled {
                try? await client.disconnectShare()
                return
            }

            let dataSource = SMBByteRangeDataSource(
                client: client,
                path: resolvedPath,
                fileSize: fileSize,
                ownerID: playerID
            )

            await MainActor.run {
                self.attachAVPlayerMedia(
                    client: client,
                    dataSource: dataSource,
                    startPositionSeconds: startPositionSeconds
                )
            }
        } catch {
            await MainActor.run {
                print("[VideoPlayer] AVPlayer setup failed; fallback to direct SMB | playerID: \(self.playerID) | file: \(self.item.name) | error: \(error)")
                self.fallbackToDirectSMBAfterHTTPProxyFailure(
                    startPositionSeconds: startPositionSeconds,
                    error: error
                )
            }
        }
    }

    private func attachAVPlayerMedia(
        client: SMB2Manager,
        dataSource: ByteRangeDataSource,
        startPositionSeconds: Double
    ) {
        currentStartupStartPositionSeconds = startPositionSeconds
        hasObservedPlayableTimeline = false
        didLogStartupBufferingBeforeTimeline = false
        lastObservedPlaybackTimeMs = nil
        startupPlaybackPath = .avPlayer
        setupTask = nil

        // VLC / stream 系のリソースが残っていれば片付ける。
        streamingServer?.stop()
        streamingServer = nil
        streamInput?.close()
        streamInput = nil
        let oldStreamClient = streamClient
        streamClient = nil
        Task { try? await oldStreamClient?.disconnectShare() }

        avStreamClient = client
        let contentType = Self.avContentType(for: item)
        let controller = AVPlayerVideoController(
            dataSource: dataSource,
            contentType: contentType,
            fileName: item.name,
            startPositionSeconds: startPositionSeconds,
            ownerID: playerID
        )
        wireAVController(controller)
        avController = controller
        avPlayer = controller.player
        usesAVPlayer = true
        controller.setMuted(isMuted)
        controller.load()

        mediaAttachedAt = CFAbsoluteTimeGetCurrent()
        logStartupDiag(
            event: "media_attached",
            extra: "path: av_player | contentType: \(contentType) | startPosition: \(startPositionSeconds)"
        )
        if isDrawableReady {
            controller.markDrawableReady()
        }
    }

    private func wireAVController(_ controller: AVPlayerVideoController) {
        controller.onTimeChanged = { [weak self] seconds in
            guard let self else { return }
            self.currentPositionSeconds = seconds
            self.recordInteractiveSeekObservation(seconds: seconds)
            if seconds > 0 {
                self.hasObservedPlayableTimeline = true
            }
        }
        controller.onDurationChanged = { [weak self] duration in
            self?.durationSeconds = duration
        }
        controller.onBufferingChanged = { [weak self] buffering in
            guard let self else { return }
            if buffering {
                self.markInteractiveSeekBuffering()
            }
            self.updateAVBuffering(buffering)
        }
        controller.onPlayingChanged = { [weak self] playing in
            guard let self else { return }
            self.isPlaying = playing
            if playing {
                self.hasEverStartedPlaying = true
                // 実際に再生が始まったら意図も再生中で確定する（初回自動再生・再開の両方を拾う）。
                self.avIntendsToPlay = true
                self.updateAVBuffering(false)
            }
        }
        controller.onFailed = { [weak self] error in
            guard let self, !self.isTearingDownPlayback else { return }
            self.errorMessage = "再生エラーが発生しました"
            print("[VideoPlayer] AVPlayer error | playerID: \(self.playerID) | file: \(self.item.name) | error: \(String(describing: error))")
        }
    }

    private func tearDownAVPlayer() {
        guard avController != nil || avStreamClient != nil else { return }
        avBufferingDebounceTask?.cancel()
        avBufferingDebounceTask = nil
        avController?.tearDown()
        avController = nil
        avPlayer = nil
        usesAVPlayer = false
        let client = avStreamClient
        avStreamClient = nil
        Task { try? await client?.disconnectShare() }
    }

    /// AVPlayer の buffering をデバウンスしてスピナーの点滅を抑える。
    private func updateAVBuffering(_ buffering: Bool) {
        avBufferingDebounceTask?.cancel()
        avBufferingDebounceTask = nil
        guard buffering else {
            isBuffering = false
            return
        }
        avBufferingDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            // drag 中はスクラブ画像を見せるのでスピナーは出さない。
            guard !self.isInteractiveSeeking else { return }
            self.isBuffering = true
        }
    }

    private func prepareHTTPProxyMedia(startPositionSeconds: Double) async {
        do {
            let credential = try smbClientManager.loadCredential(for: connection)
            let shareName = credential.shareName == "/" ? "" : credential.shareName
            let client = try smbClientManager.makeDedicatedClient(for: connection)
            try await client.connectShare(name: shareName)

            let server = SMBStreamingServer(ownerID: playerID)
            try await server.start(client: client, filePath: item.path, fileSize: item.size)

            guard let localURL = server.localURL else {
                server.stop()
                throw NSError(domain: "VideoPlayer", code: 10, userInfo: [
                    NSLocalizedDescriptionKey: "HTTP proxy URL is missing"
                ])
            }

            if Task.isCancelled {
                server.stop()
                return
            }

            await MainActor.run {
                self.attachHTTPProxyMedia(
                    server: server,
                    localURL: localURL,
                    startPositionSeconds: startPositionSeconds
                )
            }
        } catch {
            await MainActor.run {
                self.fallbackToDirectSMBAfterHTTPProxyFailure(
                    startPositionSeconds: startPositionSeconds,
                    error: error
                )
            }
        }
    }

    private func attachHTTPProxyMedia(
        server: SMBStreamingServer,
        localURL: URL,
        startPositionSeconds: Double
    ) {
        currentStartupStartPositionSeconds = startPositionSeconds
        hasObservedPlayableTimeline = false
        didLogStartupBufferingBeforeTimeline = false
        lastObservedPlaybackTimeMs = nil
        startupPlaybackPath = .httpProxy
        setupTask = nil

        streamingServer?.stop()
        streamingServer = server
        streamInput?.close()
        streamInput = nil
        let oldClient = streamClient
        streamClient = nil
        Task { try? await oldClient?.disconnectShare() }

        let networkCaching = 300
        let fileCaching = 300
        print("[VideoPlayer] Using HTTP proxy v2: \(localURL.absoluteString) | startPosition: \(startPositionSeconds)s | playerID: \(playerID) | file: \(item.name)")
        let media = VLCMedia(url: localURL)
        media.delegate = self
        media.addOption(":network-caching=\(networkCaching)")
        media.addOption(":file-caching=\(fileCaching)")
        media.addOption(":input-fast-seek")
        if startPositionSeconds > 0 {
            media.addOption(":start-time=\(Int(startPositionSeconds))")
        }
        media.parse(options: .parseNetwork, timeout: 10000)
        player.media = media
        proxyReadyAt = CFAbsoluteTimeGetCurrent()
        mediaAttachedAt = proxyReadyAt
        logStartupDiag(
            event: "media_attached",
            extra: "path: http_proxy_v2 | networkCaching: \(networkCaching) | fileCaching: \(fileCaching) | parse: network_timeout_10000 | startPosition: \(startPositionSeconds)"
        )
        if isDrawableReady {
            playIfReady(trigger: "http_proxy_ready")
        }
    }

    private func fallbackToDirectSMBAfterHTTPProxyFailure(startPositionSeconds: Double, error: Error) {
        setupTask = nil
        print("[VideoPlayer] HTTP proxy setup failed; fallback to direct SMB | playerID: \(playerID) | file: \(item.name) | error: \(error)")
        guard let url = buildSMBURL() else {
            errorMessage = "メディアURLの構築に失敗しました"
            print("[VideoPlayer] Failed to build fallback SMB URL | playerID: \(playerID) | file: \(item.name) | path: \(item.path)")
            return
        }
        attachDirectSMBMedia(url: url, startPositionSeconds: startPositionSeconds)
    }

    private func attachDirectSMBMedia(url: URL, startPositionSeconds: Double) {
        currentStartupStartPositionSeconds = startPositionSeconds
        hasObservedPlayableTimeline = false
        didLogStartupBufferingBeforeTimeline = false
        lastObservedPlaybackTimeMs = nil

        streamingServer?.stop()
        streamingServer = nil
        streamInput?.close()
        streamInput = nil
        let oldClient = streamClient
        streamClient = nil
        Task { try? await oldClient?.disconnectShare() }

        let sanitizedURL = sanitizeURL(url)
        let cachingPolicy = VideoPlayerCachingPolicy.directSMB(fileSize: item.size)
        let networkCaching = cachingPolicy.networkCachingMilliseconds
        let smbCaching = cachingPolicy.inputCachingMilliseconds
        print("[VideoPlayer] Using direct SMB: \(sanitizedURL) | startPosition: \(startPositionSeconds)s | startupRetry: \(directSMBStartupRetryCount) | playerID: \(playerID) | file: \(item.name)")
        let media = VLCMedia(url: url)
        media.delegate = self
        media.addOption(":network-caching=\(networkCaching)")
        media.addOption(":smb-caching=\(smbCaching)")
        media.addOption(":file-caching=\(smbCaching)")
        media.addOption(":input-fast-seek")
        // 重い HEVC / 4K でソフトデコードに落ちて停止しないよう VideoToolbox を明示する
        media.addOption(":avcodec-hw=videotoolbox")
        if let credential = try? smbClientManager.loadCredential(for: connection) {
            if !credential.username.isEmpty {
                media.addOption(":smb-user=\(credential.username)")
            }
            if !credential.password.isEmpty {
                media.addOption(":smb-pwd=\(credential.password)")
            }
        }
        if startPositionSeconds > 0 {
            media.addOption(":start-time=\(Int(startPositionSeconds))")
        }
        media.parse(options: .parseNetwork, timeout: 10000)
        player.media = media
        mediaAttachedAt = CFAbsoluteTimeGetCurrent()
        logStartupDiag(
            event: "media_attached",
            extra: "path: direct_smb | networkCaching: \(networkCaching) | smbCaching: \(smbCaching) | fileCaching: \(smbCaching) | hwDecode: videotoolbox | parse: network_timeout_10000 | startPosition: \(startPositionSeconds) | startupRetry: \(directSMBStartupRetryCount)"
        )
        if isDrawableReady {
            playIfReady(trigger: "direct_smb_ready")
        }
    }

    private func scheduleDirectSMBStartupTimelineWatchdog(delaySeconds: Double, replacingExisting: Bool = false) {
        guard startupPlaybackPath == .directSMB,
              currentStartupStartPositionSeconds > 0,
              replacingExisting || startupTimelineWatchdogTask == nil else { return }

        if replacingExisting {
            startupTimelineWatchdogTask?.cancel()
            startupTimelineWatchdogTask = nil
        }

        startupTimelineWatchdogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delaySeconds))
            guard !Task.isCancelled else { return }
            self?.retryDirectSMBStartupIfNeeded()
        }
    }

    private func retryDirectSMBStartupIfNeeded() {
        startupTimelineWatchdogTask = nil
        guard startupPlaybackPath == .directSMB,
              currentStartupStartPositionSeconds > 0,
              !hasObservedPlayableTimeline,
              directSMBStartupRetryCount < 1,
              !isTearingDownPlayback else { return }

        guard let url = buildSMBURL() else {
            print("[VideoPlayer] direct SMB startup retry skipped (url build failed) | playerID: \(playerID) | file: \(item.name)")
            return
        }

        directSMBStartupRetryCount += 1
        let retryStartPosition = max(0, currentStartupStartPositionSeconds - 10)
        print("[VideoPlayer] retry direct SMB startup before timeline | originalStart: \(currentStartupStartPositionSeconds)s | retryStart: \(retryStartPosition)s | playerID: \(playerID) | file: \(item.name)")
        logStartupDiag(
            event: "direct_smb_startup_retry",
            extra: "originalStart: \(currentStartupStartPositionSeconds) | retryStart: \(retryStartPosition) | reason: timeline_not_ready"
        )

        hasEverStartedPlaying = false
        startupDidLogPlaying = false
        playRequestedAt = 0
        currentPositionSeconds = retryStartPosition
        durationSeconds = 0
        player.stop()
        player.media?.delegate = nil
        player.media = nil
        attachDirectSMBMedia(url: url, startPositionSeconds: retryStartPosition)
    }

    private func prepareSMBStreamMedia(startPositionSeconds: Double) async {
        do {
            let credential = try smbClientManager.loadCredential(for: connection)
            let shareName = credential.shareName == "/" ? "" : credential.shareName
            let client = try smbClientManager.makeDedicatedClient(for: connection)
            try await client.connectShare(name: shareName)

            let resolvedPath = await resolveSMBStreamPath(client: client, path: item.path)
            let fileSize = try await resolveSMBStreamFileSize(client: client, path: resolvedPath)
            let stream = SMBRangeInputStream(
                client: client,
                path: resolvedPath,
                fileSize: fileSize,
                ownerID: playerID,
                fileName: item.name
            )

            if Task.isCancelled {
                stream.close()
                try? await client.disconnectShare()
                return
            }

            await MainActor.run {
                self.attachSMBStreamMedia(
                    stream: stream,
                    client: client,
                    resolvedPath: resolvedPath,
                    fileSize: fileSize,
                    startPositionSeconds: startPositionSeconds
                )
            }
        } catch {
            await MainActor.run {
                self.errorMessage = "メディアストリームの準備に失敗しました"
                print("[VideoPlayer] SMB stream setup failed | playerID: \(self.playerID) | file: \(self.item.name) | error: \(error)")
            }
        }
    }

    private func attachSMBStreamMedia(
        stream: SMBRangeInputStream,
        client: SMB2Manager,
        resolvedPath: String,
        fileSize: UInt64,
        startPositionSeconds: Double
    ) {
        streamInput?.close()
        let oldClient = streamClient
        Task { try? await oldClient?.disconnectShare() }

        streamInput = stream
        streamClient = client

        let inputCaching = VideoPlayerCachingPolicy.directSMB(fileSize: Int64(fileSize)).inputCachingMilliseconds
        print("[VideoPlayer] Using SMB stream | playerID: \(playerID) | file: \(item.name) | path: \(resolvedPath) | size: \(fileSize)")
        let media = VLCMedia(stream: stream)
        media.delegate = self
        media.addOption(":file-caching=\(inputCaching)")
        media.addOption(":input-fast-seek")
        if startPositionSeconds > 0 {
            media.addOption(":start-time=\(Int(startPositionSeconds))")
        }
        media.parse(options: .parseNetwork, timeout: 10000)
        player.media = media
        mediaAttachedAt = CFAbsoluteTimeGetCurrent()
        logStartupDiag(
            event: "media_attached",
            extra: "path: smb_stream | fileCaching: \(inputCaching) | size: \(fileSize) | parse: network_timeout_10000"
        )
        if isDrawableReady {
            playIfReady(trigger: "smb_stream_ready")
        }
    }

    private func resolveSMBStreamPath(client: SMB2Manager, path: String) async -> String {
        let original = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let normalized = original.precomposedStringWithCanonicalMapping
        guard normalized != original else { return normalized }

        if await smbStreamPathExists(client: client, path: normalized) {
            print("[VideoPlayer] SMB stream resolved NFC path | playerID: \(playerID) | file: \(item.name)")
            return normalized
        }
        if await smbStreamPathExists(client: client, path: original) {
            print("[VideoPlayer] SMB stream resolved original path | playerID: \(playerID) | file: \(item.name)")
            return original
        }
        print("[VideoPlayer] SMB stream path not confirmed; using NFC | playerID: \(playerID) | file: \(item.name)")
        return normalized
    }

    private func smbStreamPathExists(client: SMB2Manager, path: String) async -> Bool {
        await withCheckedContinuation { cont in
            client.attributesOfItem(atPath: path) { result in
                switch result {
                case .success:
                    cont.resume(returning: true)
                case .failure:
                    cont.resume(returning: false)
                }
            }
        }
    }

    private func resolveSMBStreamFileSize(client: SMB2Manager, path: String) async throws -> UInt64 {
        if let size = item.size, size > 0 {
            return UInt64(size)
        }
        let attrs = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[URLResourceKey: any Sendable], Error>) in
            client.attributesOfItem(atPath: path) { result in
                cont.resume(with: result)
            }
        }
        if let int64Size = attrs[.fileSizeKey] as? Int64, int64Size > 0 {
            return UInt64(int64Size)
        }
        return 0
    }
#endif

    private func setupMediaDirect(startPositionSeconds: Double) {
        guard let url = buildSMBURL() else {
            errorMessage = "メディアURLの構築に失敗しました"
            print("[VideoPlayer] Failed to build SMB URL for: \(item.path)")
            return
        }
        let sanitizedURL = sanitizeURL(url)
        print("[VideoPlayer] Setting up media (direct): \(sanitizedURL)")
        print("[VideoPlayer] File name: \(item.name), path: \(item.path), playerID: \(playerID)")
        let media = VLCMedia(url: url)
        media.delegate = self
        if startPositionSeconds > 0 {
            media.addOptions(["start-time": Int(startPositionSeconds)])
        }
        media.parse(options: .parseNetwork, timeout: 10000)
        player.media = media
        mediaAttachedAt = CFAbsoluteTimeGetCurrent()
        logStartupDiag(event: "media_attached")
        print("[VideoPlayer] media attached | playerID: \(playerID) | url: \(sanitizedURL) | file: \(item.name)")
    }

    private func sanitizeURL(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if components?.password != nil { components?.password = "****" }
        return components?.url?.absoluteString ?? url.absoluteString
    }

    private func buildSMBURL() -> URL? {
        guard let credential = try? smbClientManager.loadCredential(for: connection),
              let host = connection.host else { return nil }
        var components = URLComponents()
        components.scheme = "smb"
        if !credential.username.isEmpty {
            components.user = credential.username
        }
        if !credential.password.isEmpty {
            components.password = credential.password
        }
        components.host = host
        if let port = connection.port, port != 445 {
            components.port = port
        }
        let shareName = (credential.shareName.isEmpty || credential.shareName == "/") ? "" : credential.shareName
        let share = shareName.isEmpty ? "" : "/\(shareName)"
        // SMB 直再生でも NFD/NFC の不一致でパス解決に失敗しないようにする
        components.path = "\(share)\(item.path)".precomposedStringWithCanonicalMapping
        return components.url
    }

    /// AVPlayer + ResourceLoader で再生する形式かどうか。MP4 系は AVPlayer、その他は VLC に委ねる。
    private static func isAVPlayerEligible(_ item: DirectoryItem) -> Bool {
        let ext = (item.name as NSString).pathExtension.lowercased()
        return ["mp4", "m4v", "mov"].contains(ext)
    }

    private static func avContentType(for item: DirectoryItem) -> String {
        switch (item.name as NSString).pathExtension.lowercased() {
        case "mov":
            return AVFileType.mov.rawValue
        case "m4v":
            return "com.apple.m4v-video"
        default:
            return AVFileType.mp4.rawValue
        }
    }

    private func resetStartupDiagnostics() {
        startupFallbackTask?.cancel()
        startupFallbackTask = nil
        startupTimelineWatchdogTask?.cancel()
        startupTimelineWatchdogTask = nil
        startupBeganAt = CFAbsoluteTimeGetCurrent()
        proxyReadyAt = 0
        mediaAttachedAt = 0
        playRequestedAt = 0
        startupDidLogPlaying = false
        startupPlaybackPath = nil
        didFallbackToProxy = false
        currentStartupStartPositionSeconds = 0
        directSMBStartupRetryCount = 0
        isInteractiveSeeking = false
        isDrawableReady = false
        interactiveSeekPreviewTask?.cancel()
        interactiveSeekPreviewTask = nil
        interactiveSeekDiagnosticsFinalizeTask?.cancel()
        interactiveSeekDiagnosticsFinalizeTask = nil
        interactiveSeekDiagnostics = nil
        pendingInteractiveSeekSeconds = nil
        lastInteractiveSeekPreviewSeconds = nil
        lastObservedPlaybackTimeMs = nil
        lastPlaybackInterruptionLog = nil
        hasObservedPlayableTimeline = false
        didLogStartupBufferingBeforeTimeline = false
        didRecordPlayerError = false
    }

    private func logStartupDiag(event: String, extra: String? = nil) {
        let now = CFAbsoluteTimeGetCurrent()
        let totalMs = startupBeganAt > 0 ? Int((now - startupBeganAt) * 1000) : -1
        let proxyMs = proxyReadyAt > 0 ? Int((proxyReadyAt - startupBeganAt) * 1000) : -1
        let attachMs = mediaAttachedAt > 0 ? Int((mediaAttachedAt - startupBeganAt) * 1000) : -1
        let playMs = playRequestedAt > 0 ? Int((playRequestedAt - startupBeganAt) * 1000) : -1
        var line = "[StartupDiag] source: VideoPlayer | playerID: \(playerID) | file: \(item.name) | event: \(event) | totalMs: \(totalMs) | proxyReadyMs: \(proxyMs) | mediaAttachedMs: \(attachMs) | playRequestedMs: \(playMs)"
        if let extra {
            line += " | \(extra)"
        }
        print(line)
    }

}

// MARK: - VLCMediaPlayerDelegate

extension VideoPlayerViewModel: VLCMediaPlayerDelegate {

    func mediaPlayerStateChanged(_ aNotification: Notification?) {
        let state = player.state
        isPlaying = player.isPlaying

        let stateLabel: String
        switch state {
        case .opening:    stateLabel = "opening"
        case .buffering:  stateLabel = "buffering"
        case .playing:    stateLabel = "playing"
        case .paused:     stateLabel = "paused"
        case .stopped:    stateLabel = "stopped"
        case .ended:      stateLabel = "ended"
        case .error:      stateLabel = "error"
        default:          stateLabel = "unknown(\(state.rawValue))"
        }
        print("[VideoPlayer] State changed: \(stateLabel) | playerID: \(playerID) | file: \(item.name)")

        switch state {
        case .opening, .buffering:
            isBuffering = true
            if state == .buffering {
                markInteractiveSeekBuffering()
            }
        case .playing, .paused, .stopped, .ended, .error:
            isBuffering = false
        default:
            break
        }

        if state == .playing, !hasEverStartedPlaying {
            hasEverStartedPlaying = true
            isBuffering = false
            startupFallbackTask?.cancel()
            startupFallbackTask = nil
            if !startupDidLogPlaying {
                startupDidLogPlaying = true
                logStartupDiag(event: "first_playing")
            }
#if !targetEnvironment(simulator)
            scheduleDirectSMBStartupTimelineWatchdog(delaySeconds: 3)
#endif
        }

        if state == .error {
            guard !isTearingDownPlayback else {
                print("[VideoPlayer] ignored player error during teardown | playerID: \(playerID) | file: \(item.name)")
                return
            }
            let parsedStatus = player.media.map { parsedStatusLabel($0.parsedStatus) } ?? "no_media"
            let trackCount = player.media?.tracksInformation.count ?? 0
            errorMessage = "再生エラーが発生しました"
            recordPlayerErrorIfNeeded(parsedStatus: parsedStatus, trackCount: trackCount)
            print("[VideoPlayer] error context | parsedStatus: \(parsedStatus) | trackCount: \(trackCount) | playerID: \(playerID) | file: \(item.name)")
            logMediaDetails()
        }

        if hasEverStartedPlaying {
            switch state {
            case .buffering, .paused, .stopped, .ended, .error:
                logPlaybackInterruptionIfNeeded(stateLabel: stateLabel)
            default:
                break
            }
        }
    }

    func mediaPlayerTimeChanged(_ aNotification: Notification?) {
        let ms = player.time.intValue
        let previousMs = lastObservedPlaybackTimeMs
        lastObservedPlaybackTimeMs = ms
        currentPositionSeconds = Double(ms) / 1000.0
        recordInteractiveSeekObservation(seconds: currentPositionSeconds)

        if let previousMs,
           ms > previousMs,
           !isInteractiveSeeking,
           (player.state == .playing || player.isPlaying) {
            isBuffering = false
        }

        if let lengthMs = player.media?.length.intValue, lengthMs > 0 {
            durationSeconds = Double(lengthMs) / 1000.0
        }

        if ms > 0 || durationSeconds > 0 {
            hasObservedPlayableTimeline = true
            startupTimelineWatchdogTask?.cancel()
            startupTimelineWatchdogTask = nil
        }
    }

    private func logMediaDetails() {
        guard let media = player.media else {
            print("[VideoPlayer] No media attached to player | playerID: \(playerID)")
            return
        }
        print("[VideoPlayer] Media parsedStatus: \(parsedStatusLabel(media.parsedStatus)) | playerID: \(playerID)")
        print("[VideoPlayer] Media length: \(media.length.intValue) ms | playerID: \(playerID)")
        let tracks = media.tracksInformation
        print("[VideoPlayer] Track count: \(tracks.count) | playerID: \(playerID)")
        for (i, track) in tracks.enumerated() {
            print("[VideoPlayer]   track[\(i)] | playerID: \(playerID): \(track)")
        }
    }

    private func logPlaybackInterruptionIfNeeded(stateLabel: String) {
        if stateLabel == "buffering",
           !hasObservedPlayableTimeline,
           lastObservedPlaybackTimeMs == nil,
           durationSeconds == 0 {
            if !didLogStartupBufferingBeforeTimeline {
                didLogStartupBufferingBeforeTimeline = true
                print("[VideoPlayer] startup buffering before timeline ready | playerID: \(playerID) | file: \(item.name)")
#if !targetEnvironment(simulator)
                scheduleDirectSMBStartupTimelineWatchdog(delaySeconds: 1, replacingExisting: true)
#endif
            }
            return
        }

        let positionSeconds = Int(currentPositionSeconds.rounded())
        let durationSeconds = Int(self.durationSeconds.rounded())
        let key = "\(stateLabel)#\(positionSeconds)"
        guard lastPlaybackInterruptionLog != key else { return }
        lastPlaybackInterruptionLog = key

        let parsedStatus = player.media.map { parsedStatusLabel($0.parsedStatus) } ?? "no_media"
        let trackCount = player.media?.tracksInformation.count ?? 0
        let line = "[VideoPlayer] playback interruption | state: \(stateLabel) | positionSeconds: \(positionSeconds) | durationSeconds: \(durationSeconds) | isPlaying: \(player.isPlaying) | isBuffering: \(isBuffering) | interactiveSeeking: \(isInteractiveSeeking) | lastObservedTimeMs: \(lastObservedPlaybackTimeMs ?? -1) | parsedStatus: \(parsedStatus) | trackCount: \(trackCount) | playerID: \(playerID) | file: \(item.name)"
        let telemetryLine = "[VideoPlayer] playback interruption | state: \(stateLabel) | positionSeconds: \(positionSeconds) | durationSeconds: \(durationSeconds) | isPlaying: \(player.isPlaying) | isBuffering: \(isBuffering) | interactiveSeeking: \(isInteractiveSeeking) | lastObservedTimeMs: \(lastObservedPlaybackTimeMs ?? -1) | parsedStatus: \(parsedStatus) | trackCount: \(trackCount) | playerID: \(playerID)"
        print(line)
        FirebaseSupport.logCrashlytics(telemetryLine)
    }

    private func recordPlayerErrorIfNeeded(parsedStatus: String, trackCount: Int) {
        guard !didRecordPlayerError else {
            print("[VideoPlayer] skipped duplicate player error record | playerID: \(playerID) | file: \(item.name)")
            return
        }
        didRecordPlayerError = true

        FirebaseSupport.logEvent("vp_player_error")
        let nsErr = NSError(domain: "VLCPlayer", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "VLC player error",
            "player_id": playerID,
            "parsed_status": parsedStatus,
            "track_count": trackCount,
            "position_seconds": currentPositionSeconds,
            "duration_seconds": durationSeconds,
            "has_started_playing": hasEverStartedPlaying,
            "startup_path": startupPlaybackPathLabel,
            "is_tearing_down": isTearingDownPlayback
        ])
        FirebaseSupport.recordCrashlytics(error: nsErr)
    }

    private var startupPlaybackPathLabel: String {
        switch startupPlaybackPath {
        case .directSMB:
            return "direct_smb"
        case .smbStream:
            return "smb_stream"
        case .httpProxy:
            return "http_proxy"
        case .avPlayer:
            return "av_player"
        case nil:
            return "none"
        }
    }

    private func parsedStatusLabel(_ status: VLCMediaParsedStatus) -> String {
        // VLCMediaParsedStatusInit=0, Skipped=1, Failed=2, Timeout=3, Done=4
        switch status.rawValue {
        case 0:  return "init"
        case 1:  return "skipped"
        case 2:  return "failed"
        case 3:  return "timeout"
        case 4:  return "done"
        default: return "unknown(\(status.rawValue))"
        }
    }
}

// MARK: - VLCMediaDelegate

extension VideoPlayerViewModel: VLCMediaDelegate {

    func mediaDidFinishParsing(_ aMedia: VLCMedia) {
        let statusLabel = parsedStatusLabel(aMedia.parsedStatus)
        print("[VideoPlayer] mediaDidFinishParsing: \(statusLabel) | playerID: \(playerID) | file: \(item.name)")
        let tracks = aMedia.tracksInformation
        print("[VideoPlayer] Track count after parse: \(tracks.count) | playerID: \(playerID)")
        for (i, track) in tracks.enumerated() {
            print("[VideoPlayer]   track[\(i)] | playerID: \(playerID): \(track)")
        }
    }
}

#if !targetEnvironment(simulator)
private final class SMBRangeInputStream: InputStream, @unchecked Sendable {

    private let client: SMB2Manager
    private let path: String
    private let fileSize: UInt64
    private let ownerID: String
    private let fileName: String
    private let maxChunkSize = 2 * 1024 * 1024
    private let lock = NSLock()

    private var offset: UInt64 = 0
    private var status: Stream.Status = .notOpen
    private var error: Error?

    init(client: SMB2Manager, path: String, fileSize: UInt64, ownerID: String, fileName: String) {
        self.client = client
        self.path = path
        self.fileSize = fileSize
        self.ownerID = ownerID
        self.fileName = fileName
        super.init(data: Data())
    }

    override var streamStatus: Stream.Status {
        lock.lock()
        defer { lock.unlock() }
        return status
    }

    override var streamError: Error? {
        lock.lock()
        defer { lock.unlock() }
        return error
    }

    override var hasBytesAvailable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return status == .open && (fileSize == 0 || offset < fileSize)
    }

    override func open() {
        lock.lock()
        if status == .notOpen {
            status = .open
        }
        lock.unlock()
        print("[SMBRangeInputStream] open | playerID: \(ownerID) | file: \(fileName) | size: \(fileSize)")
    }

    override func close() {
        lock.lock()
        status = .closed
        lock.unlock()
        print("[SMBRangeInputStream] close | playerID: \(ownerID) | file: \(fileName)")
    }

    override func read(_ buffer: UnsafeMutablePointer<UInt8>, maxLength len: Int) -> Int {
        guard len > 0 else { return 0 }

        let readOffset: UInt64
        let readLength: Int
        lock.lock()
        guard status == .open else {
            lock.unlock()
            return 0
        }
        if fileSize > 0, offset >= fileSize {
            status = .atEnd
            lock.unlock()
            return 0
        }
        readOffset = offset
        let remaining = fileSize > 0 ? Int(min(UInt64(Int.max), fileSize - offset)) : len
        readLength = min(len, maxChunkSize, remaining)
        lock.unlock()

        let upperBound = readOffset + UInt64(readLength) - 1
        let result = readData(range: readOffset...upperBound)
        switch result {
        case .success(let data):
            guard !data.isEmpty else {
                lock.lock()
                status = .atEnd
                lock.unlock()
                return 0
            }
            data.copyBytes(to: buffer, count: data.count)
            lock.lock()
            offset = readOffset + UInt64(data.count)
            if fileSize > 0, offset >= fileSize {
                status = .atEnd
            }
            lock.unlock()
            return data.count
        case .failure(let readError):
            lock.lock()
            error = readError
            status = .error
            lock.unlock()
            print("[SMBRangeInputStream] read error | playerID: \(ownerID) | file: \(fileName) | offset: \(readOffset) | length: \(readLength) | error: \(readError)")
            return -1
        }
    }

    override func getBuffer(
        _ buffer: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>,
        length len: UnsafeMutablePointer<Int>
    ) -> Bool {
        buffer.pointee = nil
        len.pointee = 0
        return false
    }

    override func property(forKey key: Stream.PropertyKey) -> Any? {
        guard key == .fileCurrentOffsetKey else {
            return super.property(forKey: key)
        }
        lock.lock()
        defer { lock.unlock() }
        return NSNumber(value: offset)
    }

    override func setProperty(_ property: Any?, forKey key: Stream.PropertyKey) -> Bool {
        guard key == .fileCurrentOffsetKey else {
            return super.setProperty(property, forKey: key)
        }
        guard let requestedOffset = offsetValue(from: property) else {
            return false
        }
        lock.lock()
        offset = fileSize > 0 ? min(requestedOffset, fileSize) : requestedOffset
        if status == .atEnd, fileSize == 0 || offset < fileSize {
            status = .open
        }
        lock.unlock()
        print("[SMBRangeInputStream] seek | playerID: \(ownerID) | file: \(fileName) | offset: \(requestedOffset)")
        return true
    }

    override func schedule(in aRunLoop: RunLoop, forMode mode: RunLoop.Mode) {}

    override func remove(from aRunLoop: RunLoop, forMode mode: RunLoop.Mode) {}

    private func readData(range: ClosedRange<UInt64>) -> Result<Data, Error> {
        let semaphore = DispatchSemaphore(value: 0)
        let box = SMBRangeReadResultBox()
        client.contents(atPath: path, range: range, progress: nil) {
            box.set($0)
            semaphore.signal()
        }
        semaphore.wait()
        return box.value ?? .success(Data())
    }

    private func offsetValue(from property: Any?) -> UInt64? {
        if let number = property as? NSNumber {
            return number.uint64Value
        }
        if let int = property as? Int {
            return UInt64(max(0, int))
        }
        if let int64 = property as? Int64 {
            return UInt64(max(0, int64))
        }
        if let uint64 = property as? UInt64 {
            return uint64
        }
        return nil
    }
}

private final class SMBRangeReadResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Data, Error>?

    var value: Result<Data, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }

    func set(_ value: Result<Data, Error>) {
        lock.lock()
        result = value
        lock.unlock()
    }
}
#endif
