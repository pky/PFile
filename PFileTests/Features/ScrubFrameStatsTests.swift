import XCTest
@testable import PFile

final class ScrubFrameStatsTests: XCTestCase {

    func test_seekBecomesEffectiveAfterAdvanceThenPictureIncrease() {
        var stats = ScrubFrameStats(startedAt: 0)
        stats.recordPictureCounts(displayed: 10, lost: 2, at: 0)
        stats.recordSeekIssued(targetSeconds: 100, at: 0)
        stats.recordTime(observedSeconds: 100.5, at: 0.0205)

        let advanced = stats.summary(endedAt: 1)
        XCTAssertEqual(advanced.seekCount, 1)
        XCTAssertEqual(advanced.advancedSeekCount, 1)
        XCTAssertEqual(advanced.effectiveSeekCount, 0)
        XCTAssertEqual(advanced.advanceLatencyP50Ms, 20)
        XCTAssertEqual(advanced.effectiveLatencyP50Ms, -1)

        stats.recordPictureCounts(displayed: 11, lost: 2, at: 0.0405)
        let effective = stats.summary(endedAt: 1)
        XCTAssertEqual(effective.effectiveSeekCount, 1)
        XCTAssertEqual(effective.effectiveLatencyP50Ms, 40)
        XCTAssertEqual(effective.effectiveLatencyP90Ms, 40)

        stats.recordTime(observedSeconds: 100.75, at: 0.0605)
        stats.recordPictureCounts(displayed: 12, lost: 2, at: 0.0805)
        let repeated = stats.summary(endedAt: 1)
        XCTAssertEqual(repeated.advancedSeekCount, 1)
        XCTAssertEqual(repeated.effectiveSeekCount, 1)
        XCTAssertEqual(repeated.advanceLatencyP90Ms, 20)
        XCTAssertEqual(repeated.effectiveLatencyP90Ms, 40)
    }

    func test_timeEchoDoesNotAdvanceSeek() {
        var stats = ScrubFrameStats(startedAt: 0)
        stats.recordSeekIssued(targetSeconds: 0, at: 0)
        stats.recordTime(observedSeconds: 0, at: 0.1)
        stats.recordTime(observedSeconds: 0.005, at: 0.2)
        stats.recordTime(
            observedSeconds: VLCSeekCompletionPolicy.minimumAdvanceSeconds.nextDown,
            at: 0.3
        )

        let summary = stats.summary(endedAt: 1)
        XCTAssertEqual(summary.advancedSeekCount, 0)
        XCTAssertEqual(summary.effectiveSeekCount, 0)
        XCTAssertEqual(summary.advanceLatencyP50Ms, -1)
    }

    func test_timeBehindTargetOrBeyondToleranceDoesNotAdvanceSeek() {
        var stats = ScrubFrameStats(startedAt: 0)
        stats.recordSeekIssued(targetSeconds: 0, at: 0)
        stats.recordTime(observedSeconds: -0.5, at: 0.1)
        stats.recordTime(
            observedSeconds: VLCSeekCompletionPolicy.toleranceSeconds.nextUp,
            at: 0.2
        )

        let summary = stats.summary(endedAt: 1)
        XCTAssertEqual(summary.advancedSeekCount, 0)
        XCTAssertEqual(summary.effectiveSeekCount, 0)
    }

    func test_timeAtBothAdvanceBoundariesAdvancesSeek() {
        for observed in [
            VLCSeekCompletionPolicy.minimumAdvanceSeconds,
            VLCSeekCompletionPolicy.toleranceSeconds
        ] {
            var stats = ScrubFrameStats(startedAt: 0)
            stats.recordSeekIssued(targetSeconds: 0, at: 0)
            stats.recordTime(observedSeconds: observed, at: 0.0205)

            XCTAssertEqual(stats.summary(endedAt: 1).advancedSeekCount, 1)
        }
    }

    func test_timeAndPicturesWithoutCurrentSeekDoNotCountSeek() {
        var stats = ScrubFrameStats(startedAt: 0)
        stats.recordTime(observedSeconds: 0.5, at: 0.1)
        stats.recordPictureCounts(displayed: 10, lost: 0, at: 0.2)
        stats.recordPictureCounts(displayed: 11, lost: 0, at: 0.3)

        let summary = stats.summary(endedAt: 1)
        XCTAssertEqual(summary.seekCount, 0)
        XCTAssertEqual(summary.advancedSeekCount, 0)
        XCTAssertEqual(summary.effectiveSeekCount, 0)
    }

    func test_newSeekClosesPreviousSeekBeforeAdvance() {
        var stats = ScrubFrameStats(startedAt: 0)
        stats.recordPictureCounts(displayed: 10, lost: 0, at: 0)
        stats.recordSeekIssued(targetSeconds: 10, at: 0)
        stats.recordSeekIssued(targetSeconds: 20, at: 0.1)
        stats.recordTime(observedSeconds: 10.5, at: 0.2)
        stats.recordPictureCounts(displayed: 11, lost: 0, at: 0.3)

        let closed = stats.summary(endedAt: 1)
        XCTAssertEqual(closed.seekCount, 2)
        XCTAssertEqual(closed.advancedSeekCount, 0)
        XCTAssertEqual(closed.effectiveSeekCount, 0)

        stats.recordTime(observedSeconds: 20.5, at: 0.4)
        stats.recordPictureCounts(displayed: 12, lost: 0, at: 0.5)
        let current = stats.summary(endedAt: 1)
        XCTAssertEqual(current.advancedSeekCount, 1)
        XCTAssertEqual(current.effectiveSeekCount, 1)
    }

    func test_newSeekClosesAdvancedSeekWithoutPictureIncrease() {
        var stats = ScrubFrameStats(startedAt: 0)
        stats.recordPictureCounts(displayed: 10, lost: 0, at: 0)
        stats.recordSeekIssued(targetSeconds: 10, at: 0)
        stats.recordTime(observedSeconds: 10.5, at: 0.0205)
        stats.recordPictureCounts(displayed: 10, lost: 0, at: 0.03)
        stats.recordSeekIssued(targetSeconds: 20, at: 0.04)
        stats.recordPictureCounts(displayed: 11, lost: 0, at: 0.05)

        let summary = stats.summary(endedAt: 1)
        XCTAssertEqual(summary.seekCount, 2)
        XCTAssertEqual(summary.advancedSeekCount, 1)
        XCTAssertEqual(summary.effectiveSeekCount, 0)
        XCTAssertEqual(summary.advanceLatencyP50Ms, 20)
        XCTAssertEqual(summary.effectiveLatencyP50Ms, -1)
    }

    func test_pictureIncreaseBeforeAdvanceDoesNotMakeSeekEffective() {
        var stats = ScrubFrameStats(startedAt: 0)
        stats.recordPictureCounts(displayed: 10, lost: 0, at: 0)
        stats.recordSeekIssued(targetSeconds: 10, at: 0)
        stats.recordPictureCounts(displayed: 12, lost: 0, at: 0.01)
        XCTAssertEqual(stats.summary(endedAt: 1).effectiveSeekCount, 0)

        stats.recordTime(observedSeconds: 10.5, at: 0.02)
        stats.recordPictureCounts(displayed: 12, lost: 0, at: 0.03)
        XCTAssertEqual(stats.summary(endedAt: 1).effectiveSeekCount, 0)

        stats.recordPictureCounts(displayed: 13, lost: 0, at: 0.04)
        XCTAssertEqual(stats.summary(endedAt: 1).effectiveSeekCount, 1)
    }

    func test_firstPictureSampleAfterAdvanceEstablishesBaseline() {
        var stats = ScrubFrameStats(startedAt: 0)
        stats.recordSeekIssued(targetSeconds: 10, at: 0)
        stats.recordTime(observedSeconds: 10.5, at: 0.01)
        stats.recordPictureCounts(displayed: 50, lost: 3, at: 0.02)
        stats.recordPictureCounts(displayed: 50, lost: 3, at: 0.03)
        XCTAssertEqual(stats.summary(endedAt: 1).effectiveSeekCount, 0)

        stats.recordPictureCounts(displayed: 51, lost: 3, at: 0.0405)
        let summary = stats.summary(endedAt: 1)
        XCTAssertEqual(summary.effectiveSeekCount, 1)
        XCTAssertEqual(summary.effectiveLatencyP50Ms, 40)
        XCTAssertEqual(summary.displayedPictures, 1)
        XCTAssertEqual(summary.lostPictures, 0)
    }

    func test_pictureTotalsSumOnlyPositiveDeltasAndRebaseAfterReset() {
        var stats = ScrubFrameStats(startedAt: 0)
        stats.recordPictureCounts(displayed: 100, lost: 20, at: 0)
        stats.recordPictureCounts(displayed: 105, lost: 22, at: 0.1)
        stats.recordPictureCounts(displayed: 105, lost: 22, at: 0.2)
        stats.recordPictureCounts(displayed: 2, lost: 23, at: 0.3)
        stats.recordPictureCounts(displayed: 5, lost: 1, at: 0.4)
        stats.recordPictureCounts(displayed: 6, lost: 4, at: 0.5)

        let summary = stats.summary(endedAt: 1)
        XCTAssertEqual(summary.displayedPictures, 9)
        XCTAssertEqual(summary.lostPictures, 6)
    }

    func test_percentilesUseNearestRank() {
        var stats = ScrubFrameStats(startedAt: 0)
        stats.recordPictureCounts(displayed: 0, lost: 0, at: 0)
        // 到着順を崩し、並べ替えと nearest-rank の両方を確かめる。
        for (index, latencyMs) in [30, 10, 40, 20].enumerated() {
            let issuedAt = Double(index)
            let observedAt = issuedAt + (Double(latencyMs) + 0.5) / 1000
            stats.recordSeekIssued(targetSeconds: 0, at: issuedAt)
            stats.recordTime(observedSeconds: 0.5, at: observedAt)
            stats.recordPictureCounts(displayed: index + 1, lost: 0, at: observedAt)
        }

        let summary = stats.summary(endedAt: 4)
        XCTAssertEqual(summary.advanceLatencyP50Ms, 20)
        XCTAssertEqual(summary.advanceLatencyP90Ms, 40)
        XCTAssertEqual(summary.effectiveLatencyP50Ms, 20)
        XCTAssertEqual(summary.effectiveLatencyP90Ms, 40)
    }

    func test_emptySummaryHasZeroCountsAndMissingPercentiles() {
        let summary = ScrubFrameStats(startedAt: 0).summary(endedAt: 1)

        XCTAssertEqual(summary.seekCount, 0)
        XCTAssertEqual(summary.advancedSeekCount, 0)
        XCTAssertEqual(summary.effectiveSeekCount, 0)
        XCTAssertEqual(summary.displayedPictures, 0)
        XCTAssertEqual(summary.lostPictures, 0)
        XCTAssertEqual(summary.effectiveSeeksPerSecond, 0)
        XCTAssertEqual(summary.advanceLatencyP50Ms, -1)
        XCTAssertEqual(summary.advanceLatencyP90Ms, -1)
        XCTAssertEqual(summary.effectiveLatencyP50Ms, -1)
        XCTAssertEqual(summary.effectiveLatencyP90Ms, -1)
    }

    func test_durationAndEffectiveSeeksPerSecond() {
        var stats = ScrubFrameStats(startedAt: 0)
        stats.recordPictureCounts(displayed: 0, lost: 0, at: 0)
        for index in 0..<2 {
            let issuedAt = Double(index)
            stats.recordSeekIssued(targetSeconds: 0, at: issuedAt)
            stats.recordTime(observedSeconds: 0.5, at: issuedAt + 0.1)
            stats.recordPictureCounts(displayed: index + 1, lost: 0, at: issuedAt + 0.2)
        }

        let summary = stats.summary(endedAt: 4.0005)
        XCTAssertEqual(summary.durationMs, 4000)
        XCTAssertEqual(summary.effectiveSeekCount, 2)
        XCTAssertEqual(summary.effectiveSeeksPerSecond, 0.5, accuracy: 0.000001)

        for endedAt in [0.0, 0.0005, -1.0] {
            let zeroDuration = stats.summary(endedAt: endedAt)
            XCTAssertEqual(zeroDuration.durationMs, 0)
            XCTAssertEqual(zeroDuration.effectiveSeeksPerSecond, 0)
            XCTAssertEqual(zeroDuration.effectiveSeekCount, 2)
        }
    }

    func test_negativeLatenciesAreClampedToZero() {
        var stats = ScrubFrameStats(startedAt: 0)
        stats.recordPictureCounts(displayed: 0, lost: 0, at: 0)
        stats.recordSeekIssued(targetSeconds: 0, at: 2)
        stats.recordTime(observedSeconds: 0.5, at: 1)
        stats.recordPictureCounts(displayed: 1, lost: 0, at: 1.5)

        let summary = stats.summary(endedAt: 3)
        XCTAssertEqual(summary.advancedSeekCount, 1)
        XCTAssertEqual(summary.effectiveSeekCount, 1)
        XCTAssertEqual(summary.advanceLatencyP50Ms, 0)
        XCTAssertEqual(summary.advanceLatencyP90Ms, 0)
        XCTAssertEqual(summary.effectiveLatencyP50Ms, 0)
        XCTAssertEqual(summary.effectiveLatencyP90Ms, 0)
    }

    func test_nonFiniteSeekArgumentsDoNotChangeStateOrReplaceCurrentSeek() {
        for invalid in [Double.nan, .infinity, -.infinity] {
            var stats = ScrubFrameStats(startedAt: 0)
            stats.recordPictureCounts(displayed: 0, lost: 0, at: 0)
            stats.recordSeekIssued(targetSeconds: 10, at: 0)
            let before = stats.summary(endedAt: 1)

            stats.recordSeekIssued(targetSeconds: invalid, at: 0.1)
            XCTAssertEqual(stats.summary(endedAt: 1), before)
            stats.recordSeekIssued(targetSeconds: 20, at: invalid)
            XCTAssertEqual(stats.summary(endedAt: 1), before)

            stats.recordTime(observedSeconds: 10.5, at: 0.0205)
            stats.recordPictureCounts(displayed: 1, lost: 0, at: 0.0405)
            let summary = stats.summary(endedAt: 1)
            XCTAssertEqual(summary.advancedSeekCount, 1)
            XCTAssertEqual(summary.effectiveSeekCount, 1)
            XCTAssertEqual(summary.advanceLatencyP50Ms, 20)
            XCTAssertEqual(summary.effectiveLatencyP50Ms, 40)
        }
    }

    func test_nonFiniteTimeArgumentsDoNotChangeState() {
        for invalid in [Double.nan, .infinity, -.infinity] {
            var stats = ScrubFrameStats(startedAt: 0)
            stats.recordSeekIssued(targetSeconds: 0, at: 0)
            let before = stats.summary(endedAt: 1)

            stats.recordTime(observedSeconds: invalid, at: 0.1)
            XCTAssertEqual(stats.summary(endedAt: 1), before)
            stats.recordTime(observedSeconds: 0.5, at: invalid)
            XCTAssertEqual(stats.summary(endedAt: 1), before)

            stats.recordTime(observedSeconds: 0.5, at: 0.0205)
            let summary = stats.summary(endedAt: 1)
            XCTAssertEqual(summary.advancedSeekCount, 1)
            XCTAssertEqual(summary.advanceLatencyP50Ms, 20)
        }
    }

    func test_nonFinitePictureTimeDoesNotChangeStateOrBaseline() {
        for invalid in [Double.nan, .infinity, -.infinity] {
            var stats = ScrubFrameStats(startedAt: 0)
            stats.recordPictureCounts(displayed: 10, lost: 2, at: 0)
            stats.recordSeekIssued(targetSeconds: 0, at: 0)
            stats.recordTime(observedSeconds: 0.5, at: 0.0205)
            let before = stats.summary(endedAt: 1)

            stats.recordPictureCounts(displayed: 100, lost: 100, at: invalid)
            XCTAssertEqual(stats.summary(endedAt: 1), before)

            stats.recordPictureCounts(displayed: 11, lost: 3, at: 0.0405)
            let summary = stats.summary(endedAt: 1)
            XCTAssertEqual(summary.effectiveSeekCount, 1)
            XCTAssertEqual(summary.effectiveLatencyP50Ms, 40)
            XCTAssertEqual(summary.displayedPictures, 1)
            XCTAssertEqual(summary.lostPictures, 1)
        }
    }
}
