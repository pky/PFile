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
    /// direct SMB でもドラッグ中に映像を追従させる。seek は常に 1 件に抑えるので連続 seek で詰まらない。
    static let directSMBPreviewEnabled = true
    /// ドラッグ入力を主プレイヤーへ渡す最小間隔。初回は即時。
    static let previewMinimumInterval: TimeInterval = 0.1
}

/// 再生エンジンの振り分け方針。
/// AVPlayer 経路は特定の HEVC MP4 で表示がカクつき（iOS 側の統計では検出できない）、
/// VLC 経路は NAS 上の重い動画でも軽く再生できたため、MP4 系も VLC に委ねる。
/// AVPlayer 経路の実装は残しており、この定数を true に戻せば再び有効になる。
struct VideoPlayerEnginePolicy {
    static let avPlayerEnabledForMP4Family = false
    private static let mp4FamilyExtensions: Set<String> = ["mp4", "m4v", "mov"]

    static func usesAVPlayer(fileName: String) -> Bool {
        guard avPlayerEnabledForMP4Family else { return false }
        let ext = (fileName as NSString).pathExtension.lowercased()
        return mp4FamilyExtensions.contains(ext)
    }
}

@Observable
final class VideoPlayerViewModel: NSObject {

    private enum StartupPlaybackPath {
        case directSMB
        case smbStream
        case httpProxy
        case avPlayer
    }

    private var vlcIntendsToPlay = true
    private var pendingVLCSeekSeconds: Double?
    var isPlaying = false
    var isMuted = false
    var currentPositionSeconds: Double = 0
    var durationSeconds: Double = 0
    var resolutionText: String?
    var errorMessage: String?

    // MP4 / MOV は AVPlayer 経路で再生する。true のとき View は AVPlayerLayer を描画する。
    private(set) var usesAVPlayer = false
    private(set) var avPlayer: AVPlayer?
    private var scrubPreviewTask: Task<Void, Never>?
    private var scrubPreviewTaskID: UUID?
    private var scrubPreviewState = VideoScrubPreviewState(
        minimumInterval: VideoPlayerInteractiveSeekPolicy.previewMinimumInterval
    )
    private var scrubPreviewDiagnostics: ScrubPreviewDiagnostics?
    // VLC 経路のドラッグ追従。seek は常に 1 件だけ実行し、完了は時刻通知か打ち切りで判定する。
    private var vlcScrubSeekState = VideoSeekState()
    private var vlcScrubSeekIssuedAt: TimeInterval = 0
    private var vlcScrubTimeoutTask: Task<Void, Never>?

    private struct ScrubPreviewDiagnostics {
        let startedAt: TimeInterval
        var inputCount = 0
        var requestCount = 0
        var completedCount = 0
        var failureCount = 0
        var totalExecutionMs = 0
        var maxExecutionMs = 0
        var totalSubmitWaitMs = 0
        var maxSubmitWaitMs = 0
        var firstCompletedMs: Int?
        var lastDeltaSeconds: Double = -1
    }
    // 一瞬の buffering でスピナーを点滅させないためのデバウンス。
    private var avBufferingDebounceTask: Task<Void, Never>?
    // シーク操作の開始時に再生中だったか。指を離したときの再開判定に使う。
    private var wasPlayingBeforeInteractiveSeek = false
    // AVPlayer 経路でユーザーが再生を望んでいるかの意図。buffering で揺れる isPlaying と違い、
    // 明示的な再生/一時停止だけで変わる。連続シーク中の再開判定をこの値で安定させる。
    private var avIntendsToPlay: Bool {
#if !targetEnvironment(simulator)
        avController?.intendsToPlay ?? !hasEverStartedPlaying
#else
        false
#endif
    }

    private(set) var isBuffering = true
    private var hasEverStartedPlaying = false

    let connection: RemoteConnection
    let item: DirectoryItem

    let player = VLCMediaPlayer()
    let playerID: String
    let mediaID: String

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
    private var didFallbackFromAVPlayer = false
    private var startupFallbackTask: Task<Void, Never>?
    private var startupTimelineWatchdogTask: Task<Void, Never>?
    private var currentStartupStartPositionSeconds: Double = 0
    private var directSMBStartupRetryCount = 0
    private var isInteractiveSeeking = false
    private var pendingInteractiveSeekSeconds: Double?
    private var interactiveSeekDiagnostics: InteractiveSeekDiagnostics?
    private var interactiveSeekDiagnosticsFinalizeTask: Task<Void, Never>?
    private var lastObservedPlaybackTimeMs: Int32?
    private var lastPlaybackInterruptionLog: String?
    private var isDrawableReady = false
    private var hasObservedPlayableTimeline = false
    private var didLogStartupBufferingBeforeTimeline = false
    private var didRecordPlayerError = false
    private var startupInterval: MediaDiagnostics.Interval?
    private var seekInterval: MediaDiagnostics.Interval?

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
        var shouldResume = false

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
        self.mediaID = MediaDiagnostics.mediaID(
            sourceID: "remote:\(connection.id.uuidString)",
            path: item.path
        )
        self.playbackHistoryService = playbackHistoryService
        self.smbClientManager = smbClientManager
        super.init()
        player.delegate = self
        VideoPlayerDiagnostics.playerDidInit(playerID: playerID)
        MediaDiagnostics.playback("event=init mediaID=\(mediaID) playerID=\(playerID)")
        setupMedia(startPositionSeconds: startPositionSeconds)
    }

    deinit {
        MediaDiagnostics.playback("event=deinit_begin mediaID=\(mediaID) playerID=\(playerID)")
        tearDownPlayback(trigger: "deinit")
        VideoPlayerDiagnostics.playerDidDeinit(playerID: playerID)
        MediaDiagnostics.playback("event=deinit_end mediaID=\(mediaID) playerID=\(playerID)")
    }

    func cancelSetup() {
        if setupTask != nil {
            FirebaseSupport.logCrashlytics("[VideoPlayer] cancelSetup | playerID: \(playerID)")
            FirebaseSupport.logEvent("vp_setup_cancelled")
            MediaDiagnostics.playback("event=setup_cancelled mediaID=\(mediaID) playerID=\(playerID)")
        }
        startupFallbackTask?.cancel()
        startupFallbackTask = nil
        startupTimelineWatchdogTask?.cancel()
        startupTimelineWatchdogTask = nil
        interactiveSeekDiagnosticsFinalizeTask?.cancel()
        if interactiveSeekDiagnostics != nil { logInteractiveSeekDiagnosticsSummary(result: "cancelled") }
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
        Task {
            try? await SMB2OperationGate.runAsync {
                try await client?.disconnectShare()
            }
        }
        tearDownAVPlayer()
#endif
    }

    func togglePlayPause() {
#if !targetEnvironment(simulator)
        if usesAVPlayer {
            // toggle 前の状態から再生意図を確定する。buffering 中の isPlaying には依存しない。
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
        guard let target = VideoSeekState.clamped(seconds, duration: durationSeconds) else { return }
        // フォールバック準備中の操作も、新しいmediaの開始位置へ引き継ぐ。
        if player.media == nil {
            pendingVLCSeekSeconds = target
            return
        }
        let ms = Int32(target * 1000)
        player.time = VLCTime(int: ms)
    }

    func updateInteractiveSeek(to seconds: Double) {
        guard let clamped = VideoSeekState.clamped(seconds, duration: durationSeconds) else { return }
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
            if scrubPreviewState.sessionID == nil {
                scrubPreviewState.beginSession()
                scrubPreviewDiagnostics = ScrubPreviewDiagnostics(startedAt: ProcessInfo.processInfo.systemUptime)
            }
            scrubPreviewDiagnostics?.inputCount += 1
            scrubPreviewState.update(seconds: clamped, duration: durationSeconds,
                                     now: ProcessInfo.processInfo.systemUptime)
            scheduleScrubPreview()
            return
        }
#endif

        guard shouldPreviewInteractiveSeekDuringDrag else { return }
        if scrubPreviewState.sessionID == nil {
            scrubPreviewState.beginSession()
            scrubPreviewDiagnostics = ScrubPreviewDiagnostics(startedAt: ProcessInfo.processInfo.systemUptime)
        }
        scrubPreviewDiagnostics?.inputCount += 1
        scrubPreviewState.update(seconds: clamped, duration: durationSeconds,
                                 now: ProcessInfo.processInfo.systemUptime)
        scheduleVLCScrubPreview()
    }

    func endInteractiveSeek() {
        guard isInteractiveSeeking else { return }
        stopScrubPreview()
        if let pendingInteractiveSeekSeconds {
            recordInteractiveSeekRequest(seconds: pendingInteractiveSeekSeconds)
            interactiveSeekDiagnostics?.finalRequestedSeconds = pendingInteractiveSeekSeconds
            seek(to: pendingInteractiveSeekSeconds)
        }
#if !targetEnvironment(simulator)
        interactiveSeekDiagnostics?.shouldResume = usesAVPlayer ? avIntendsToPlay : wasPlayingBeforeInteractiveSeek
#else
        interactiveSeekDiagnostics?.shouldResume = wasPlayingBeforeInteractiveSeek
#endif
        isInteractiveSeeking = false
        pendingInteractiveSeekSeconds = nil
#if !targetEnvironment(simulator)
        if usesAVPlayer {
            avController?.endInteractiveSeek()
        } else if wasPlayingBeforeInteractiveSeek {
            resumeAfterInteractiveSeek()
        }
#else
        if wasPlayingBeforeInteractiveSeek { resumeAfterInteractiveSeek() }
#endif
        wasPlayingBeforeInteractiveSeek = false
        finalizeInteractiveSeekDiagnosticsAfterDelay()
    }

    private func pauseForInteractiveSeek() {
#if !targetEnvironment(simulator)
        if usesAVPlayer {
            avController?.beginInteractiveSeek()
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

    /// VLC 経路のドラッグ追従。初回は即時、継続入力を約100ms間隔に集約し、seek は常に 1 件だけ実行する。
    private func scheduleVLCScrubPreview() {
        guard scrubPreviewTask == nil, let sessionID = scrubPreviewState.sessionID,
              !usesAVPlayer, isInteractiveSeeking, !isTearingDownPlayback,
              let delay = scrubPreviewState.delay(now: ProcessInfo.processInfo.systemUptime) else { return }
        if delay <= 0 {
            applyVLCScrubPreviewRequest(sessionID: sessionID)
            return
        }
        let taskID = UUID()
        scrubPreviewTaskID = taskID
        scrubPreviewTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(ceil(delay * 1000))))
            guard let self else { return }
            defer {
                if self.scrubPreviewTaskID == taskID {
                    self.scrubPreviewTask = nil
                    self.scrubPreviewTaskID = nil
                }
            }
            guard !Task.isCancelled, self.scrubPreviewTaskID == taskID else { return }
            self.applyVLCScrubPreviewRequest(sessionID: sessionID)
        }
    }

    private func applyVLCScrubPreviewRequest(sessionID: UUID) {
        guard isInteractiveSeeking, !isTearingDownPlayback, !usesAVPlayer,
              scrubPreviewState.sessionID == sessionID, player.media != nil,
              let request = scrubPreviewState.takeRequest(now: ProcessInfo.processInfo.systemUptime) else { return }
        recordScrubPreviewSubmission(request)
        recordInteractiveSeekRequest(seconds: request.seconds)
        // 実行中なら最新目標だけ保持し、完了後に 1 件だけ出す。
        if let seekRequest = vlcScrubSeekState.request(seconds: request.seconds, duration: durationSeconds,
                                                       purpose: .scrubPreview, contextID: sessionID) {
            issueVLCScrubSeek(seekRequest)
        }
    }

    private func issueVLCScrubSeek(_ request: VideoSeekState.Request) {
        vlcScrubSeekIssuedAt = ProcessInfo.processInfo.systemUptime
        player.time = VLCTime(int: Int32(request.seconds * 1000))
        vlcScrubTimeoutTask?.cancel()
        vlcScrubTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(VLCSeekCompletionPolicy.timeoutSeconds))
            guard !Task.isCancelled, let self,
                  self.vlcScrubSeekState.inFlight?.id == request.id else { return }
            self.completeVLCScrubSeek(request, finished: false)
        }
    }

    /// VLC は seek 完了を通知しないので、時刻通知が目標近傍に届いたときに完了とみなす。
    private func observeVLCScrubSeekProgress(observedSeconds: Double) {
        guard let inFlight = vlcScrubSeekState.inFlight,
              VLCSeekCompletionPolicy.isCompleted(target: inFlight.seconds, observed: observedSeconds) else { return }
        completeVLCScrubSeek(inFlight, finished: true)
    }

    private func completeVLCScrubSeek(_ request: VideoSeekState.Request, finished: Bool) {
        vlcScrubTimeoutTask?.cancel()
        vlcScrubTimeoutTask = nil
        let executionMs = max(0, Int((ProcessInfo.processInfo.systemUptime - vlcScrubSeekIssuedAt) * 1000))
        recordScrubPreviewCompletion(requested: request.seconds, observed: currentPositionSeconds,
                                     finished: finished, executionMs: executionMs)
        guard let next = vlcScrubSeekState.complete(request) else { return }
        if isInteractiveSeeking, !isTearingDownPlayback, !usesAVPlayer {
            issueVLCScrubSeek(next)
        } else {
            vlcScrubSeekState.reset()
        }
    }

    private func stopVLCScrubSeek() {
        vlcScrubTimeoutTask?.cancel()
        vlcScrubTimeoutTask = nil
        vlcScrubSeekState.reset()
    }

    private func stopScrubPreview() {
        logScrubPreviewSummary()
        scrubPreviewState.endSession()
        scrubPreviewTask?.cancel()
        scrubPreviewTask = nil
        scrubPreviewTaskID = nil
        // VLC のプレビュー seek は指を離したときの確定 seek が上書きするので破棄する。
        // 主AVPlayerの実行中seekは取消さず、確定目的の要求へ完了後に引き継ぐ。
        stopVLCScrubSeek()
    }

    private func recordScrubPreviewSubmission(_ request: VideoScrubPreviewState.Request) {
        let waitMs = max(0, Int((ProcessInfo.processInfo.systemUptime - request.requestedAt) * 1000))
        scrubPreviewDiagnostics?.requestCount += 1
        scrubPreviewDiagnostics?.totalSubmitWaitMs += waitMs
        if let maximum = scrubPreviewDiagnostics?.maxSubmitWaitMs {
            scrubPreviewDiagnostics?.maxSubmitWaitMs = max(maximum, waitMs)
        }
    }

    private func recordScrubPreviewCompletion(requested: Double, observed: Double, finished: Bool, executionMs: Int) {
        scrubPreviewDiagnostics?.completedCount += 1
        if !finished { scrubPreviewDiagnostics?.failureCount += 1 }
        scrubPreviewDiagnostics?.totalExecutionMs += executionMs
        if let maximum = scrubPreviewDiagnostics?.maxExecutionMs {
            scrubPreviewDiagnostics?.maxExecutionMs = max(maximum, executionMs)
        }
        if scrubPreviewDiagnostics?.firstCompletedMs == nil,
           let startedAt = scrubPreviewDiagnostics?.startedAt {
            scrubPreviewDiagnostics?.firstCompletedMs = max(0, Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000))
        }
        scrubPreviewDiagnostics?.lastDeltaSeconds = abs(observed - requested)
    }

    private func logScrubPreviewSummary() {
        guard let diagnostics = scrubPreviewDiagnostics else { return }
        scrubPreviewDiagnostics = nil
#if !targetEnvironment(simulator)
        let playerSeeking = usesAVPlayer ? (avController?.isSeeking ?? false) : vlcScrubSeekState.inFlight != nil
#else
        let playerSeeking = vlcScrubSeekState.inFlight != nil
#endif
        let path = usesAVPlayer ? "avplayer_paused_seek" : "vlc_paused_seek"
        MediaDiagnostics.playback(
            "event=scrub_preview_summary mediaID=\(mediaID) playerID=\(playerID) path=\(path) inputs=\(diagnostics.inputCount) requests=\(diagnostics.requestCount) completed=\(diagnostics.completedCount) failures=\(diagnostics.failureCount) firstCompletedMs=\(diagnostics.firstCompletedMs ?? -1) totalExecutionMs=\(diagnostics.totalExecutionMs) maxExecutionMs=\(diagnostics.maxExecutionMs) totalSubmitWaitMs=\(diagnostics.totalSubmitWaitMs) maxSubmitWaitMs=\(diagnostics.maxSubmitWaitMs) lastDeltaSeconds=\(diagnostics.lastDeltaSeconds) seekInFlight=\(playerSeeking)"
        )
    }

#if !targetEnvironment(simulator)
    /// 初回は即時、継続入力を約100ms間隔に集約して主プレイヤーへ渡す。
    private func scheduleScrubPreview() {
        guard scrubPreviewTask == nil, let sessionID = scrubPreviewState.sessionID,
              let controller = avController, usesAVPlayer, isInteractiveSeeking,
              !isTearingDownPlayback,
              let delay = scrubPreviewState.delay(now: ProcessInfo.processInfo.systemUptime) else { return }
        if delay <= 0 {
            applyScrubPreviewRequest(sessionID: sessionID, controller: controller)
            return
        }
        let taskID = UUID()
        scrubPreviewTaskID = taskID
        scrubPreviewTask = Task { @MainActor [weak self, weak controller] in
            try? await Task.sleep(for: .milliseconds(Int(ceil(delay * 1000))))
            guard let self else { return }
            defer {
                if self.scrubPreviewTaskID == taskID {
                    self.scrubPreviewTask = nil
                    self.scrubPreviewTaskID = nil
                }
            }
            guard !Task.isCancelled, let controller,
                  self.scrubPreviewTaskID == taskID else { return }
            self.applyScrubPreviewRequest(sessionID: sessionID, controller: controller)
        }
    }

    private func applyScrubPreviewRequest(sessionID: UUID, controller: AVPlayerVideoController) {
        guard isInteractiveSeeking, !isTearingDownPlayback, avController === controller,
              scrubPreviewState.sessionID == sessionID,
              let request = scrubPreviewState.takeRequest(now: ProcessInfo.processInfo.systemUptime) else { return }
        recordScrubPreviewSubmission(request)
        recordInteractiveSeekRequest(seconds: request.seconds)
        controller.seekForScrubPreview(toSeconds: request.seconds, sessionID: request.sessionID)
    }
#endif

    private var shouldPreviewInteractiveSeekDuringDrag: Bool {
        switch startupPlaybackPath {
        case .directSMB:
            return VideoPlayerInteractiveSeekPolicy.directSMBPreviewEnabled
        case .avPlayer:
            // AVPlayer経路は専用の入力集約とpaused seekで扱う。
            return false
        case .smbStream, .httpProxy, nil:
            return true
        }
    }

    private func beginInteractiveSeekDiagnostics(startedSeconds: Double) {
        interactiveSeekDiagnosticsFinalizeTask?.cancel()
        interactiveSeekDiagnosticsFinalizeTask = nil
        if interactiveSeekDiagnostics != nil { logInteractiveSeekDiagnosticsSummary(result: "superseded") }
        interactiveSeekDiagnostics = InteractiveSeekDiagnostics(
            startedAt: CFAbsoluteTimeGetCurrent(),
            startedPlaybackSeconds: currentPositionSeconds,
            startedRequestSeconds: startedSeconds
        )
        seekInterval = MediaDiagnostics.begin("MediaSeek", mediaID: mediaID)
        MediaDiagnostics.playback(
            "event=seek_begin mediaID=\(mediaID) playerID=\(playerID) playbackSeconds=\(String(format: "%.2f", currentPositionSeconds)) requestSeconds=\(String(format: "%.2f", startedSeconds))"
        )
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
            MediaDiagnostics.playback(
                "event=seek_first_response mediaID=\(mediaID) playerID=\(playerID) responseMs=\(firstResponse.responseMs) deltaSeconds=\(String(format: "%.2f", firstResponse.deltaSeconds)) observedSeconds=\(String(format: "%.2f", seconds))"
            )
        }
        finishInteractiveSeekDiagnosticsIfReached()
    }

    private func finishInteractiveSeekDiagnosticsIfReached() {
        guard !isInteractiveSeeking, interactiveSeekDiagnosticsFinalizeTask != nil,
              let diagnostics = interactiveSeekDiagnostics,
              let target = diagnostics.finalRequestedSeconds,
              abs(currentPositionSeconds - target) <= 1.1,
              !diagnostics.shouldResume || isPlaying else { return }
        interactiveSeekDiagnosticsFinalizeTask?.cancel()
        logInteractiveSeekDiagnosticsSummary(result: "timeline_position")
    }

    private func markInteractiveSeekBuffering() {
        guard interactiveSeekDiagnostics != nil else { return }
        interactiveSeekDiagnostics?.bufferingDuringSeek = true
    }

    private func finalizeInteractiveSeekDiagnosticsAfterDelay() {
        interactiveSeekDiagnosticsFinalizeTask?.cancel()
        interactiveSeekDiagnosticsFinalizeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            self?.logInteractiveSeekDiagnosticsSummary(result: "timeout")
        }
        finishInteractiveSeekDiagnosticsIfReached()
    }

    private func logInteractiveSeekDiagnosticsSummary(result: String) {
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
        let line = "event=seek_summary result=\(result) observation=timeline mediaID=\(mediaID) playerID=\(playerID) dragMs=\(dragMs) seekRequests=\(diagnostics.requestCount) firstResponseMs=\(firstResponseMs) firstResponseDeltaSeconds=\(String(format: "%.2f", firstResponseDeltaSeconds)) latencyCount=\(diagnostics.latencyCount) avgLatencyMs=\(avgLatencyMs) maxLatencyMs=\(diagnostics.maxLatencyMs) bufferingDuringSeek=\(diagnostics.bufferingDuringSeek) finalRequestedSeconds=\(String(format: "%.2f", finalRequestedSeconds)) finalObservedSeconds=\(String(format: "%.2f", finalObservedSeconds)) finalDeltaSeconds=\(String(format: "%.2f", finalDeltaSeconds))"
        let telemetryLine = "[SeekDiag] summary | dragMs: \(dragMs) | seekRequests: \(diagnostics.requestCount) | firstResponseMs: \(firstResponseMs) | firstResponseDeltaSeconds: \(String(format: "%.2f", firstResponseDeltaSeconds)) | latencyCount: \(diagnostics.latencyCount) | avgLatencyMs: \(avgLatencyMs) | maxLatencyMs: \(diagnostics.maxLatencyMs) | bufferingDuringSeek: \(diagnostics.bufferingDuringSeek) | finalRequestedSeconds: \(String(format: "%.2f", finalRequestedSeconds)) | finalObservedSeconds: \(String(format: "%.2f", finalObservedSeconds)) | finalDeltaSeconds: \(String(format: "%.2f", finalDeltaSeconds)) | playerID: \(playerID)"
        MediaDiagnostics.playback(line)
        if let seekInterval {
            MediaDiagnostics.end(seekInterval, mediaID: mediaID, result: "\(result) delta=\(String(format: "%.2f", finalDeltaSeconds))")
            self.seekInterval = nil
        }
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
        vlcIntendsToPlay = true
        if isInteractiveSeeking { wasPlayingBeforeInteractiveSeek = true }
        guard player.media != nil else {
            MediaDiagnostics.playback("event=play_skipped mediaID=\(mediaID) playerID=\(playerID) trigger=\(trigger)")
            return
        }
        if playRequestedAt == 0 {
            playRequestedAt = CFAbsoluteTimeGetCurrent()
        }
        logStartupDiag(event: "play_requested", extra: "trigger: \(trigger)")
        MediaDiagnostics.playback("event=play mediaID=\(mediaID) playerID=\(playerID) trigger=\(trigger)")
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
        if vlcIntendsToPlay, !isInteractiveSeeking { playIfReady(trigger: "drawable_ready") }
    }

    func pausePlayback(trigger: String) {
        MediaDiagnostics.playback("event=pause mediaID=\(mediaID) playerID=\(playerID) trigger=\(trigger)")
#if !targetEnvironment(simulator)
        if usesAVPlayer {
            avController?.pause()
            return
        }
#endif
        vlcIntendsToPlay = false
        if isInteractiveSeeking { wasPlayingBeforeInteractiveSeek = false }
        player.pause()
    }

    func stopPlayback(trigger: String) {
        MediaDiagnostics.playback("event=stop mediaID=\(mediaID) playerID=\(playerID) trigger=\(trigger)")
#if !targetEnvironment(simulator)
        if usesAVPlayer {
            avController?.pause()
            return
        }
#endif
        vlcIntendsToPlay = false
        if isInteractiveSeeking { wasPlayingBeforeInteractiveSeek = false }
        player.stop()
    }

    func tearDownPlayback(trigger: String) {
        MediaDiagnostics.playback("event=teardown_begin mediaID=\(mediaID) playerID=\(playerID) trigger=\(trigger)")
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
        Task {
            try? await SMB2OperationGate.runAsync {
                try await client?.disconnectShare()
            }
        }
        tearDownAVPlayer()
#endif
        pendingVLCSeekSeconds = nil
        startupPlaybackPath = nil
        didFallbackToProxy = false
        didFallbackFromAVPlayer = false
        isInteractiveSeeking = false
        isDrawableReady = false
        currentStartupStartPositionSeconds = 0
        stopScrubPreview()
        interactiveSeekDiagnosticsFinalizeTask?.cancel()
        if interactiveSeekDiagnostics != nil { logInteractiveSeekDiagnosticsSummary(result: "cancelled") }
        interactiveSeekDiagnosticsFinalizeTask = nil
        interactiveSeekDiagnostics = nil
        pendingInteractiveSeekSeconds = nil
        hasObservedPlayableTimeline = false
        didLogStartupBufferingBeforeTimeline = false
        VideoPlayerDiagnostics.logMemory(event: "teardown_end_\(trigger)", playerID: playerID)
        MediaDiagnostics.playback("event=teardown_end mediaID=\(mediaID) playerID=\(playerID) trigger=\(trigger)")
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
        MediaDiagnostics.playback("event=setup_begin mediaID=\(mediaID) playerID=\(playerID) startSeconds=\(startPositionSeconds)")
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
            MediaDiagnostics.playback("event=url_build_failed mediaID=\(mediaID) playerID=\(playerID) route=direct_smb")
            return
        }
        attachDirectSMBMedia(url: url, startPositionSeconds: startPositionSeconds)
    }

    private func prepareAVPlayerMedia(startPositionSeconds: Double) async {
        do {
            let credential = try smbClientManager.loadCredential(for: connection)
            let shareName = credential.shareName == "/" ? "" : credential.shareName
            let client = try smbClientManager.makeDedicatedClient(for: connection)
            try await SMB2OperationGate.runAsync {
                try await client.connectShare(name: shareName)
            }

            let resolvedPath = await resolveSMBStreamPath(client: client, path: item.path)
            let fileSize = try await resolveSMBStreamFileSize(client: client, path: resolvedPath)

            if Task.isCancelled {
                try? await SMB2OperationGate.runAsync {
                    try await client.disconnectShare()
                }
                return
            }

            let dataSource = SMBByteRangeDataSource(
                client: client,
                path: resolvedPath,
                fileSize: fileSize,
                ownerID: playerID
            )

            await MainActor.run {
                guard !self.isTearingDownPlayback else {
                    Task {
                        try? await SMB2OperationGate.runAsync {
                            try await client.disconnectShare()
                        }
                    }
                    return
                }
                self.attachAVPlayerMedia(
                    client: client,
                    dataSource: dataSource,
                    startPositionSeconds: startPositionSeconds
                )
            }
        } catch {
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard !self.isTearingDownPlayback else { return }
                MediaDiagnostics.playback(
                    "event=avplayer_setup_failed mediaID=\(self.mediaID) playerID=\(self.playerID) fallback=http_proxy \(MediaDiagnostics.errorCode(error))"
                )
                self.startAVPlayerFallback(
                    startPositionSeconds: startPositionSeconds,
                    error: error,
                    reason: "setup_failed"
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
        Task {
            try? await SMB2OperationGate.runAsync {
                try await oldStreamClient?.disconnectShare()
            }
        }

        avStreamClient = client
        let contentType = Self.avContentType(for: item)
        let controller = AVPlayerVideoController(
            dataSource: dataSource,
            contentType: contentType,
            fileName: item.name,
            startPositionSeconds: startPositionSeconds,
            ownerID: playerID,
            mediaID: mediaID
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
        controller.onTimeChanged = { [weak self, weak controller] seconds in
            guard let self, let controller, self.avController === controller, !self.isTearingDownPlayback else { return }
            self.currentPositionSeconds = seconds
            self.recordInteractiveSeekObservation(seconds: seconds)
            if seconds > 0 {
                self.hasObservedPlayableTimeline = true
            }
        }
        controller.onDurationChanged = { [weak self, weak controller] duration in
            guard let self, let controller, self.avController === controller, !self.isTearingDownPlayback else { return }
            self.durationSeconds = duration
        }
        controller.onPresentationSizeChanged = { [weak self, weak controller] size in
            guard let self, let controller, self.avController === controller, !self.isTearingDownPlayback else { return }
            self.resolutionText = VideoResolutionFormatter.text(
                width: size.width,
                height: size.height
            )
        }
        controller.onBufferingChanged = { [weak self, weak controller] buffering in
            guard let self, let controller, self.avController === controller, !self.isTearingDownPlayback else { return }
            if buffering {
                self.markInteractiveSeekBuffering()
            }
            self.updateAVBuffering(buffering)
        }
        controller.onPlayingChanged = { [weak self, weak controller] playing in
            guard let self, let controller, self.avController === controller, !self.isTearingDownPlayback else { return }
            self.isPlaying = playing
            self.finishInteractiveSeekDiagnosticsIfReached()
            if playing {
                self.hasEverStartedPlaying = true
                self.updateAVBuffering(false)
                if !self.startupDidLogPlaying {
                    self.startupDidLogPlaying = true
                    self.logStartupDiag(event: "first_playing")
                    self.finishStartupInterval(result: "av_player")
                }
            }
        }
        controller.onScrubPreviewCompleted = { [weak self, weak controller] sessionID, requested, observed, finished, executionMs in
            guard let self, let controller, self.avController === controller,
                  !self.isTearingDownPlayback, self.isInteractiveSeeking,
                  self.scrubPreviewState.sessionID == sessionID else { return }
            self.recordScrubPreviewCompletion(requested: requested, observed: observed,
                                              finished: finished, executionMs: executionMs)
        }
        controller.onFailed = { [weak self, weak controller] error in
            guard let self,
                  let controller,
                  self.avController === controller,
                  !self.isTearingDownPlayback else { return }
            let errorCode = error.map(MediaDiagnostics.errorCode) ?? "domain=unknown code=0"
            MediaDiagnostics.playback(
                "event=avplayer_failed mediaID=\(self.mediaID) playerID=\(self.playerID) fallback=http_proxy \(errorCode)"
            )
            self.startAVPlayerFallback(
                startPositionSeconds: controller.fallbackPositionSeconds,
                error: error,
                reason: "runtime_failed"
            )
        }
    }

    private func startAVPlayerFallback(
        startPositionSeconds: Double,
        error: Error?,
        reason: String
    ) {
        guard !didFallbackFromAVPlayer, !isTearingDownPlayback else {
            MediaDiagnostics.playback(
                "event=avplayer_fallback_skipped mediaID=\(mediaID) playerID=\(playerID) reason=already_attempted"
            )
            return
        }

        didFallbackFromAVPlayer = true
        let shouldAutoplay = avIntendsToPlay
        vlcIntendsToPlay = shouldAutoplay
        if isInteractiveSeeking { wasPlayingBeforeInteractiveSeek = shouldAutoplay }
        let errorCode = error.map(MediaDiagnostics.errorCode) ?? "domain=unknown code=0"
        MediaDiagnostics.playback(
            "event=avplayer_fallback_begin mediaID=\(mediaID) playerID=\(playerID) route=http_proxy reason=\(reason) startSeconds=\(startPositionSeconds) autoplay=\(shouldAutoplay) \(errorCode)"
        )

        tearDownAVPlayer()
        errorMessage = nil
        isBuffering = true
        currentPositionSeconds = startPositionSeconds
        startupPlaybackPath = .httpProxy
        setupTask = Task { [weak self] in
            guard let self else { return }
            await self.prepareHTTPProxyMedia(
                startPositionSeconds: startPositionSeconds,
                autoplay: shouldAutoplay && !self.isInteractiveSeeking
            )
        }
    }

    private func tearDownAVPlayer() {
        guard avController != nil || avStreamClient != nil else { return }
        stopScrubPreview()
        avBufferingDebounceTask?.cancel()
        avBufferingDebounceTask = nil
        avController?.tearDown()
        avController = nil
        avPlayer = nil
        usesAVPlayer = false
        let client = avStreamClient
        avStreamClient = nil
        Task {
            try? await SMB2OperationGate.runAsync {
                try await client?.disconnectShare()
            }
        }
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

    private func prepareHTTPProxyMedia(
        startPositionSeconds: Double,
        autoplay: Bool
    ) async {
        do {
            let credential = try smbClientManager.loadCredential(for: connection)
            let shareName = credential.shareName == "/" ? "" : credential.shareName
            let client = try smbClientManager.makeDedicatedClient(for: connection)
            try await SMB2OperationGate.runAsync {
                try await client.connectShare(name: shareName)
            }

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
                guard !self.isTearingDownPlayback else {
                    server.stop()
                    return
                }
                self.attachHTTPProxyMedia(
                    server: server,
                    localURL: localURL,
                    startPositionSeconds: startPositionSeconds,
                    autoplay: autoplay
                )
            }
        } catch {
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard !self.isTearingDownPlayback else { return }
                self.fallbackToDirectSMBAfterHTTPProxyFailure(
                    startPositionSeconds: startPositionSeconds,
                    error: error,
                    autoplay: autoplay
                )
            }
        }
    }

    private func attachHTTPProxyMedia(
        server: SMBStreamingServer,
        localURL: URL,
        startPositionSeconds: Double,
        autoplay: Bool
    ) {
        let startPositionSeconds = pendingVLCSeekSeconds ?? startPositionSeconds
        pendingVLCSeekSeconds = nil
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
        Task {
            try? await SMB2OperationGate.runAsync {
                try await oldClient?.disconnectShare()
            }
        }

        let networkCaching = 300
        let fileCaching = 300
        MediaDiagnostics.playback("event=route_begin mediaID=\(mediaID) playerID=\(playerID) route=http_proxy startSeconds=\(startPositionSeconds)")
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
        if isDrawableReady, vlcIntendsToPlay, !isInteractiveSeeking {
            playIfReady(trigger: "http_proxy_ready")
        }
    }

    private func fallbackToDirectSMBAfterHTTPProxyFailure(
        startPositionSeconds: Double,
        error: Error,
        autoplay: Bool
    ) {
        setupTask = nil
        MediaDiagnostics.playback(
            "event=proxy_setup_failed mediaID=\(mediaID) playerID=\(playerID) fallback=direct_smb \(MediaDiagnostics.errorCode(error))"
        )
        guard let url = buildSMBURL() else {
            errorMessage = "メディアURLの構築に失敗しました"
            MediaDiagnostics.playback("event=url_build_failed mediaID=\(mediaID) playerID=\(playerID) route=fallback_direct_smb")
            return
        }
        attachDirectSMBMedia(
            url: url,
            startPositionSeconds: startPositionSeconds,
            autoplay: autoplay
        )
    }

    private func attachDirectSMBMedia(
        url: URL,
        startPositionSeconds: Double,
        autoplay: Bool = true
    ) {
        let startPositionSeconds = pendingVLCSeekSeconds ?? startPositionSeconds
        pendingVLCSeekSeconds = nil
        currentStartupStartPositionSeconds = startPositionSeconds
        hasObservedPlayableTimeline = false
        didLogStartupBufferingBeforeTimeline = false
        lastObservedPlaybackTimeMs = nil
        startupPlaybackPath = .directSMB

        streamingServer?.stop()
        streamingServer = nil
        streamInput?.close()
        streamInput = nil
        let oldClient = streamClient
        streamClient = nil
        Task {
            try? await SMB2OperationGate.runAsync {
                try await oldClient?.disconnectShare()
            }
        }

        let cachingPolicy = VideoPlayerCachingPolicy.directSMB(fileSize: item.size)
        let networkCaching = cachingPolicy.networkCachingMilliseconds
        let smbCaching = cachingPolicy.inputCachingMilliseconds
        MediaDiagnostics.playback("event=route_begin mediaID=\(mediaID) playerID=\(playerID) route=direct_smb startSeconds=\(startPositionSeconds) retry=\(directSMBStartupRetryCount)")
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
        if isDrawableReady, vlcIntendsToPlay, !isInteractiveSeeking {
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
            MediaDiagnostics.playback("event=startup_retry_skipped mediaID=\(mediaID) playerID=\(playerID) reason=url_build_failed")
            return
        }

        directSMBStartupRetryCount += 1
        let retryStartPosition = max(0, currentStartupStartPositionSeconds - 10)
        MediaDiagnostics.playback("event=startup_retry mediaID=\(mediaID) playerID=\(playerID) originalStart=\(currentStartupStartPositionSeconds) retryStart=\(retryStartPosition)")
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
            try await SMB2OperationGate.runAsync {
                try await client.connectShare(name: shareName)
            }

            let resolvedPath = await resolveSMBStreamPath(client: client, path: item.path)
            let fileSize = try await resolveSMBStreamFileSize(client: client, path: resolvedPath)
            let stream = SMBRangeInputStream(
                client: client,
                path: resolvedPath,
                fileSize: fileSize,
                ownerID: playerID
            )

            if Task.isCancelled {
                stream.close()
                try? await SMB2OperationGate.runAsync {
                    try await client.disconnectShare()
                }
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
                MediaDiagnostics.playback("event=smb_stream_setup_failed mediaID=\(self.mediaID) playerID=\(self.playerID) \(MediaDiagnostics.errorCode(error))")
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
        Task {
            try? await SMB2OperationGate.runAsync {
                try await oldClient?.disconnectShare()
            }
        }

        streamInput = stream
        streamClient = client

        let inputCaching = VideoPlayerCachingPolicy.directSMB(fileSize: Int64(fileSize)).inputCachingMilliseconds
        MediaDiagnostics.playback("event=route_begin mediaID=\(mediaID) playerID=\(playerID) route=smb_stream size=\(fileSize)")
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
            MediaDiagnostics.resource("event=path_resolved mediaID=\(mediaID) playerID=\(playerID) normalization=nfc")
            return normalized
        }
        if await smbStreamPathExists(client: client, path: original) {
            MediaDiagnostics.resource("event=path_resolved mediaID=\(mediaID) playerID=\(playerID) normalization=original")
            return original
        }
        MediaDiagnostics.resource("event=path_unconfirmed mediaID=\(mediaID) playerID=\(playerID) fallback=nfc")
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
            MediaDiagnostics.playback("event=url_build_failed mediaID=\(mediaID) playerID=\(playerID) route=simulator_direct")
            return
        }
        MediaDiagnostics.playback("event=route_begin mediaID=\(mediaID) playerID=\(playerID) route=simulator_direct")
        let media = VLCMedia(url: url)
        media.delegate = self
        if startPositionSeconds > 0 {
            media.addOptions(["start-time": Int(startPositionSeconds)])
        }
        media.parse(options: .parseNetwork, timeout: 10000)
        player.media = media
        mediaAttachedAt = CFAbsoluteTimeGetCurrent()
        logStartupDiag(event: "media_attached")
        MediaDiagnostics.playback("event=media_attached mediaID=\(mediaID) playerID=\(playerID) route=simulator_direct")
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

    /// AVPlayer + ResourceLoader で再生する形式かどうか。振り分けは VideoPlayerEnginePolicy に従う。
    private static func isAVPlayerEligible(_ item: DirectoryItem) -> Bool {
        VideoPlayerEnginePolicy.usesAVPlayer(fileName: item.name)
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
        if let startupInterval {
            MediaDiagnostics.end(startupInterval, mediaID: mediaID, result: "restarted")
        }
        startupInterval = MediaDiagnostics.begin("MediaStartup", mediaID: mediaID)
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
        didFallbackFromAVPlayer = false
        currentStartupStartPositionSeconds = 0
        directSMBStartupRetryCount = 0
        isInteractiveSeeking = false
        isDrawableReady = false
        stopScrubPreview()
        interactiveSeekDiagnosticsFinalizeTask?.cancel()
        interactiveSeekDiagnosticsFinalizeTask = nil
        interactiveSeekDiagnostics = nil
        pendingInteractiveSeekSeconds = nil
        lastObservedPlaybackTimeMs = nil
        lastPlaybackInterruptionLog = nil
        hasObservedPlayableTimeline = false
        didLogStartupBufferingBeforeTimeline = false
        didRecordPlayerError = false
    }

    private func finishStartupInterval(result: String) {
        guard let startupInterval else { return }
        MediaDiagnostics.end(startupInterval, mediaID: mediaID, result: result)
        self.startupInterval = nil
    }

    private func logStartupDiag(event: String, extra: String? = nil) {
        let now = CFAbsoluteTimeGetCurrent()
        let totalMs = startupBeganAt > 0 ? Int((now - startupBeganAt) * 1000) : -1
        let proxyMs = proxyReadyAt > 0 ? Int((proxyReadyAt - startupBeganAt) * 1000) : -1
        let attachMs = mediaAttachedAt > 0 ? Int((mediaAttachedAt - startupBeganAt) * 1000) : -1
        let playMs = playRequestedAt > 0 ? Int((playRequestedAt - startupBeganAt) * 1000) : -1
        var line = "event=startup mediaID=\(mediaID) playerID=\(playerID) stage=\(event) totalMs=\(totalMs) proxyReadyMs=\(proxyMs) mediaAttachedMs=\(attachMs) playRequestedMs=\(playMs)"
        if let extra {
            line += " | \(extra)"
        }
        MediaDiagnostics.playback(line)
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
        case .esAdded:    stateLabel = "es_added"
        default:          stateLabel = "unknown(\(state.rawValue))"
        }
        MediaDiagnostics.playback(
            "event=state mediaID=\(mediaID) playerID=\(playerID) state=\(stateLabel) path=\(startupPlaybackPathLabel)"
        )

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
                finishStartupInterval(result: startupPlaybackPathLabel)
            }
#if !targetEnvironment(simulator)
            scheduleDirectSMBStartupTimelineWatchdog(delaySeconds: 3)
#endif
        }

        if state == .error {
            guard !isTearingDownPlayback else {
                MediaDiagnostics.playback("event=player_error_ignored mediaID=\(mediaID) playerID=\(playerID) reason=teardown")
                return
            }
            let parsedStatus = player.media.map { parsedStatusLabel($0.parsedStatus) } ?? "no_media"
            let trackCount = player.media?.tracksInformation.count ?? 0
            errorMessage = "再生エラーが発生しました"
            recordPlayerErrorIfNeeded(parsedStatus: parsedStatus, trackCount: trackCount)
            MediaDiagnostics.playback("event=vlc_error mediaID=\(mediaID) playerID=\(playerID) parsedStatus=\(parsedStatus) trackCount=\(trackCount)")
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
        observeVLCScrubSeekProgress(observedSeconds: currentPositionSeconds)

        if let previousMs,
           ms > previousMs,
           !isInteractiveSeeking,
           (player.state == .playing || player.isPlaying) {
            isBuffering = false
        }

        if let lengthMs = player.media?.length.intValue, lengthMs > 0 {
            durationSeconds = Double(lengthMs) / 1000.0
        }
        if resolutionText == nil, let media = player.media {
            updateResolution(from: media)
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
    }

    private func updateResolution(from media: VLCMedia) {
        for case let track as NSDictionary in media.tracksInformation {
            guard track[VLCMediaTracksInformationType] as? String
                    == VLCMediaTracksInformationTypeVideo,
                  let width = track[VLCMediaTracksInformationVideoWidth] as? NSNumber,
                  let height = track[VLCMediaTracksInformationVideoHeight] as? NSNumber,
                  let text = VideoResolutionFormatter.text(
                    width: width.doubleValue,
                    height: height.doubleValue
                  ) else { continue }
            resolutionText = text
            return
        }
    }

    private func logPlaybackInterruptionIfNeeded(stateLabel: String) {
        if stateLabel == "buffering",
           !hasObservedPlayableTimeline,
           lastObservedPlaybackTimeMs == nil,
           durationSeconds == 0 {
            if !didLogStartupBufferingBeforeTimeline {
                didLogStartupBufferingBeforeTimeline = true
                MediaDiagnostics.playback("event=startup_buffering_before_timeline mediaID=\(mediaID) playerID=\(playerID)")
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
        let line = "event=playback_interruption mediaID=\(mediaID) playerID=\(playerID) state=\(stateLabel) positionSeconds=\(positionSeconds) durationSeconds=\(durationSeconds) isPlaying=\(player.isPlaying) isBuffering=\(isBuffering) interactiveSeeking=\(isInteractiveSeeking) lastObservedTimeMs=\(lastObservedPlaybackTimeMs ?? -1) parsedStatus=\(parsedStatus) trackCount=\(trackCount)"
        let telemetryLine = "[VideoPlayer] playback interruption | state: \(stateLabel) | positionSeconds: \(positionSeconds) | durationSeconds: \(durationSeconds) | isPlaying: \(player.isPlaying) | isBuffering: \(isBuffering) | interactiveSeeking: \(isInteractiveSeeking) | lastObservedTimeMs: \(lastObservedPlaybackTimeMs ?? -1) | parsedStatus: \(parsedStatus) | trackCount: \(trackCount) | playerID: \(playerID)"
        MediaDiagnostics.playback(line)
        FirebaseSupport.logCrashlytics(telemetryLine)
    }

    private func recordPlayerErrorIfNeeded(parsedStatus: String, trackCount: Int) {
        guard !didRecordPlayerError else {
            MediaDiagnostics.playback("event=duplicate_player_error_ignored mediaID=\(mediaID) playerID=\(playerID)")
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
        MediaDiagnostics.playback("event=vlc_parse_finished mediaID=\(mediaID) playerID=\(playerID) status=\(statusLabel)")
        let tracks = aMedia.tracksInformation
        print("[VideoPlayer] Track count after parse: \(tracks.count) | playerID: \(playerID)")
        updateResolution(from: aMedia)
    }
}

#if !targetEnvironment(simulator)
private final class SMBRangeInputStream: InputStream, @unchecked Sendable {

    private let client: SMB2Manager
    private let path: String
    private let fileSize: UInt64
    private let ownerID: String
    private let maxChunkSize = 2 * 1024 * 1024
    private let lock = NSLock()

    private var offset: UInt64 = 0
    private var status: Stream.Status = .notOpen
    private var error: Error?

    init(client: SMB2Manager, path: String, fileSize: UInt64, ownerID: String) {
        self.client = client
        self.path = path
        self.fileSize = fileSize
        self.ownerID = ownerID
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
        MediaDiagnostics.resource("event=stream_open playerID=\(ownerID) size=\(fileSize)")
    }

    override func close() {
        lock.lock()
        status = .closed
        lock.unlock()
        MediaDiagnostics.resource("event=stream_close playerID=\(ownerID)")
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
            MediaDiagnostics.resource("event=stream_read_failed playerID=\(ownerID) offset=\(readOffset) length=\(readLength) \(MediaDiagnostics.errorCode(readError))")
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
        MediaDiagnostics.resource("event=stream_seek playerID=\(ownerID) offset=\(requestedOffset)")
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
