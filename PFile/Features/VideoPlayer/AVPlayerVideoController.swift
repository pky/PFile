import Foundation
import AVFoundation
import UIKit

#if !targetEnvironment(simulator)

/// MP4 / MOV を AVPlayer + AVAssetResourceLoader + AMSMB2 で再生する制御クラス。
/// VLC 経路と混ざらないよう AVPlayer 関連の状態と監視をここに閉じ込め、
/// 再生状態は closure で VideoPlayerViewModel に通知する。
/// 利用は main 想定で、KVO や時刻監視の通知は main へ marshal する。
final class AVPlayerVideoController: @unchecked Sendable {

    let player = AVPlayer()

    private let dataSource: ByteRangeDataSource
    private let loaderQueue = DispatchQueue(label: "jp.pky.pfile.av-loader-delegate")
    private let contentType: String
    private let fileName: String
    private let startPositionSeconds: Double
    private let ownerID: String
    private let mediaID: String
    private lazy var resourceLoader = SMBResourceLoaderDelegate(
        dataSource: dataSource,
        contentType: contentType,
        ownerID: ownerID,
        mediaID: mediaID
    ) { [weak self] error in
        DispatchQueue.main.async {
            self?.reportFailureOnce(error)
        }
    }

    private var playerItem: AVPlayerItem?
    private var asset: AVURLAsset?
    private var imageGenerator: AVAssetImageGenerator?
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var bufferObservations: [NSKeyValueObservation] = []
    private var itemNotifications: [NSObjectProtocol] = []
    private var playbackIntent = VideoPlaybackIntentState()
    private var seekState = VideoSeekState()
    private var executingSeekID: UUID?
    private var seekInterval: MediaDiagnostics.Interval?
    private var seekBeganAt: TimeInterval = 0
    private var seekTimeoutTask: Task<Void, Never>?

    private var isSuspendedForSeek: Bool { playbackIntent.isSuspendedForSeek }
    private var isItemReady = false
    private var isDrawableReady = false
    private var didStartPlayback = false
    private var didApplyStartPosition = false
    private var didReportPresentationSize = false
    private var didReportFailure = false

    var onTimeChanged: ((Double) -> Void)?
    var onDurationChanged: ((Double) -> Void)?
    var onPresentationSizeChanged: ((CGSize) -> Void)?
    var onBufferingChanged: ((Bool) -> Void)?
    var onPlayingChanged: ((Bool) -> Void)?
    var onFailed: ((Error?) -> Void)?
    var onScrubPreviewCompleted: ((UUID, Double, Double, Bool, Int) -> Void)?

    init(
        dataSource: ByteRangeDataSource,
        contentType: String,
        fileName: String,
        startPositionSeconds: Double,
        ownerID: String,
        mediaID: String
    ) {
        self.dataSource = dataSource
        self.contentType = contentType
        self.fileName = fileName
        self.startPositionSeconds = startPositionSeconds
        self.ownerID = ownerID
        self.mediaID = mediaID
        // 独自ResourceLoaderではAVPlayerの将来到着予測を使わず、データ回復時に明示的に再開する。
        player.automaticallyWaitsToMinimizeStalling = false
    }

    // MARK: - ライフサイクル

    func load() {
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)

        // カスタムスキームにすることで AVPlayer のロードを ResourceLoader へ委譲する。
        let encodedName = fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "stream"
        guard let url = URL(string: "\(SMBResourceLoaderDelegate.scheme)://stream/\(encodedName)") else {
            reportFailureOnce(nil)
            return
        }
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(resourceLoader, queue: loaderQueue)
        self.asset = asset

        // 履歴用の画像サイズと近傍フレームの許容差を維持する。
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        generator.maximumSize = CGSize(width: 480, height: 480)
        self.imageGenerator = generator

        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 0
        self.playerItem = item

        observe(item: item)
        player.replaceCurrentItem(with: item)
        MediaDiagnostics.playback(
            "event=avplayer_load mediaID=\(mediaID) playerID=\(ownerID) startSeconds=\(startPositionSeconds)"
        )
    }

    func markDrawableReady() {
        guard playbackIntent.isActive else { return }
        isDrawableReady = true
        startPlaybackIfReady()
    }

    func tearDown() {
        playbackIntent.tearDown()
        seekState.reset()
        executingSeekID = nil
        finishSeekDiagnostics(result: "cancelled")
        bufferObservations.forEach { $0.invalidate() }
        bufferObservations.removeAll()
        itemNotifications.forEach { NotificationCenter.default.removeObserver($0) }
        itemNotifications.removeAll()
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        onTimeChanged = nil
        onDurationChanged = nil
        onPresentationSizeChanged = nil
        onBufferingChanged = nil
        onPlayingChanged = nil
        onFailed = nil
        onScrubPreviewCompleted = nil
        statusObservation?.invalidate()
        statusObservation = nil
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        imageGenerator?.cancelAllCGImageGeneration()
        imageGenerator = nil
        resourceLoader.cancelAllLoadingRequests()
        asset?.resourceLoader.setDelegate(nil, queue: nil)
        asset?.cancelLoading()
        playerItem?.cancelPendingSeeks()
        player.pause()
        player.replaceCurrentItem(with: nil)
        playerItem = nil
        asset = nil
        didReportPresentationSize = false
        MediaDiagnostics.playback("event=avplayer_teardown mediaID=\(mediaID) playerID=\(ownerID)")
    }

    // MARK: - 操作

    var fallbackPositionSeconds: Double { seekState.targetSeconds ?? currentPositionSeconds }

    var isSeeking: Bool { seekState.inFlight != nil }

    var intendsToPlay: Bool { playbackIntent.intendsToPlay }

    func play() {
        guard playbackIntent.isActive, !didReportFailure else { return }
        playbackIntent.play()
        if isAtEnd, seekState.inFlight == nil {
            seek(toSeconds: 0)
            return
        }
        startPlaybackIfReady()
        if didStartPlayback, seekState.inFlight == nil, !isSuspendedForSeek { requestPlayback() }
    }

    func pause() {
        playbackIntent.pause()
        player.pause()
        onPlayingChanged?(false)
        onBufferingChanged?(false)
    }

    func beginInteractiveSeek() {
        playbackIntent.beginInteractiveSeek()
        player.pause()
    }

    func endInteractiveSeek() {
        playbackIntent.endInteractiveSeek()
        if playbackIntent.intendsToPlay { play() }
    }

    var isPaused: Bool { !playbackIntent.intendsToPlay }

    func togglePlayPause() {
        if isPaused { play() } else { pause() }
    }

    func setMuted(_ muted: Bool) { player.isMuted = muted }

    var currentPositionSeconds: Double {
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? max(0, seconds) : 0
    }

    /// 連打中は最新の目標だけを保持し、実行中のシーク完了後に追従する。
    func seek(toSeconds seconds: Double) {
        guard playbackIntent.isActive, !didReportFailure,
              let target = VideoSeekState.clamped(seconds, duration: durationSeconds) else { return }
        beginSeekDiagnostics(target: target)
        if let request = seekState.request(seconds: target, duration: durationSeconds) {
            performSeek(request)
        }
    }

    /// ドラッグ中は主プレイヤーの映像を直接更新し、別の画像取得・復号を行わない。
    func seekForScrubPreview(toSeconds seconds: Double, sessionID: UUID) {
        guard playbackIntent.isActive, !didReportFailure, isSuspendedForSeek,
              let target = VideoSeekState.clamped(seconds, duration: durationSeconds) else { return }
        finishSeekDiagnostics(result: "superseded_by_scrub")
        if let request = seekState.request(seconds: target, duration: durationSeconds,
                                           purpose: .scrubPreview, contextID: sessionID) {
            performSeek(request)
        }
    }

    func skip(seconds delta: Double) {
        guard delta.isFinite else { return }
        seek(toSeconds: (seekState.targetSeconds ?? currentPositionSeconds) + delta)
    }

    private var durationSeconds: Double { playerItem?.duration.seconds ?? 0 }

    private func performSeek(_ request: VideoSeekState.Request) {
        guard let item = playerItem, isItemReady, executingSeekID == nil else { return }
        executingSeekID = request.id
        let issuedAt = ProcessInfo.processInfo.systemUptime
        // プレビューは速度優先の標準seek、指を離した確定seekは従来の±1秒を維持する。
        let tolerance = request.purpose == .scrubPreview
            ? CMTime.positiveInfinity : CMTime(seconds: 1, preferredTimescale: 600)
        let previewInterval = request.purpose == .scrubPreview
            ? MediaDiagnostics.begin("AVPlayerScrubSeek", mediaID: mediaID) : nil
        let diagnosticMediaID = mediaID
        player.seek(to: CMTime(seconds: request.seconds, preferredTimescale: 600),
                    toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self, weak item] finished in
            Task { @MainActor in
                var intervalResult = "obsolete"
                defer {
                    if let previewInterval {
                        MediaDiagnostics.end(previewInterval, mediaID: diagnosticMediaID, result: intervalResult)
                    }
                }
                guard let self, let item, self.isCurrent(item),
                      self.seekState.inFlight?.id == request.id else { return }
                let executionMs = max(0, Int((ProcessInfo.processInfo.systemUptime - issuedAt) * 1000))
                intervalResult = finished ? "seek_completed" : "interrupted"
                if request.purpose == .scrubPreview {
                    if let sessionID = request.contextID, self.isSuspendedForSeek {
                        self.onScrubPreviewCompleted?(sessionID, request.seconds, self.currentPositionSeconds, finished, executionMs)
                    }
                } else {
                    MediaDiagnostics.playback(
                        "event=avplayer_seek_completed mediaID=\(self.mediaID) playerID=\(self.ownerID) requestSeconds=\(request.seconds) finished=\(finished) executionMs=\(executionMs) latestRequestElapsedMs=\(self.seekElapsedMilliseconds)"
                    )
                }
                self.executingSeekID = nil
                if let next = self.seekState.complete(request) {
                    self.performSeek(next)
                    return
                }
                self.onTimeChanged?(self.currentPositionSeconds)
                // 粗いプレビューの完了では終端・再生意図・確定seek診断を変更しない。
                guard request.purpose == .playback, !self.isSuspendedForSeek else { return }
                if finished, self.isAtEnd {
                    self.playbackIntent.ended()
                    self.onPlayingChanged?(false)
                    self.onBufferingChanged?(false)
                    self.finishSeekDiagnostics(result: "completed_end")
                    return
                }
                if !finished {
                    self.finishSeekDiagnostics(result: "interrupted")
                } else if !self.playbackIntent.intendsToPlay {
                    self.finishSeekDiagnostics(result: "completed_paused")
                }
                // 完了は映像の表示とは区別する。再生意図がある場合だけ再開する。
                if self.playbackIntent.intendsToPlay, self.didStartPlayback, !self.isSuspendedForSeek {
                    self.requestPlayback()
                    if self.player.timeControlStatus == .playing {
                        self.finishSeekDiagnostics(result: "completed_playing_state")
                    }
                }
                self.startPlaybackIfReady()
            }
        }
    }

    private var seekElapsedMilliseconds: Int {
        max(0, Int((ProcessInfo.processInfo.systemUptime - seekBeganAt) * 1000))
    }

    private func beginSeekDiagnostics(target: Double) {
        finishSeekDiagnostics(result: "superseded")
        seekBeganAt = ProcessInfo.processInfo.systemUptime
        seekInterval = MediaDiagnostics.begin("AVPlayerSeek", mediaID: mediaID)
        MediaDiagnostics.playback("event=avplayer_seek_requested mediaID=\(mediaID) playerID=\(ownerID) requestSeconds=\(target)")
        seekTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            self?.finishSeekDiagnostics(result: "timeout")
        }
    }

    private func finishSeekDiagnostics(result: String) {
        seekTimeoutTask?.cancel()
        seekTimeoutTask = nil
        guard let seekInterval else { return }
        MediaDiagnostics.playback("event=avplayer_seek_result mediaID=\(mediaID) playerID=\(ownerID) result=\(result) elapsedMs=\(seekElapsedMilliseconds)")
        MediaDiagnostics.end(seekInterval, mediaID: mediaID, result: result)
        self.seekInterval = nil
    }

    // MARK: - サムネイル

    /// 履歴保存用のフレーム画像を生成する。
    func generateThumbnail(atSeconds seconds: Double) async -> UIImage? {
        guard let imageGenerator else { return nil }
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        do {
            let cgImage = try await imageGenerator.image(at: time).image
            return UIImage(cgImage: cgImage)
        } catch {
            return nil
        }
    }

    // MARK: - 監視

    private func observe(item: AVPlayerItem) {
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, self.isCurrent(item) else { return }
                self.handleStatusChange(item.status, error: item.error)
            }
        }
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self, weak item] _, _ in
            Task { @MainActor in
                guard let self, let item, self.isCurrent(item) else { return }
                self.handleTimeControlChange(self.player.timeControlStatus)
            }
        }
        // 待機予測ではなく、現在位置に届いた実データで復帰を判断する。
        bufferObservations = [
            item.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] item, _ in
                Task { @MainActor in self?.handleBufferChange(item) }
            },
            item.observe(\.loadedTimeRanges, options: [.new]) { [weak self] item, _ in
                Task { @MainActor in self?.handleBufferChange(item) }
            }
        ]
        itemNotifications = [
            NotificationCenter.default.addObserver(forName: .AVPlayerItemPlaybackStalled, object: item, queue: .main) { [weak self, weak item] _ in
                guard let self, let item, self.isCurrent(item) else { return }
                self.playbackIntent.stalled()
                self.onBufferingChanged?(self.playbackIntent.isWaitingForData)
                self.handleBufferChange(item)
            },
            NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self, weak item] _ in
                guard let self, let item, self.isCurrent(item), !self.isSuspendedForSeek,
                      self.seekState.inFlight == nil, self.isAtEnd else { return }
                self.playbackIntent.ended()
                self.onPlayingChanged?(false)
                self.onBufferingChanged?(false)
                self.finishSeekDiagnostics(result: "ended")
            }
        ]

        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self, self.playbackIntent.isActive, self.player.currentItem === self.playerItem else { return }
            let seconds = time.seconds
            if seconds.isFinite {
                self.onTimeChanged?(max(0, seconds))
            }
            if let duration = self.playerItem?.duration.seconds, duration.isFinite, duration > 0 {
                self.onDurationChanged?(duration)
            }
            self.reportPresentationSizeIfAvailable()
        }
    }

    private func handleStatusChange(_ status: AVPlayerItem.Status, error: Error?) {
        switch status {
        case .readyToPlay:
            isItemReady = true
            if let duration = playerItem?.duration.seconds, duration.isFinite, duration > 0 {
                onDurationChanged?(duration)
            }
            reportPresentationSizeIfAvailable()
            seekState.clampPending(duration: durationSeconds)
            applyStartPositionIfNeeded()
            if let request = seekState.inFlight { performSeek(request) }
            startPlaybackIfReady()
        case .failed:
            let errorCode = error.map(MediaDiagnostics.errorCode) ?? "domain=unknown code=0"
            MediaDiagnostics.playback(
                "event=avplayer_item_failed mediaID=\(mediaID) playerID=\(ownerID) \(errorCode)"
            )
            reportFailureOnce(error)
        default:
            break
        }
    }

    private func reportPresentationSizeIfAvailable() {
        guard !didReportPresentationSize,
              let size = playerItem?.presentationSize,
              size.width > 0,
              size.height > 0 else { return }
        didReportPresentationSize = true
        onPresentationSizeChanged?(size)
    }

    private func isCurrent(_ item: AVPlayerItem) -> Bool {
        playbackIntent.isActive && !didReportFailure && playerItem === item && player.currentItem === item
    }

    private var isAtEnd: Bool {
        durationSeconds.isFinite && durationSeconds > 0 && currentPositionSeconds >= durationSeconds - 0.05
    }

    private func handleBufferChange(_ item: AVPlayerItem) {
        guard isCurrent(item), !isAtEnd else { return }
        if item.isPlaybackBufferEmpty {
            playbackIntent.stalled()
        }
        if playbackIntent.isWaitingForData {
            onBufferingChanged?(true)
        }
        let position = player.currentTime()
        let hasData = !item.isPlaybackBufferEmpty && item.loadedTimeRanges.contains { value in
            let range = value.timeRangeValue
            return CMTimeRangeContainsTime(range, time: position)
                && CMTimeSubtract(CMTimeRangeGetEnd(range), position).seconds > 0.05
        }
        if playbackIntent.resumeIfPossible(hasData: hasData,
                                           isReady: isItemReady && isDrawableReady && !isSuspendedForSeek,
                                           isSeeking: seekState.inFlight != nil) {
            MediaDiagnostics.playback("event=avplayer_resume_after_stall mediaID=\(mediaID) playerID=\(ownerID)")
            player.play()
        }
    }

    private func handleTimeControlChange(_ status: AVPlayer.TimeControlStatus) {
        MediaDiagnostics.playback("event=avplayer_time_control mediaID=\(mediaID) playerID=\(ownerID) status=\(status.rawValue) intendsToPlay=\(playbackIntent.intendsToPlay) bufferEmpty=\(playerItem?.isPlaybackBufferEmpty ?? true)")
        switch status {
        case .playing:
            guard playbackIntent.intendsToPlay, !isSuspendedForSeek else {
                player.pause()
                return
            }
            onPlayingChanged?(true)
            onBufferingChanged?(false)
            if seekState.inFlight == nil { finishSeekDiagnostics(result: "playing_state") }
        case .waitingToPlayAtSpecifiedRate:
            onBufferingChanged?(playbackIntent.intendsToPlay)
        case .paused:
            onPlayingChanged?(false)
            if let item = playerItem { handleBufferChange(item) }
            if !playbackIntent.intendsToPlay { onBufferingChanged?(false) }
        @unknown default:
            break
        }
    }

    private func applyStartPositionIfNeeded() {
        guard !didApplyStartPosition, startPositionSeconds > 0 else { return }
        didApplyStartPosition = true
        guard seekState.targetSeconds == nil else { return }
        // 履歴シークは初回再生より先に完了させる。
        _ = seekState.request(seconds: startPositionSeconds, duration: durationSeconds)
        beginSeekDiagnostics(target: seekState.targetSeconds ?? 0)
    }

    private func startPlaybackIfReady() {
        guard playbackIntent.isActive, !didReportFailure, playbackIntent.intendsToPlay,
              isItemReady, isDrawableReady, !isSuspendedForSeek, !didStartPlayback, seekState.inFlight == nil else { return }
        didStartPlayback = true
        playbackIntent.started()
        requestPlayback()
    }

    private func requestPlayback() {
        player.play()
        // 初回の空バッファでは停止通知が来ない場合もあるので、再生要求直後にも確認する。
        if let item = playerItem { handleBufferChange(item) }
    }

    private func reportFailureOnce(_ error: Error?) {
        guard playbackIntent.isActive, !didReportFailure else { return }
        didReportFailure = true
        finishSeekDiagnostics(result: "failed")
        onFailed?(error)
    }
}

#endif
