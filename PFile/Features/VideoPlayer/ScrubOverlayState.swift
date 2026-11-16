import Foundation

struct ScrubOverlayState: Equatable {
    enum Phase: Equatable {
        case idle
        case dragging
        case settling(target: Double, startedAt: TimeInterval, hasObservedEcho: Bool)
    }

    enum HideReason: String, Equatable {
        case vlcCaughtUp, timeout, cancelled, noPreviewFrame, superseded
    }

    static let settleTimeoutSeconds: TimeInterval = 3.0

    private(set) var phase: Phase = .idle
    private(set) var hasPreviewFrame = false
    private(set) var lastHideReason: HideReason?

    var isOverlayVisible: Bool { phase != .idle && hasPreviewFrame }
    var suppressesVLCScrubSeeks: Bool { phase == .dragging }

    mutating func beginDrag() {
        if phase == .idle { hasPreviewFrame = false }
        phase = .dragging
    }

    mutating func previewSeekCompleted(finished: Bool) {
        guard phase != .idle, finished else { return }
        hasPreviewFrame = true
    }

    mutating func endDrag(target: Double, at: TimeInterval) {
        guard phase == .dragging else { return }
        guard target.isFinite, at.isFinite else {
            cancel()
            return
        }
        guard hasPreviewFrame else {
            hide(reason: .noPreviewFrame)
            return
        }
        phase = .settling(target: target, startedAt: at, hasObservedEcho: false)
    }

    mutating func observeVLC(seconds: Double) {
        guard case let .settling(target, startedAt, hasObservedEcho) = phase,
              seconds.isFinite else { return }
        let isEcho = VLCSeekCompletionPolicy.isEcho(target: target, observed: seconds)
        if !hasObservedEcho {
            if isEcho {
                phase = .settling(target: target, startedAt: startedAt, hasObservedEcho: true)
            }
        } else if !isEcho {
            hide(reason: .vlcCaughtUp)
        }
    }

    mutating func checkTimeout(now: TimeInterval) {
        guard case let .settling(_, startedAt, _) = phase, now.isFinite,
              now - startedAt >= Self.settleTimeoutSeconds else { return }
        hide(reason: .timeout)
    }

    mutating func cancel() {
        guard phase != .idle else { return }
        hide(reason: .cancelled)
    }

    private mutating func hide(reason: HideReason) {
        phase = .idle
        hasPreviewFrame = false
        lastHideReason = reason
    }
}

struct ScrubOverlayStats {
    struct Summary: Equatable, Encodable {
        let inputs: Int
        let previewSeeks: Int
        let previewCompleted: Int
        let previewFinished: Int
        let previewLatencyP50Ms: Int
        let previewLatencyP90Ms: Int
        let firstFrameMs: Int
        let settleMs: Int
        let hideReason: String
    }

    private let startedAt: TimeInterval?
    private var inputs = 0
    private var previewSeeks = 0
    private var previewCompleted = 0
    private var previewLatenciesMs: [Int] = []
    private var firstFrameAt: TimeInterval?
    private var dragEndedAt: TimeInterval?

    init(startedAt: TimeInterval) {
        self.startedAt = startedAt.isFinite ? startedAt : nil
    }

    mutating func recordInput() { inputs += 1 }

    mutating func recordPreviewSeekIssued() { previewSeeks += 1 }

    mutating func recordPreviewSeekCompleted(finished: Bool, latencyMs: Int, at: TimeInterval) {
        previewCompleted += 1
        guard finished else { return }
        previewLatenciesMs.append(max(0, latencyMs))
        if firstFrameAt == nil, at.isFinite { firstFrameAt = at }
    }

    mutating func recordDragEnded(at: TimeInterval) {
        if at.isFinite { dragEndedAt = at }
    }

    func summary(endedAt: TimeInterval, hideReason: ScrubOverlayState.HideReason?) -> Summary {
        Summary(
            inputs: inputs,
            previewSeeks: previewSeeks,
            previewCompleted: previewCompleted,
            previewFinished: previewLatenciesMs.count,
            previewLatencyP50Ms: Self.percentile(previewLatenciesMs, p: 0.5),
            previewLatencyP90Ms: Self.percentile(previewLatenciesMs, p: 0.9),
            firstFrameMs: Self.elapsedMilliseconds(from: startedAt, to: firstFrameAt),
            settleMs: Self.elapsedMilliseconds(from: dragEndedAt, to: endedAt),
            hideReason: hideReason?.rawValue ?? "none"
        )
    }

    private static func elapsedMilliseconds(from start: TimeInterval?, to end: TimeInterval?) -> Int {
        guard let start, let end, end.isFinite else { return -1 }
        let value = max(0, (end - start) * 1000)
        return value >= Double(Int.max) ? Int.max : Int(value)
    }

    private static func percentile(_ values: [Int], p: Double) -> Int {
        guard !values.isEmpty else { return -1 }
        let sorted = values.sorted()
        return sorted[max(0, Int(ceil(p * Double(sorted.count))) - 1)]
    }
}
