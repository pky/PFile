import Foundation

/// ドラッグ入力を集約し、初回は即時、継続入力は一定間隔でAVPlayerへ渡す。
struct VideoScrubPreviewState {
    struct Request {
        let sessionID: UUID
        let seconds: Double
        let requestedAt: TimeInterval
    }

    private let minimumInterval: TimeInterval
    private(set) var sessionID: UUID?
    private var latestSeconds: Double?
    private var latestRequestedAt: TimeInterval?
    private var lastIssuedSeconds: Double?
    private var lastIssuedAt: TimeInterval?

    init(minimumInterval: TimeInterval = 0.1) {
        self.minimumInterval = minimumInterval.isFinite ? max(0, minimumInterval) : 0.1
    }

    mutating func beginSession() {
        sessionID = UUID()
        latestSeconds = nil
        latestRequestedAt = nil
        lastIssuedSeconds = nil
        lastIssuedAt = nil
    }

    mutating func update(seconds: Double, duration: Double, now: TimeInterval) {
        guard sessionID != nil, now.isFinite,
              let target = VideoSeekState.clamped(seconds, duration: duration) else { return }
        latestSeconds = target
        latestRequestedAt = now
    }

    func delay(now: TimeInterval) -> TimeInterval? {
        guard sessionID != nil, now.isFinite, let latestSeconds else { return nil }
        if let lastIssuedSeconds, abs(latestSeconds - lastIssuedSeconds) < 0.25 { return nil }
        guard let lastIssuedAt else { return 0 }
        return max(0, minimumInterval - max(0, now - lastIssuedAt))
    }

    mutating func takeRequest(now: TimeInterval) -> Request? {
        guard let delay = delay(now: now), delay <= 0, let sessionID,
              let latestSeconds, let latestRequestedAt else { return nil }
        lastIssuedSeconds = latestSeconds
        lastIssuedAt = now
        return Request(sessionID: sessionID, seconds: latestSeconds, requestedAt: latestRequestedAt)
    }

    mutating func endSession() {
        sessionID = nil
        latestSeconds = nil
        latestRequestedAt = nil
    }
}
