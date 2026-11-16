import Foundation
import AVFoundation

#if !targetEnvironment(simulator)

/// 再生せず、一時停止した画面へのシークだけを行う専用プレイヤー。
/// 操作は main で行い、KVO とシーク完了も main へ戻す。
final class ScrubPreviewPlayer: @unchecked Sendable {
    let player = AVPlayer()

    var onReadyChanged: ((Bool) -> Void)?
    var onSeekIssued: (() -> Void)?
    var onSeekCompleted: ((Bool, Int) -> Void)?

    private let fileName: String
    private let loaderQueue = DispatchQueue(label: "jp.pky.pfile.scrub-overlay-loader")
    private let resourceLoader: SMBResourceLoaderDelegate
    private var asset: AVURLAsset?
    private var playerItem: AVPlayerItem?
    private var statusObservation: NSKeyValueObservation?
    private var seekState = VideoSeekState()
    private var executingSeekID: UUID?
    private var isReady = false
    private var isActive = false

    init(dataSource: ByteRangeDataSource, contentType: String, fileName: String,
         ownerID: String, mediaID: String) {
        self.fileName = fileName
        // 読み出し失敗は item.status の失敗通知で処理する。
        resourceLoader = SMBResourceLoaderDelegate(
            dataSource: dataSource, contentType: contentType, ownerID: ownerID, mediaID: mediaID
        ) { _ in }
        player.isMuted = true
        player.automaticallyWaitsToMinimizeStalling = false
    }

    func load() {
        guard !isActive else { return }
        isActive = true
        let encodedName = fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "stream"
        guard let url = URL(string: "\(SMBResourceLoaderDelegate.scheme)://stream/\(encodedName)") else {
            onReadyChanged?(false)
            return
        }
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(resourceLoader, queue: loaderQueue)
        self.asset = asset
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 1
        playerItem = item
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, self.isActive, self.playerItem === item,
                      self.player.currentItem === item else { return }
                switch item.status {
                case .readyToPlay:
                    self.isReady = true
                    self.onReadyChanged?(true)
                    self.seekState.clampPending(duration: item.duration.seconds)
                    if let request = self.seekState.inFlight { self.performSeek(request) }
                case .failed:
                    self.isReady = false
                    self.onReadyChanged?(false)
                default:
                    break
                }
            }
        }
        player.replaceCurrentItem(with: item)
    }

    func requestSeek(seconds: Double) {
        guard isActive else { return }
        if let request = seekState.request(seconds: seconds, duration: playerItem?.duration.seconds ?? 0,
                                           purpose: .scrubPreview) {
            performSeek(request)
        }
    }

    /// 前のドラッグの完了が次のドラッグの表示・集計へ混入するのを防ぐ。
    func cancelSeeks() {
        seekState.reset()
        executingSeekID = nil
        playerItem?.cancelPendingSeeks()
    }

    private func performSeek(_ request: VideoSeekState.Request) {
        guard isActive, isReady, let item = playerItem, executingSeekID == nil else { return }
        executingSeekID = request.id
        let issuedAt = ProcessInfo.processInfo.systemUptime
        onSeekIssued?()
        player.seek(to: CMTime(seconds: request.seconds, preferredTimescale: 600),
                    toleranceBefore: .positiveInfinity, toleranceAfter: .zero) { [weak self, weak item] finished in
            Task { @MainActor in
                guard let self, let item, self.isActive, self.playerItem === item,
                      self.player.currentItem === item,
                      self.seekState.inFlight?.id == request.id else { return }
                let latencyMs = max(0, Int((ProcessInfo.processInfo.systemUptime - issuedAt) * 1000))
                self.onSeekCompleted?(finished, latencyMs)
                self.executingSeekID = nil
                if let next = self.seekState.complete(request) { self.performSeek(next) }
            }
        }
    }

    func tearDown() {
        isActive = false
        isReady = false
        onReadyChanged = nil
        onSeekIssued = nil
        onSeekCompleted = nil
        statusObservation?.invalidate()
        statusObservation = nil
        cancelSeeks()
        player.replaceCurrentItem(with: nil)
        resourceLoader.cancelAllLoadingRequests()
        asset?.resourceLoader.setDelegate(nil, queue: nil)
        asset?.cancelLoading()
        playerItem = nil
        asset = nil
    }
}

#endif
