import XCTest
#if canImport(PFile)
@testable import PFile
#endif

final class VideoPlaybackControlStateTests: XCTestCase {
    func test_stallKeepsIntentAndResumesOnlyWithData() {
        var state = VideoPlaybackIntentState()
        state.started()
        state.stalled()
        XCTAssertTrue(state.intendsToPlay)
        XCTAssertTrue(state.isWaitingForData)
        XCTAssertFalse(state.resumeIfPossible(hasData: false, isReady: true, isSeeking: false))
        XCTAssertTrue(state.resumeIfPossible(hasData: true, isReady: true, isSeeking: false))
        XCTAssertFalse(state.resumeIfPossible(hasData: true, isReady: true, isSeeking: false))
    }

    func test_explicitPausePreventsRecovery() {
        var state = VideoPlaybackIntentState()
        state.started()
        state.stalled()
        state.pause()
        state.stalled()
        XCTAssertFalse(state.intendsToPlay)
        XCTAssertFalse(state.resumeIfPossible(hasData: true, isReady: true, isSeeking: false))
    }

    func test_recoveryWaitsForReadinessAndSeekCompletion() {
        var state = VideoPlaybackIntentState()
        state.started()
        state.stalled()
        XCTAssertFalse(state.resumeIfPossible(hasData: true, isReady: false, isSeeking: false))
        XCTAssertFalse(state.resumeIfPossible(hasData: true, isReady: true, isSeeking: true))
        XCTAssertTrue(state.resumeIfPossible(hasData: true, isReady: true, isSeeking: false))
    }

    func test_endAndTeardownPreventRecovery() {
        var state = VideoPlaybackIntentState()
        state.started()
        state.stalled()
        state.ended()
        XCTAssertFalse(state.resumeIfPossible(hasData: true, isReady: true, isSeeking: false))
        state.play()
        XCTAssertTrue(state.intendsToPlay)
        state.tearDown()
        state.play()
        state.stalled()
        XCTAssertFalse(state.intendsToPlay)
        XCTAssertFalse(state.resumeIfPossible(hasData: true, isReady: true, isSeeking: false))
    }

    func test_initialEmptyBufferRecoversAfterPlayRequest() {
        var state = VideoPlaybackIntentState()
        state.stalled()
        XCTAssertFalse(state.isWaitingForData)
        // 初回の再生要求時に開始を記録し、通知がない場合も空バッファを確認する。
        state.started()
        state.stalled()
        XCTAssertTrue(state.resumeIfPossible(hasData: true, isReady: true, isSeeking: false))
    }

    func test_dragSuspensionPreservesIntentAndExplicitPauseWins() {
        var state = VideoPlaybackIntentState()
        state.started()
        state.beginInteractiveSeek()
        state.stalled()
        XCTAssertTrue(state.intendsToPlay)
        XCTAssertFalse(state.resumeIfPossible(hasData: true, isReady: true, isSeeking: false))
        state.pause()
        state.endInteractiveSeek()
        XCTAssertFalse(state.intendsToPlay)
        XCTAssertFalse(state.resumeIfPossible(hasData: true, isReady: true, isSeeking: false))
    }

    func test_explicitPlayDuringPausedDragIsKeptUntilRelease() {
        var state = VideoPlaybackIntentState()
        state.started()
        state.pause()
        state.beginInteractiveSeek()
        state.play()
        state.stalled()
        XCTAssertFalse(state.resumeIfPossible(hasData: true, isReady: true, isSeeking: false))
        state.endInteractiveSeek()
        XCTAssertTrue(state.intendsToPlay)
        XCTAssertTrue(state.resumeIfPossible(hasData: true, isReady: true, isSeeking: false))
    }

    func test_skipAccumulatesAndCoalescesWhileSeekIsInFlight() throws {
        var state = VideoSeekState()
        let first = try XCTUnwrap(state.skip(delta: 60, currentSeconds: 120, duration: 1000))
        XCTAssertEqual(first.seconds, 180)
        XCTAssertNil(state.skip(delta: 60, currentSeconds: 120, duration: 1000))
        XCTAssertNil(state.skip(delta: 60, currentSeconds: 120, duration: 1000))
        XCTAssertEqual(state.inFlight, first)
        let latest = try XCTUnwrap(state.complete(first))
        XCTAssertEqual(latest.seconds, 300)
        XCTAssertNil(state.complete(latest))
        XCTAssertNil(state.targetSeconds)
    }

    func test_mixedSkipsUseLatestTargetAndClampAtBothEnds() throws {
        var state = VideoSeekState()
        let first = try XCTUnwrap(state.skip(delta: 60, currentSeconds: 90, duration: 100))
        XCTAssertEqual(first.seconds, 100)
        XCTAssertNil(state.skip(delta: -60, currentSeconds: 90, duration: 100))
        XCTAssertEqual(state.targetSeconds, 40)
        XCTAssertNil(state.skip(delta: -60, currentSeconds: 90, duration: 100))
        XCTAssertEqual(state.targetSeconds, 0)
        XCTAssertEqual(state.complete(first)?.seconds, 0)
    }

    func test_returnToOriginalTargetNeedsNoDuplicateSeek() throws {
        var state = VideoSeekState()
        let first = try XCTUnwrap(state.request(seconds: 60, duration: 1000))
        XCTAssertNil(state.request(seconds: 80, duration: 1000))
        XCTAssertNil(state.request(seconds: 60, duration: 1000))
        XCTAssertNil(state.complete(first))
        XCTAssertNil(state.inFlight)
    }

    func test_invalidTargetsDoNotOverwritePendingSeek() throws {
        var state = VideoSeekState()
        let first = try XCTUnwrap(state.request(seconds: 60, duration: 100))
        XCTAssertNil(state.request(seconds: .nan, duration: 100))
        XCTAssertNil(state.request(seconds: .infinity, duration: 100))
        XCTAssertNil(state.skip(delta: -.infinity, currentSeconds: 10, duration: 100))
        XCTAssertEqual(state.targetSeconds, 60)
        XCTAssertEqual(state.inFlight, first)
        XCTAssertNotNil(VideoSeekState.clamped(1e100, duration: .nan))
    }

    func test_staleCompletionCannotClearNewSeekAfterReset() throws {
        var state = VideoSeekState()
        let old = try XCTUnwrap(state.request(seconds: 60, duration: 1000))
        state.reset()
        let latest = try XCTUnwrap(state.request(seconds: 120, duration: 1000))
        XCTAssertNil(state.complete(old))
        XCTAssertEqual(state.inFlight, latest)
        XCTAssertEqual(state.targetSeconds, 120)
    }

    func test_readyDurationClampsRequestsReceivedBeforePreparation() throws {
        var state = VideoSeekState()
        let first = try XCTUnwrap(state.request(seconds: 600, duration: 0))
        XCTAssertNil(state.request(seconds: 900, duration: 0))
        state.clampPending(duration: 100)
        let clamped = try XCTUnwrap(state.inFlight)
        XCTAssertEqual(clamped.id, first.id)
        XCTAssertEqual(clamped.seconds, 100)
        XCTAssertEqual(state.targetSeconds, 100)
        XCTAssertNil(state.complete(clamped))
    }
    func test_previewThenFinalAtSamePositionMustRunFinalSeek() throws {
        var state = VideoSeekState()
        let session = UUID()
        let preview = try XCTUnwrap(state.request(seconds: 60, duration: 100, purpose: .scrubPreview, contextID: session))
        XCTAssertNil(state.request(seconds: 60, duration: 100))
        let final = try XCTUnwrap(state.complete(preview))
        XCTAssertEqual(final.seconds, 60)
        XCTAssertEqual(final.purpose, .playback)
        XCTAssertNil(final.contextID)
        XCTAssertNil(state.complete(final))
    }

    func test_previewInputsKeepOnlyLatestWhileOneSeekRuns() throws {
        var state = VideoSeekState()
        let session = UUID()
        let first = try XCTUnwrap(state.request(seconds: 10, duration: 100, purpose: .scrubPreview, contextID: session))
        for seconds in [20.0, 30.0, 40.0] {
            XCTAssertNil(state.request(seconds: seconds, duration: 100, purpose: .scrubPreview, contextID: session))
        }
        XCTAssertEqual(state.inFlight, first)
        let latest = try XCTUnwrap(state.complete(first))
        XCTAssertEqual(latest.seconds, 40)
        XCTAssertEqual(latest.purpose, .scrubPreview)
        XCTAssertEqual(latest.contextID, session)
    }

    func test_newDragAtSamePositionDoesNotReuseOldSessionCompletion() throws {
        var state = VideoSeekState()
        let oldSession = UUID()
        let old = try XCTUnwrap(state.request(seconds: 60, duration: 100, purpose: .scrubPreview, contextID: oldSession))
        let newSession = UUID()
        XCTAssertNil(state.request(seconds: 60, duration: 100, purpose: .scrubPreview, contextID: newSession))
        let latest = try XCTUnwrap(state.complete(old))
        XCTAssertEqual(latest.contextID, newSession)
        XCTAssertNotEqual(latest.id, old.id)
    }

    func test_skipDuringPreviewUsesLatestTargetAndPlaybackPurpose() throws {
        var state = VideoSeekState()
        let preview = try XCTUnwrap(state.request(seconds: 60, duration: 200, purpose: .scrubPreview, contextID: UUID()))
        XCTAssertNil(state.skip(delta: 10, currentSeconds: 40, duration: 200))
        XCTAssertNil(state.skip(delta: 10, currentSeconds: 40, duration: 200))
        let next = try XCTUnwrap(state.complete(preview))
        XCTAssertEqual(next.seconds, 80)
        XCTAssertEqual(next.purpose, .playback)
    }

    func test_readyClampPreservesPreviewPurposeAndSession() throws {
        var state = VideoSeekState()
        let session = UUID()
        let preview = try XCTUnwrap(state.request(seconds: 600, duration: 0, purpose: .scrubPreview, contextID: session))
        state.clampPending(duration: 100)
        let clamped = try XCTUnwrap(state.inFlight)
        XCTAssertEqual(clamped.id, preview.id)
        XCTAssertEqual(clamped.seconds, 100)
        XCTAssertEqual(clamped.purpose, .scrubPreview)
        XCTAssertEqual(clamped.contextID, session)
    }

    func test_oldPreviewCompletionCannotClearFinalAfterReset() throws {
        var state = VideoSeekState()
        let old = try XCTUnwrap(state.request(seconds: 60, duration: 100, purpose: .scrubPreview, contextID: UUID()))
        state.reset()
        let final = try XCTUnwrap(state.request(seconds: 60, duration: 100))
        XCTAssertNil(state.complete(old))
        XCTAssertEqual(state.inFlight, final)
    }

}
