import Foundation

/// VLC には seek 完了通知がない。time を設定した直後に目標値がそのまま通知される（エコー）。
/// ドラッグ中のプレビュー seek はエコーで完了とみなす。目標値そのものなので前の seek 由来の
/// 古い通知と混同せず、デコード完了を待たないので追従が落ちない。
/// 指を離した後の pause 遅延だけは Tracker でエコー後の進行（デコード再開の証拠）か制限時間を待つ。
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

    /// time 設定直後に VLC が目標値をそのまま返す通知かどうか。
    static func isEcho(target: Double, observed: Double) -> Bool {
        guard target.isFinite, observed.isFinite else { return false }
        return abs(observed - target) < minimumAdvanceSeconds
    }

    /// seek 1 件分の完了追跡。ドラッグ中は再生を続けるため、前の seek 由来の古い時刻通知が
    /// 発行後にも届く。エコーを観測するまでは、どの通知も現在の seek に帰属できないので完了にしない。
    struct Tracker {
        let target: Double
        private(set) var hasObservedEcho = false

        init(target: Double) {
            self.target = target
        }

        /// 時刻通知を取り込み、現在の seek が完了したなら true を返す。
        mutating func observe(_ observed: Double) -> Bool {
            guard hasObservedEcho else {
                if VLCSeekCompletionPolicy.isEcho(target: target, observed: observed) {
                    hasObservedEcho = true
                }
                return false
            }
            return VLCSeekCompletionPolicy.isCompleted(target: target, observed: observed)
        }
    }
}
