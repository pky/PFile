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
    private let resourceLoader: SMBResourceLoaderDelegate
    private let loaderQueue = DispatchQueue(label: "jp.pky.pfile.av-loader-delegate")
    private let contentType: String
    private let fileName: String
    private let startPositionSeconds: Double
    private let ownerID: String

    private var playerItem: AVPlayerItem?
    private var asset: AVURLAsset?
    private var imageGenerator: AVAssetImageGenerator?
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?

    private var isItemReady = false
    private var isDrawableReady = false
    private var didStartPlayback = false
    private var didApplyStartPosition = false

    var onTimeChanged: ((Double) -> Void)?
    var onDurationChanged: ((Double) -> Void)?
    var onBufferingChanged: ((Bool) -> Void)?
    var onPlayingChanged: ((Bool) -> Void)?
    var onFailed: ((Error?) -> Void)?

    init(
        dataSource: ByteRangeDataSource,
        contentType: String,
        fileName: String,
        startPositionSeconds: Double,
        ownerID: String
    ) {
        self.dataSource = dataSource
        self.contentType = contentType
        self.fileName = fileName
        self.startPositionSeconds = startPositionSeconds
        self.ownerID = ownerID
        self.resourceLoader = SMBResourceLoaderDelegate(
            dataSource: dataSource,
            contentType: contentType,
            ownerID: ownerID
        )
    }

    // MARK: - ライフサイクル

    func load() {
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)

        // カスタムスキームにすることで AVPlayer のロードを ResourceLoader へ委譲する。
        let encodedName = fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "stream"
        guard let url = URL(string: "\(SMBResourceLoaderDelegate.scheme)://stream/\(encodedName)") else {
            onFailed?(nil)
            return
        }
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(resourceLoader, queue: loaderQueue)
        self.asset = asset

        // drag スクラブと履歴サムネイルで使い回す。tolerance を持たせ近傍キーフレームを高速に取る。
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
        print("[AVPlayer] load | playerID: \(ownerID) | file: \(fileName) | startPosition: \(startPositionSeconds)s")
    }

    func markDrawableReady() {
        isDrawableReady = true
        startPlaybackIfReady()
    }

    func tearDown() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        statusObservation?.invalidate()
        statusObservation = nil
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        imageGenerator?.cancelAllCGImageGeneration()
        imageGenerator = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        playerItem = nil
        asset = nil
        print("[AVPlayer] teardown | playerID: \(ownerID) | file: \(fileName)")
    }

    // MARK: - 操作

    func play() {
        player.play()
    }

    func pause() {
        player.pause()
    }

    var isPaused: Bool {
        player.timeControlStatus == .paused
    }

    func togglePlayPause() {
        if player.timeControlStatus == .paused {
            play()
        } else {
            pause()
        }
    }

    func setMuted(_ muted: Bool) {
        player.isMuted = muted
    }

    var currentPositionSeconds: Double {
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? max(0, seconds) : 0
    }

    /// 指定秒へ seek する。tolerance を持たせて遠距離 seek でも素早く近傍キーフレームへ寄せる。
    func seek(toSeconds seconds: Double) {
        let target = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        let tolerance = CMTime(seconds: 1, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: tolerance, toleranceAfter: tolerance)
    }

    func skip(seconds delta: Double) {
        seek(toSeconds: currentPositionSeconds + delta)
    }

    // MARK: - サムネイル

    /// 進行中のサムネイル生成を中断し、共有 SMB セッションを再生側へ即座に返す。
    /// drag を離したあとの再生再開が、古いスクラブ読み出しと競合して詰まるのを防ぐ。
    func cancelThumbnailGeneration() {
        imageGenerator?.cancelAllCGImageGeneration()
    }

    /// 指定秒のフレーム画像を生成する。履歴サムネイルと drag スクラブの両方で使う。
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
            Task { @MainActor in self?.handleStatusChange(item.status, error: item.error) }
        }
        // isPlaybackLikelyToKeepUp は予測値で、実際に止まっていなくても周期的に false へ振れる。
        // スピナー判定には使わず、timeControlStatus の実待機だけを使う。
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor in self?.handleTimeControlChange(player.timeControlStatus) }
        }

        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            let seconds = time.seconds
            if seconds.isFinite {
                self.onTimeChanged?(max(0, seconds))
            }
            if let duration = self.playerItem?.duration.seconds, duration.isFinite, duration > 0 {
                self.onDurationChanged?(duration)
            }
        }
    }

    private func handleStatusChange(_ status: AVPlayerItem.Status, error: Error?) {
        switch status {
        case .readyToPlay:
            isItemReady = true
            if let duration = playerItem?.duration.seconds, duration.isFinite, duration > 0 {
                onDurationChanged?(duration)
            }
            applyStartPositionIfNeeded()
            startPlaybackIfReady()
        case .failed:
            print("[AVPlayer] item failed | playerID: \(ownerID) | file: \(fileName) | error: \(String(describing: error))")
            onFailed?(error)
        default:
            break
        }
    }

    private func handleTimeControlChange(_ status: AVPlayer.TimeControlStatus) {
        switch status {
        case .playing:
            onPlayingChanged?(true)
            onBufferingChanged?(false)
        case .waitingToPlayAtSpecifiedRate:
            onBufferingChanged?(true)
        case .paused:
            onPlayingChanged?(false)
        @unknown default:
            break
        }
    }

    private func applyStartPositionIfNeeded() {
        guard !didApplyStartPosition, startPositionSeconds > 0 else { return }
        didApplyStartPosition = true
        seek(toSeconds: startPositionSeconds)
    }

    private func startPlaybackIfReady() {
        guard isItemReady, isDrawableReady, !didStartPlayback else { return }
        didStartPlayback = true
        play()
    }
}

#endif
