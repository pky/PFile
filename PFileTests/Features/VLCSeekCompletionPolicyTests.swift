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
}
