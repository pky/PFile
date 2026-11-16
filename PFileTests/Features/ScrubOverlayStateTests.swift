import XCTest
@testable import PFile

final class ScrubOverlayStateTests: XCTestCase {

    func test_beginDragFromIdleSuppressesSeeksWithoutShowingOverlay() {
        var state = ScrubOverlayState()
        XCTAssertEqual(state.phase, .idle)
        XCTAssertFalse(state.hasPreviewFrame)
        XCTAssertFalse(state.isOverlayVisible)
        XCTAssertFalse(state.suppressesVLCScrubSeeks)
        XCTAssertNil(state.lastHideReason)

        state.beginDrag()

        XCTAssertEqual(state.phase, .dragging)
        XCTAssertFalse(state.hasPreviewFrame)
        XCTAssertFalse(state.isOverlayVisible)
        XCTAssertTrue(state.suppressesVLCScrubSeeks)
    }

    func test_previewCompletionShowsOverlayOnlyWhenFinished() {
        var state = ScrubOverlayState()
        state.beginDrag()
        state.previewSeekCompleted(finished: false)
        XCTAssertFalse(state.hasPreviewFrame)
        XCTAssertFalse(state.isOverlayVisible)

        state.previewSeekCompleted(finished: true)
        XCTAssertTrue(state.hasPreviewFrame)
        XCTAssertTrue(state.isOverlayVisible)
        XCTAssertEqual(state.phase, .dragging)

        let visible = state
        state.previewSeekCompleted(finished: false)
        XCTAssertEqual(state, visible)
    }

    func test_previewCompletionInIdleDoesNotChangeState() {
        var state = ScrubOverlayState()
        state.beginDrag()
        state.cancel()
        let idle = state

        state.previewSeekCompleted(finished: true)
        XCTAssertEqual(state, idle)
        state.previewSeekCompleted(finished: false)
        XCTAssertEqual(state, idle)
    }

    func test_endDragKeepsOverlayVisibleAndReleasesSeekSuppression() {
        var state = ScrubOverlayState()
        state.beginDrag()
        state.previewSeekCompleted(finished: true)
        state.endDrag(target: 10, at: 2)

        XCTAssertEqual(state.phase, .settling(target: 10, startedAt: 2, hasObservedEcho: false))
        XCTAssertTrue(state.hasPreviewFrame)
        XCTAssertTrue(state.isOverlayVisible)
        XCTAssertFalse(state.suppressesVLCScrubSeeks)

        let settling = state
        state.previewSeekCompleted(finished: false)
        XCTAssertEqual(state, settling)
        state.previewSeekCompleted(finished: true)
        XCTAssertEqual(state, settling)
    }

    func test_endDragWithoutPreviewFrameReturnsToIdle() {
        var state = ScrubOverlayState()
        state.beginDrag()
        state.previewSeekCompleted(finished: false)
        state.endDrag(target: 10, at: 2)

        XCTAssertEqual(state.phase, .idle)
        XCTAssertFalse(state.hasPreviewFrame)
        XCTAssertFalse(state.isOverlayVisible)
        XCTAssertFalse(state.suppressesVLCScrubSeeks)
        XCTAssertEqual(state.lastHideReason, .noPreviewFrame)
    }

    func test_endDragOutsideDraggingDoesNotChangeState() {
        var state = ScrubOverlayState()
        let idle = state
        state.endDrag(target: 10, at: 2)
        XCTAssertEqual(state, idle)

        state.beginDrag()
        state.previewSeekCompleted(finished: true)
        state.endDrag(target: 10, at: 2)
        let settling = state
        state.endDrag(target: 20, at: 3)
        XCTAssertEqual(state, settling)
        state.endDrag(target: .nan, at: .infinity)
        XCTAssertEqual(state, settling)
    }

    func test_vlcNonEchoIsIgnoredUntilEchoThenHidesOverlay() {
        // 後退や許容範囲外の通知も、エコー後なら仕様上は非エコーとして扱う。
        for observed in [9.5, 10.5, 12.0] {
            var state = ScrubOverlayState()
            state.beginDrag()
            state.previewSeekCompleted(finished: true)
            state.endDrag(target: 10, at: 2)
            let beforeEcho = state

            state.observeVLC(seconds: observed)
            XCTAssertEqual(state, beforeEcho)
            state.observeVLC(seconds: 10)
            XCTAssertEqual(state.phase, .settling(target: 10, startedAt: 2, hasObservedEcho: true))
            XCTAssertTrue(state.isOverlayVisible)
            state.observeVLC(seconds: 10)
            XCTAssertTrue(state.isOverlayVisible)

            state.observeVLC(seconds: observed)
            XCTAssertEqual(state.phase, .idle)
            XCTAssertFalse(state.hasPreviewFrame)
            XCTAssertFalse(state.isOverlayVisible)
            XCTAssertFalse(state.suppressesVLCScrubSeeks)
            XCTAssertEqual(state.lastHideReason, .vlcCaughtUp)
        }
    }

    func test_vlcEchoUsesPolicyBoundary() {
        var state = ScrubOverlayState()
        state.beginDrag()
        state.previewSeekCompleted(finished: true)
        state.endDrag(target: 0, at: 2)

        state.observeVLC(seconds: VLCSeekCompletionPolicy.minimumAdvanceSeconds.nextDown)
        XCTAssertEqual(state.phase, .settling(target: 0, startedAt: 2, hasObservedEcho: true))
        XCTAssertTrue(state.isOverlayVisible)

        state.observeVLC(seconds: VLCSeekCompletionPolicy.minimumAdvanceSeconds)
        XCTAssertEqual(state.phase, .idle)
        XCTAssertEqual(state.lastHideReason, .vlcCaughtUp)
    }

    func test_timeoutHidesOverlayAtThreeSecondsOrLater() {
        XCTAssertEqual(ScrubOverlayState.settleTimeoutSeconds, 3.0)
        for now in [5.0, 6.0] {
            var state = ScrubOverlayState()
            state.beginDrag()
            state.previewSeekCompleted(finished: true)
            state.endDrag(target: 10, at: 2)
            let settling = state

            state.checkTimeout(now: 5.0.nextDown)
            XCTAssertEqual(state, settling)
            state.checkTimeout(now: now)
            XCTAssertEqual(state.phase, .idle)
            XCTAssertFalse(state.hasPreviewFrame)
            XCTAssertFalse(state.isOverlayVisible)
            XCTAssertFalse(state.suppressesVLCScrubSeeks)
            XCTAssertEqual(state.lastHideReason, .timeout)
        }
    }

    func test_beginDragDuringSettlingKeepsPreviewAndResetsEcho() {
        var state = ScrubOverlayState()
        state.beginDrag()
        state.previewSeekCompleted(finished: true)
        state.endDrag(target: 10, at: 2)
        state.observeVLC(seconds: 10)

        state.beginDrag()
        XCTAssertEqual(state.phase, .dragging)
        XCTAssertTrue(state.hasPreviewFrame)
        XCTAssertTrue(state.isOverlayVisible)
        XCTAssertTrue(state.suppressesVLCScrubSeeks)

        state.endDrag(target: 20, at: 3)
        state.observeVLC(seconds: 20.5)
        XCTAssertEqual(state.phase, .settling(target: 20, startedAt: 3, hasObservedEcho: false))
        XCTAssertTrue(state.isOverlayVisible)
    }

    func test_repeatedBeginDragPreservesFrameAndLastHideReason() {
        var state = ScrubOverlayState()
        state.beginDrag()
        state.cancel()
        state.beginDrag()
        XCTAssertEqual(state.lastHideReason, .cancelled)
        XCTAssertFalse(state.hasPreviewFrame)
        state.previewSeekCompleted(finished: true)
        let dragging = state

        state.beginDrag()
        XCTAssertEqual(state, dragging)

        state.endDrag(target: 10, at: 2)
        state.beginDrag()
        XCTAssertEqual(state, dragging)
    }

    func test_cancelClearsDraggingOrSettlingAndIdleCancelPreservesReason() {
        for settling in [false, true] {
            var state = ScrubOverlayState()
            let initial = state
            state.cancel()
            XCTAssertEqual(state, initial)
            state.beginDrag()
            state.previewSeekCompleted(finished: true)
            if settling {
                state.endDrag(target: 10, at: 2)
            }

            state.cancel()
            XCTAssertEqual(state.phase, .idle)
            XCTAssertFalse(state.hasPreviewFrame)
            XCTAssertFalse(state.isOverlayVisible)
            XCTAssertFalse(state.suppressesVLCScrubSeeks)
            XCTAssertEqual(state.lastHideReason, .cancelled)
            let cancelled = state
            state.cancel()
            XCTAssertEqual(state, cancelled)
        }

        var state = ScrubOverlayState()
        state.beginDrag()
        state.endDrag(target: 10, at: 2)
        let noFrame = state
        state.cancel()
        XCTAssertEqual(state, noFrame)
    }

    func test_nonFiniteEndDragArgumentsCancelEvenWithoutPreviewFrame() {
        for invalid in [Double.nan, .infinity, -.infinity] {
            for hasFrame in [false, true] {
                for invalidTarget in [false, true] {
                    var state = ScrubOverlayState()
                    state.beginDrag()
                    state.previewSeekCompleted(finished: hasFrame)
                    var cancelled = state
                    cancelled.cancel()

                    state.endDrag(target: invalidTarget ? invalid : 10, at: invalidTarget ? 2 : invalid)
                    XCTAssertEqual(state, cancelled)
                    XCTAssertEqual(state.lastHideReason, .cancelled)
                }
            }
        }
    }

    func test_nonFiniteObservationsAndTimeoutsDoNotChangeSettlingState() {
        for invalid in [Double.nan, .infinity, -.infinity] {
            var state = ScrubOverlayState()
            state.beginDrag()
            state.previewSeekCompleted(finished: true)
            state.endDrag(target: 10, at: 2)
            let beforeEcho = state

            state.observeVLC(seconds: invalid)
            XCTAssertEqual(state, beforeEcho)
            state.checkTimeout(now: invalid)
            XCTAssertEqual(state, beforeEcho)

            state.observeVLC(seconds: 10)
            let afterEcho = state
            state.observeVLC(seconds: invalid)
            XCTAssertEqual(state, afterEcho)
            state.checkTimeout(now: invalid)
            XCTAssertEqual(state, afterEcho)
            state.observeVLC(seconds: 10.5)
            XCTAssertEqual(state.lastHideReason, .vlcCaughtUp)
        }
    }

    func test_observationAndTimeoutOutsideSettlingDoNotChangeState() {
        var state = ScrubOverlayState()
        let idle = state
        state.observeVLC(seconds: 10)
        state.checkTimeout(now: 100)
        XCTAssertEqual(state, idle)

        state.beginDrag()
        state.previewSeekCompleted(finished: true)
        let dragging = state
        state.observeVLC(seconds: 10)
        state.observeVLC(seconds: 10.5)
        state.checkTimeout(now: 100)
        XCTAssertEqual(state, dragging)
    }
}

final class ScrubOverlayStatsTests: XCTestCase {

    func test_emptySummaryHasZeroCountsAndMissingMeasurements() {
        let summary = ScrubOverlayStats(startedAt: 0).summary(endedAt: 1, hideReason: nil)

        XCTAssertEqual(summary.inputs, 0)
        XCTAssertEqual(summary.previewSeeks, 0)
        XCTAssertEqual(summary.previewCompleted, 0)
        XCTAssertEqual(summary.previewFinished, 0)
        XCTAssertEqual(summary.previewLatencyP50Ms, -1)
        XCTAssertEqual(summary.previewLatencyP90Ms, -1)
        XCTAssertEqual(summary.firstFrameMs, -1)
        XCTAssertEqual(summary.settleMs, -1)
        XCTAssertEqual(summary.hideReason, "none")
    }

    func test_countsTrackInputsSeeksAndBothCompletionResults() {
        var stats = ScrubOverlayStats(startedAt: 0)
        for _ in 0..<4 { stats.recordInput() }
        for _ in 0..<3 { stats.recordPreviewSeekIssued() }
        stats.recordPreviewSeekCompleted(finished: false, latencyMs: 10, at: 0.1)
        stats.recordPreviewSeekCompleted(finished: true, latencyMs: 20, at: 0.2)

        let summary = stats.summary(endedAt: 1, hideReason: nil)
        XCTAssertEqual(summary.inputs, 4)
        XCTAssertEqual(summary.previewSeeks, 3)
        XCTAssertEqual(summary.previewCompleted, 2)
        XCTAssertEqual(summary.previewFinished, 1)
    }

    func test_previewLatencyUsesNearestRankAndExcludesUnfinishedCompletions() {
        var stats = ScrubOverlayStats(startedAt: 0)
        // 到着順を崩し、補間せず順位で選ぶことと失敗した完了の除外を確かめる。
        for latency in [30, 10, 40, 20] {
            stats.recordPreviewSeekCompleted(finished: true, latencyMs: latency, at: 0.1)
        }
        stats.recordPreviewSeekCompleted(finished: false, latencyMs: 0, at: 0.2)
        stats.recordPreviewSeekCompleted(finished: false, latencyMs: 1000, at: 0.3)

        let summary = stats.summary(endedAt: 1, hideReason: nil)
        XCTAssertEqual(summary.previewLatencyP50Ms, 20)
        XCTAssertEqual(summary.previewLatencyP90Ms, 40)
    }

    func test_negativePreviewLatencyIsClampedAndUnfinishedOnlyHasNoLatency() {
        var stats = ScrubOverlayStats(startedAt: 0)
        stats.recordPreviewSeekCompleted(finished: false, latencyMs: 10, at: 0.1)
        let unfinished = stats.summary(endedAt: 1, hideReason: nil)
        XCTAssertEqual(unfinished.previewLatencyP50Ms, -1)
        XCTAssertEqual(unfinished.previewLatencyP90Ms, -1)
        XCTAssertEqual(unfinished.firstFrameMs, -1)

        stats.recordPreviewSeekCompleted(finished: true, latencyMs: -10, at: 0.2)
        let finished = stats.summary(endedAt: 1, hideReason: nil)
        XCTAssertEqual(finished.previewLatencyP50Ms, 0)
        XCTAssertEqual(finished.previewLatencyP90Ms, 0)
    }

    func test_firstFrameUsesFirstFinishedCompletionAndTruncatesMilliseconds() {
        var stats = ScrubOverlayStats(startedAt: 1)
        stats.recordPreviewSeekCompleted(finished: false, latencyMs: 10, at: 1.0105)
        XCTAssertEqual(stats.summary(endedAt: 2, hideReason: nil).firstFrameMs, -1)
        stats.recordPreviewSeekCompleted(finished: true, latencyMs: 20, at: 1.0405)
        XCTAssertEqual(stats.summary(endedAt: 2, hideReason: nil).firstFrameMs, 40)

        // 後から届いた完了の時刻が早くても、最初に記録した成功を保持する。
        stats.recordPreviewSeekCompleted(finished: true, latencyMs: 10, at: 1.0205)
        XCTAssertEqual(stats.summary(endedAt: 3, hideReason: nil).firstFrameMs, 40)
    }

    func test_firstFrameBeforeStartIsClampedToZero() {
        var stats = ScrubOverlayStats(startedAt: 2)
        stats.recordPreviewSeekCompleted(finished: true, latencyMs: 10, at: 1)

        XCTAssertEqual(stats.summary(endedAt: 3, hideReason: nil).firstFrameMs, 0)
    }

    func test_settleDurationStartsAtDragEnd() {
        var stats = ScrubOverlayStats(startedAt: 0)
        XCTAssertEqual(stats.summary(endedAt: 4, hideReason: nil).settleMs, -1)
        stats.recordDragEnded(at: 2)

        XCTAssertEqual(stats.summary(endedAt: 2, hideReason: nil).settleMs, 0)
        XCTAssertEqual(stats.summary(endedAt: 4, hideReason: nil).settleMs, 2000)
    }

    func test_hideReasonUsesSpecifiedStrings() {
        let stats = ScrubOverlayStats(startedAt: 0)
        let cases: [(ScrubOverlayState.HideReason?, String)] = [
            (.vlcCaughtUp, "vlcCaughtUp"),
            (.timeout, "timeout"),
            (.cancelled, "cancelled"),
            (.noPreviewFrame, "noPreviewFrame"),
            (nil, "none")
        ]

        for (reason, expected) in cases {
            XCTAssertEqual(stats.summary(endedAt: 1, hideReason: reason).hideReason, expected)
        }
    }

    func test_nonFiniteCompletionTimeStillCountsResultAndLatency() {
        for invalid in [Double.nan, .infinity, -.infinity] {
            var stats = ScrubOverlayStats(startedAt: 0)
            stats.recordPreviewSeekCompleted(finished: false, latencyMs: 1000, at: invalid)
            stats.recordPreviewSeekCompleted(finished: true, latencyMs: 20, at: invalid)
            let untimed = stats.summary(endedAt: 1, hideReason: nil)
            XCTAssertEqual(untimed.previewCompleted, 2)
            XCTAssertEqual(untimed.previewFinished, 1)
            XCTAssertEqual(untimed.previewLatencyP50Ms, 20)
            XCTAssertEqual(untimed.previewLatencyP90Ms, 20)
            XCTAssertEqual(untimed.firstFrameMs, -1)

            stats.recordPreviewSeekCompleted(finished: true, latencyMs: 30, at: 0.0405)
            XCTAssertEqual(stats.summary(endedAt: 1, hideReason: nil).firstFrameMs, 40)
            stats.recordPreviewSeekCompleted(finished: true, latencyMs: 40, at: invalid)
            let timed = stats.summary(endedAt: 1, hideReason: nil)
            XCTAssertEqual(timed.previewCompleted, 4)
            XCTAssertEqual(timed.previewFinished, 3)
            XCTAssertEqual(timed.firstFrameMs, 40)
        }
    }

    func test_nonFiniteStartLeavesFirstFrameMissingWithoutDiscardingCompletion() {
        for invalid in [Double.nan, .infinity, -.infinity] {
            var stats = ScrubOverlayStats(startedAt: invalid)
            stats.recordPreviewSeekCompleted(finished: true, latencyMs: 20, at: 1)
            stats.recordDragEnded(at: 2)

            let summary = stats.summary(endedAt: 3, hideReason: nil)
            XCTAssertEqual(summary.previewCompleted, 1)
            XCTAssertEqual(summary.previewFinished, 1)
            XCTAssertEqual(summary.previewLatencyP50Ms, 20)
            XCTAssertEqual(summary.firstFrameMs, -1)
            XCTAssertEqual(summary.settleMs, 1000)
        }
    }

    func test_nonFiniteDragEndAndSummaryTimesDoNotProduceSettleDuration() {
        for invalid in [Double.nan, .infinity, -.infinity] {
            var stats = ScrubOverlayStats(startedAt: 0)
            stats.recordDragEnded(at: invalid)
            XCTAssertEqual(stats.summary(endedAt: 3, hideReason: nil).settleMs, -1)
            stats.recordDragEnded(at: 2)
            let before = stats.summary(endedAt: 3, hideReason: .timeout)
            stats.recordDragEnded(at: invalid)
            XCTAssertEqual(stats.summary(endedAt: 3, hideReason: .timeout), before)
            XCTAssertEqual(stats.summary(endedAt: invalid, hideReason: .timeout).settleMs, -1)
        }
    }
}
