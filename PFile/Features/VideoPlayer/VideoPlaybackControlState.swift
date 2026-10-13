import Foundation

/// 観測された停止状態と、ユーザーの再生意図を分離する。
struct VideoPlaybackIntentState {
    private(set) var intendsToPlay = true
    private(set) var isWaitingForData = false
    private(set) var hasStarted = false
    private(set) var isActive = true
    private(set) var hasEnded = false
    private(set) var isSuspendedForSeek = false

    mutating func play() {
        guard isActive else { return }
        intendsToPlay = true
        hasEnded = false
    }

    mutating func pause() {
        intendsToPlay = false
        isWaitingForData = false
    }

    mutating func beginInteractiveSeek() { isSuspendedForSeek = true }
    mutating func endInteractiveSeek() { isSuspendedForSeek = false }

    mutating func started() { hasStarted = true }

    mutating func stalled() {
        guard isActive, hasStarted, intendsToPlay, !hasEnded else { return }
        isWaitingForData = true
    }

    mutating func resumeIfPossible(hasData: Bool, isReady: Bool, isSeeking: Bool) -> Bool {
        guard isActive, intendsToPlay, !hasEnded, !isSuspendedForSeek, isWaitingForData,
              hasData, isReady, !isSeeking else { return false }
        isWaitingForData = false
        return true
    }

    mutating func ended() {
        hasEnded = true
        pause()
    }

    mutating func tearDown() {
        isActive = false
        pause()
    }
}

/// シークは常に1件だけ実行し、その間の入力は最新の目標へ集約する。
struct VideoSeekState {
    enum Purpose: Equatable { case playback, scrubPreview }

    struct Request: Equatable {
        let id: UUID
        let seconds: Double
        let purpose: Purpose
        let contextID: UUID?
    }

    private(set) var inFlight: Request?
    private(set) var targetSeconds: Double?
    private var targetPurpose: Purpose?
    private var targetContextID: UUID?

    static func clamped(_ seconds: Double, duration: Double) -> Double? {
        guard seconds.isFinite else { return nil }
        // VLCのミリ秒表現でもオーバーフローしない範囲に収める。
        let upperBound = duration.isFinite && duration > 0
            ? min(duration, Double(Int32.max) / 1000)
            : Double(Int32.max) / 1000
        return min(max(0, seconds), upperBound)
    }

    mutating func request(seconds: Double, duration: Double, purpose: Purpose = .playback, contextID: UUID? = nil) -> Request? {
        guard let target = Self.clamped(seconds, duration: duration) else { return nil }
        targetSeconds = target
        targetPurpose = purpose
        targetContextID = contextID
        guard inFlight == nil else { return nil }
        let request = Request(id: UUID(), seconds: target, purpose: purpose, contextID: contextID)
        inFlight = request
        return request
    }

    mutating func skip(delta: Double, currentSeconds: Double, duration: Double) -> Request? {
        guard delta.isFinite else { return nil }
        return request(seconds: (targetSeconds ?? currentSeconds) + delta, duration: duration)
    }

    mutating func complete(_ request: Request) -> Request? {
        guard inFlight?.id == request.id else { return nil }
        inFlight = nil
        if let targetSeconds, let targetPurpose,
           targetSeconds != request.seconds || targetPurpose != request.purpose || targetContextID != request.contextID {
            let next = Request(id: UUID(), seconds: targetSeconds, purpose: targetPurpose, contextID: targetContextID)
            inFlight = next
            return next
        }
        targetSeconds = nil
        targetPurpose = nil
        targetContextID = nil
        return nil
    }

    /// 準備前に受けた要求も、時間が判明した時点で範囲内へ収める。
    mutating func clampPending(duration: Double) {
        if let targetSeconds { self.targetSeconds = Self.clamped(targetSeconds, duration: duration) }
        if let inFlight, let seconds = Self.clamped(inFlight.seconds, duration: duration) {
            self.inFlight = Request(id: inFlight.id, seconds: seconds, purpose: inFlight.purpose, contextID: inFlight.contextID)
        }
    }

    mutating func reset() {
        inFlight = nil
        targetSeconds = nil
        targetPurpose = nil
        targetContextID = nil
    }
}
