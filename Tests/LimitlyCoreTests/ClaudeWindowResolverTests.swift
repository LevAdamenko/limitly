import XCTest
@testable import LimitlyCore

final class ClaudeWindowResolverTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func statusLine(
        fiveHour: Double?,
        fiveHourResetsAt: Date? = nil,
        sevenDay: Double? = 30,
        age: TimeInterval = 60
    ) -> ClaudeStatusLineSnapshot {
        ClaudeStatusLineSnapshot(
            fiveHourPercent: fiveHour,
            fiveHourResetsAt: fiveHourResetsAt,
            sevenDayPercent: sevenDay,
            sevenDayResetsAt: nil,
            observedAt: now.addingTimeInterval(-age)
        )
    }

    private func desktop(fiveHour: Double = 88, sampleAge: TimeInterval = 60) -> PlanUsageSnapshot {
        PlanUsageSnapshot(
            fiveHourPercent: fiveHour,
            sevenDayPercent: 31,
            sessionResetTime: now.addingTimeInterval(4 * 3600),
            latestSampleTime: now.addingTimeInterval(-sampleAge)
        )
    }

    /// The reported reset time must win over ccusage's reconstruction — this
    /// is the discrepancy that had the popover saying "4h 59m" while the
    /// Claude app said "4h 8m".
    func testStatusLineBeatsTheDesktopCacheAndTheCcusageBlockBoundary() {
        let reported = now.addingTimeInterval(4 * 3600 + 8 * 60)
        let windows = ClaudeWindowResolver.windows(
            statusLine: statusLine(fiveHour: 41, fiveHourResetsAt: reported),
            desktop: desktop(),
            ccusageBlockEnd: now.addingTimeInterval(4 * 3600 + 59 * 60),
            now: now
        )

        XCTAssertEqual(windows?.session?.usedPercent, 41)
        XCTAssertEqual(windows?.session?.resetsAt, reported)
        XCTAssertEqual(windows?.session?.source, .claudeStatusLine)
        XCTAssertEqual(windows?.session?.resetIsApproximate, false)
    }

    /// Claude Code drops a window from its payload the moment that window's
    /// reset passes, so its absence is a fact, not missing data.
    func testAMissingFiveHourWindowMeansTheSessionIsEmptyNotUnknown() {
        let windows = ClaudeWindowResolver.windows(
            statusLine: statusLine(fiveHour: nil),
            desktop: desktop(fiveHour: 100),
            ccusageBlockEnd: nil,
            now: now
        )

        XCTAssertEqual(windows?.session?.usedPercent, 0, "must not fall back to the desktop cache's stale 100%")
        XCTAssertEqual(windows?.session?.source, .claudeStatusLine)
        XCTAssertNil(windows?.session?.resetsAt)
    }

    func testFallsBackToTheDesktopCacheOnceTheStatusLineReadingIsOlderThanAWindow() {
        let windows = ClaudeWindowResolver.windows(
            statusLine: statusLine(fiveHour: 41, age: 5 * 3600 + 60),
            desktop: desktop(fiveHour: 12),
            ccusageBlockEnd: nil,
            now: now
        )

        XCTAssertEqual(windows?.session?.usedPercent, 12)
        XCTAssertEqual(windows?.session?.source, .claudeDesktop)
    }

    func testDesktopFallbackMarksItsResetTimeApproximate() {
        let blockEnd = now.addingTimeInterval(3 * 3600)
        let windows = ClaudeWindowResolver.windows(
            statusLine: nil,
            desktop: desktop(),
            ccusageBlockEnd: blockEnd,
            now: now
        )

        XCTAssertEqual(windows?.session?.resetsAt, blockEnd)
        XCTAssertEqual(windows?.session?.resetIsApproximate, true)
        XCTAssertEqual(windows?.session?.source, .claudeDesktop)
    }

    /// On a machine where the desktop app is rarely open, the backward scan
    /// for "where the percentage dropped" lands on whichever sample happened
    /// to be written last, which is not a session boundary at all.
    func testStaleDesktopSamplesYieldNoEstimatedResetTime() {
        let windows = ClaudeWindowResolver.windows(
            statusLine: nil,
            desktop: desktop(sampleAge: 31 * 60),
            ccusageBlockEnd: nil,
            now: now
        )

        XCTAssertNotNil(windows?.session)
        XCTAssertNil(windows?.session?.resetsAt)
    }

    func testTheWeeklyWindowIsChosenIndependentlyOfTheSessionWindow() {
        // Older than a session window but well inside a weekly one.
        let windows = ClaudeWindowResolver.windows(
            statusLine: statusLine(fiveHour: 41, sevenDay: 64, age: 6 * 3600),
            desktop: desktop(),
            ccusageBlockEnd: nil,
            now: now
        )

        XCTAssertEqual(windows?.session?.source, .claudeDesktop)
        XCTAssertEqual(windows?.weekly?.usedPercent, 64)
        XCTAssertEqual(windows?.weekly?.source, .claudeStatusLine)
    }

    func testNoSourcesAtAllProducesNothingRatherThanAnEmptyWindow() {
        XCTAssertNil(ClaudeWindowResolver.windows(statusLine: nil, desktop: nil, ccusageBlockEnd: now, now: now))
    }
}
