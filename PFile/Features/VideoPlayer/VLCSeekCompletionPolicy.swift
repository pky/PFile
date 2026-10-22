import Foundation

/// VLC には seek 完了通知がないため、時刻通知が目標の近傍に届いたか、
/// 制限時間を超えたかで完了とみなす。許容差は AVPlayer 経路の確定 seek（±1秒）と揃える。
enum VLCSeekCompletionPolicy {
    static let toleranceSeconds = 1.0
    static let timeoutSeconds = 1.5

    static func isCompleted(target: Double, observed: Double) -> Bool {
        guard target.isFinite, observed.isFinite else { return false }
        return abs(observed - target) <= toleranceSeconds
    }

    static func isTimedOut(issuedAt: TimeInterval, now: TimeInterval) -> Bool {
        guard issuedAt.isFinite, now.isFinite else { return false }
        return now - issuedAt >= timeoutSeconds
    }
}
