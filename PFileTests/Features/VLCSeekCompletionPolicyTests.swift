import XCTest
@testable import PFile

final class VLCSeekCompletionPolicyTests: XCTestCase {

    func test_constants_matchAVPlayerSeekTolerance() {
        XCTAssertEqual(VLCSeekCompletionPolicy.toleranceSeconds, 1.0)
        XCTAssertEqual(VLCSeekCompletionPolicy.timeoutSeconds, 1.5)
    }

    func test_isCompleted_whenObservedWithinTolerance() {
        XCTAssertTrue(VLCSeekCompletionPolicy.isCompleted(target: 100, observed: 100.9))
        XCTAssertTrue(VLCSeekCompletionPolicy.isCompleted(target: 100, observed: 99.1))
        XCTAssertTrue(VLCSeekCompletionPolicy.isCompleted(target: 100, observed: 101.0))
    }

    func test_isCompleted_whenObservedOutsideTolerance() {
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
