import Foundation

/// VLC には seek 完了通知がない。time を設定した直後に目標値がそのまま通知されるので、
/// それは無視し、時刻が目標を越えて進んだ通知（デコード再開の証拠）か制限時間で完了とみなす。
/// 先読み上限は AVPlayer 経路の確定 seek（±1秒）と揃える。
enum VLCSeekCompletionPolicy {
    static let toleranceSeconds = 1.0
    static let minimumAdvanceSeconds = 0.01
    static let timeoutSeconds = 1.5

    static func isCompleted(target: Double, observed: Double) -> Bool {
        guard target.isFinite, observed.isFinite else { return false }
        let advance = observed - target
        return advance >= minimumAdvanceSeconds && advance <= toleranceSeconds
    }

    static func isTimedOut(issuedAt: TimeInterval, now: TimeInterval) -> Bool {
        guard issuedAt.isFinite, now.isFinite else { return false }
        return now - issuedAt >= timeoutSeconds
    }
}
