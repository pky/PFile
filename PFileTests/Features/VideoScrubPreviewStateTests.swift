import XCTest
#if canImport(PFile)
@testable import PFile
#endif

final class VideoScrubPreviewStateTests: XCTestCase {
    func test_firstInputIsIssuedImmediately() throws {
        var state = VideoScrubPreviewState()
        state.beginSession()
        state.update(seconds: 10, duration: 100, now: 1)
        XCTAssertEqual(state.delay(now: 1), 0)
        XCTAssertEqual(try XCTUnwrap(state.takeRequest(now: 1)).seconds, 10)
        XCTAssertNil(state.takeRequest(now: 1))
    }

    func test_continuousInputIsCoalescedToLatestTarget() throws {
        var state = VideoScrubPreviewState()
        state.beginSession()
        state.update(seconds: 10, duration: 100, now: 0)
        _ = state.takeRequest(now: 0)
        state.update(seconds: 20, duration: 100, now: 0.02)
        state.update(seconds: 30, duration: 100, now: 0.04)
        XCTAssertEqual(try XCTUnwrap(state.delay(now: 0.04)), 0.06, accuracy: 0.0001)
        XCTAssertNil(state.takeRequest(now: 0.04))
        let latest = try XCTUnwrap(state.takeRequest(now: 0.11))
        XCTAssertEqual(latest.seconds, 30)
        XCTAssertEqual(latest.requestedAt, 0.04)
    }

    func test_continuousMovementKeepsIssuingRequests() throws {
        var state = VideoScrubPreviewState()
        state.beginSession()
        for index in 0..<10 {
            let time = Double(index) * 0.2
            state.update(seconds: Double(index) * 10, duration: 100, now: time)
            XCTAssertEqual(try XCTUnwrap(state.takeRequest(now: time)).seconds, Double(index) * 10)
        }
    }

    func test_tinyChangesDoNotFloodSeeksButDirectionChangeIsKept() throws {
        var state = VideoScrubPreviewState()
        state.beginSession()
        state.update(seconds: 10, duration: 100, now: 0)
        _ = state.takeRequest(now: 0)
        state.update(seconds: 10.1, duration: 100, now: 0.2)
        XCTAssertNil(state.delay(now: 0.2))
        state.update(seconds: 5, duration: 100, now: 0.3)
        XCTAssertEqual(try XCTUnwrap(state.takeRequest(now: 0.3)).seconds, 5)
    }

    func test_endInvalidatesPendingInputAndNewDragStartsImmediately() throws {
        var state = VideoScrubPreviewState()
        state.beginSession()
        state.update(seconds: 10, duration: 100, now: 0)
        let old = try XCTUnwrap(state.takeRequest(now: 0))
        state.update(seconds: 20, duration: 100, now: 0.01)
        state.endSession()
        XCTAssertNil(state.delay(now: 0.02))
        XCTAssertNil(state.takeRequest(now: 0.2))
        state.beginSession()
        state.update(seconds: 70, duration: 100, now: 0.02)
        let latest = try XCTUnwrap(state.takeRequest(now: 0.02))
        XCTAssertNotEqual(latest.sessionID, old.sessionID)
        XCTAssertEqual(latest.seconds, 70)
    }

    func test_invalidInputsDoNotOverwriteLatestValidInput() throws {
        var state = VideoScrubPreviewState()
        state.beginSession()
        state.update(seconds: 10, duration: 100, now: 0)
        state.update(seconds: .nan, duration: 100, now: 0.01)
        state.update(seconds: 90, duration: 100, now: .nan)
        XCTAssertNil(state.delay(now: .nan))
        XCTAssertEqual(try XCTUnwrap(state.takeRequest(now: 0.02)).seconds, 10)
    }

    func test_targetIsClampedBeforeIssuingPreview() throws {
        var state = VideoScrubPreviewState()
        state.beginSession()
        state.update(seconds: 200, duration: 100, now: 0)
        XCTAssertEqual(try XCTUnwrap(state.takeRequest(now: 0)).seconds, 100)
        state.update(seconds: -10, duration: 100, now: 0.2)
        XCTAssertEqual(try XCTUnwrap(state.takeRequest(now: 0.2)).seconds, 0)
    }

    func test_inputOutsideSessionDoesNotIssueSeek() {
        var state = VideoScrubPreviewState()
        state.update(seconds: 10, duration: 100, now: 0)
        XCTAssertNil(state.takeRequest(now: 0))
    }
}
