import Foundation

struct ScrubFrameStats {
    struct Summary: Equatable, Encodable {
        let durationMs: Int
        let seekCount: Int
        let advancedSeekCount: Int
        let effectiveSeekCount: Int
        let effectiveSeeksPerSecond: Double
        let advanceLatencyP50Ms: Int
        let advanceLatencyP90Ms: Int
        let effectiveLatencyP50Ms: Int
        let effectiveLatencyP90Ms: Int
        let displayedPictures: Int
        let lostPictures: Int
    }

    private struct Seek {
        let targetSeconds: Double
        let issuedAt: TimeInterval
        var hasAdvanced = false
        var isEffective = false
        var pictureBaseline: Int?
    }

    private let startedAt: TimeInterval?
    private var currentSeek: Seek?
    private var seekCount = 0
    private var advanceLatenciesMs: [Int] = []
    private var effectiveLatenciesMs: [Int] = []
    private var lastDisplayed: Int?
    private var lastLost: Int?
    private var displayedPictures = 0
    private var lostPictures = 0

    init(startedAt: TimeInterval) {
        self.startedAt = startedAt.isFinite ? startedAt : nil
    }

    mutating func recordSeekIssued(targetSeconds: Double, at: TimeInterval) {
        guard targetSeconds.isFinite, at.isFinite else { return }
        seekCount += 1
        currentSeek = Seek(targetSeconds: targetSeconds, issuedAt: at)
    }

    mutating func recordTime(observedSeconds: Double, at: TimeInterval) {
        guard observedSeconds.isFinite, at.isFinite,
              var seek = currentSeek, !seek.hasAdvanced else { return }
        let advance = observedSeconds - seek.targetSeconds
        guard advance >= VLCSeekCompletionPolicy.minimumAdvanceSeconds,
              advance <= VLCSeekCompletionPolicy.toleranceSeconds else { return }
        seek.hasAdvanced = true
        seek.pictureBaseline = lastDisplayed
        currentSeek = seek
        advanceLatenciesMs.append(Self.milliseconds(at - seek.issuedAt))
    }

    mutating func recordPictureCounts(displayed: Int, lost: Int, at: TimeInterval) {
        guard at.isFinite else { return }
        if let lastDisplayed, displayed > lastDisplayed {
            displayedPictures += displayed - lastDisplayed
        }
        if let lastLost, lost > lastLost {
            lostPictures += lost - lastLost
        }
        lastDisplayed = displayed
        lastLost = lost

        guard var seek = currentSeek, seek.hasAdvanced, !seek.isEffective else { return }
        if let baseline = seek.pictureBaseline {
            guard displayed > baseline else { return }
            seek.isEffective = true
            effectiveLatenciesMs.append(Self.milliseconds(at - seek.issuedAt))
        } else {
            // 前進前にサンプルがなければ、最初の値から増加を追跡する。
            seek.pictureBaseline = displayed
        }
        currentSeek = seek
    }

    func summary(endedAt: TimeInterval) -> Summary {
        let durationMs = startedAt.flatMap { start in
            endedAt.isFinite ? Self.milliseconds(endedAt - start) : nil
        } ?? 0
        return Summary(
            durationMs: durationMs,
            seekCount: seekCount,
            advancedSeekCount: advanceLatenciesMs.count,
            effectiveSeekCount: effectiveLatenciesMs.count,
            effectiveSeeksPerSecond: durationMs > 0
                ? Double(effectiveLatenciesMs.count) / (Double(durationMs) / 1000) : 0,
            advanceLatencyP50Ms: Self.percentile(advanceLatenciesMs, p: 0.5),
            advanceLatencyP90Ms: Self.percentile(advanceLatenciesMs, p: 0.9),
            effectiveLatencyP50Ms: Self.percentile(effectiveLatenciesMs, p: 0.5),
            effectiveLatencyP90Ms: Self.percentile(effectiveLatenciesMs, p: 0.9),
            displayedPictures: displayedPictures,
            lostPictures: lostPictures
        )
    }

    private static func milliseconds(_ seconds: TimeInterval) -> Int {
        let value = max(0, seconds * 1000)
        return value >= Double(Int.max) ? Int.max : Int(value)
    }

    private static func percentile(_ values: [Int], p: Double) -> Int {
        guard !values.isEmpty else { return -1 }
        let sorted = values.sorted()
        return sorted[max(0, Int(ceil(p * Double(sorted.count))) - 1)]
    }
}

struct ScrubFrameReport: Equatable, Encodable {
    let route: String
    let mediaDurationSeconds: Int
    let resolution: String?
    let networkCachingMs: Int?
    let inputs: Int
    let stats: ScrubFrameStats.Summary
}

struct PlaybackFrameReport: Equatable, Encodable {
    let route: String
    let mediaDurationSeconds: Int
    let resolution: String?
    let networkCachingMs: Int?
    let sessionMs: Int
    let displayedPictures: Int
    let lostPictures: Int
    let decodedVideo: Int
}
