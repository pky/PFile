import XCTest
@testable import PFile

final class VLCSeekCompletionPolicyTests: XCTestCase {

    func test_constants_matchAVPlayerSeekTolerance() {
        XCTAssertEqual(VLCSeekCompletionPolicy.toleranceSeconds, 1.0)
        XCTAssertEqual(VLCSeekCompletionPolicy.minimumAdvanceSeconds, 0.01)
        XCTAssertEqual(VLCSeekCompletionPolicy.timeoutSeconds, 1.5)
    }

    func test_isCompleted_whenTimeAdvancedPastTargetWithinTolerance() {
        XCTAssertTrue(VLCSeekCompletionPolicy.isCompleted(target: 100, observed: 100.02))
        XCTAssertTrue(VLCSeekCompletionPolicy.isCompleted(target: 100, observed: 100.5))
        XCTAssertTrue(VLCSeekCompletionPolicy.isCompleted(target: 100, observed: 101.0))
    }

    func test_isCompleted_ignoresImmediateEchoOfTarget() {
        // VLC は time 設定直後に目標値をそのまま通知する。デコード再開の証拠にならない。
        XCTAssertFalse(VLCSeekCompletionPolicy.isCompleted(target: 100, observed: 100))
        XCTAssertFalse(VLCSeekCompletionPolicy.isCompleted(target: 100, observed: 100.005))
    }

    func test_isCompleted_whenObservedBehindOrFarAhead() {
        XCTAssertFalse(VLCSeekCompletionPolicy.isCompleted(target: 100, observed: 99.9))
        XCTAssertFalse(VLCSeekCompletionPolicy.isCompleted(target: 100, observed: 101.1))
        XCTAssertFalse(VLCSeekCompletionPolicy.isCompleted(target: 100, observed: 50))
        XCTAssertFalse(VLCSeekCompletionPolicy.isCompleted(target: 100, observed: .nan))
    }

    func test_isTimedOut_afterTimeout() {
        XCTAssertFalse(VLCSeekCompletionPolicy.isTimedOut(issuedAt: 10, now: 11.4))
        XCTAssertTrue(VLCSeekCompletionPolicy.isTimedOut(issuedAt: 10, now: 11.5))
        XCTAssertTrue(VLCSeekCompletionPolicy.isTimedOut(issuedAt: 10, now: 20))
    }

    func test_isEcho_matchesTargetWithinMinimumAdvance() {
        // 目標値そのままの通知だけをエコーとし、0.01 秒以上離れた通知を進行として区別するため。
        XCTAssertTrue(VLCSeekCompletionPolicy.isEcho(target: 100, observed: 100))
        XCTAssertTrue(VLCSeekCompletionPolicy.isEcho(target: 100, observed: 100.005))
        XCTAssertTrue(VLCSeekCompletionPolicy.isEcho(target: 100, observed: 99.995))
        XCTAssertFalse(VLCSeekCompletionPolicy.isEcho(target: 100, observed: 100.01))
        XCTAssertFalse(VLCSeekCompletionPolicy.isEcho(target: 100, observed: 99.99))
        XCTAssertFalse(VLCSeekCompletionPolicy.isEcho(target: 100, observed: .nan))
    }

    func test_tracker_ignoresProgressBeforeEcho() {
        // エコー前の通知は前の seek 由来かもしれず、現在の seek の完了証拠にならないため。
        var tracker = VLCSeekCompletionPolicy.Tracker(target: 99.5)
        XCTAssertFalse(tracker.observe(100.4))
        XCTAssertFalse(tracker.hasObservedEcho)
        XCTAssertFalse(tracker.observe(100.6))
    }

    func test_tracker_completesAfterEchoThenAdvance() {
        // エコーで seek 帰属が確定した後の時刻進行を完了とする正常系のため。
        var tracker = VLCSeekCompletionPolicy.Tracker(target: 99.5)
        XCTAssertFalse(tracker.observe(99.5))
        XCTAssertTrue(tracker.hasObservedEcho)
        XCTAssertTrue(tracker.observe(99.75))
    }

    func test_tracker_echoAloneDoesNotComplete() {
        // エコーはデコード再開の証拠ではないので、エコーだけでは完了にしないため。
        var tracker = VLCSeekCompletionPolicy.Tracker(target: 100)
        XCTAssertFalse(tracker.observe(100))
        XCTAssertFalse(tracker.observe(100.005))
        XCTAssertFalse(tracker.observe(100.0))
    }

    func test_tracker_afterEcho_rejectsObservedBehindOrFarAhead() {
        // エコー後も後方や先読み上限超えの通知は従来どおり完了にしない境界のため。
        var tracker = VLCSeekCompletionPolicy.Tracker(target: 99.5)
        XCTAssertFalse(tracker.observe(99.5))
        XCTAssertFalse(tracker.observe(99.4))
        XCTAssertFalse(tracker.observe(101.0))
        XCTAssertTrue(tracker.observe(100.5))
    }

    func test_tracker_backwardScrubScenario_staleNotificationsDoNotComplete() {
        // 後方スクラブ時に前の seek 由来の古い通知で誤完了し、次の seek が早く出る不具合の再現のため。
        var tracker = VLCSeekCompletionPolicy.Tracker(target: 99.5)
        XCTAssertFalse(tracker.observe(100.4))
        XCTAssertFalse(tracker.observe(100.6))
        XCTAssertFalse(tracker.observe(99.5))
        XCTAssertTrue(tracker.observe(99.6))
    }
}
