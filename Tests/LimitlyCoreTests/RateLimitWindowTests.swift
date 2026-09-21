import XCTest
@testable import LimitlyCore

final class RateLimitWindowTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_790_000_000)

    /// The bug this whole type exists for: the window had rolled over hours
    /// ago, nothing had written a fresh reading, and the menu bar kept
    /// repeating "100%".
    func testPassedResetTimeReportsZeroWithoutWaitingForFreshData() {
        let window = RateLimitWindow(
            usedPercent: 100,
            resetsAt: base.addingTimeInterval(60),
            observedAt: base,
            source: .codexAppServer
        )

        let resolved = window.resolve(at: base.addingTimeInterval(120))
        XCTAssertEqual(resolved?.usedPercent, 0)
        XCTAssertEqual(resolved?.didRollOver, true)
        // The next window is anchored to the next request, not to a clock
        // grid, so its reset time is genuinely unknown until something reports
        // one — better empty than invented.
        XCTAssertNil(resolved?.resetsAt)
        XCTAssertEqual(resolved?.isStale, false)
    }

    func testApproximateResetTimeNeverRollsTheWindowOver() {
        // ccusage floors a block's start to the hour, so its boundary can sit
        // up to an hour before the real one. Zeroing on it would wipe a
        // genuinely-still-80% window.
        let window = RateLimitWindow(
            usedPercent: 80,
            resetsAt: base.addingTimeInterval(60),
            resetIsApproximate: true,
            observedAt: base,
            source: .ccusageBlocks
        )

        let resolved = window.resolve(at: base.addingTimeInterval(120))
        XCTAssertEqual(resolved?.usedPercent, 80)
        XCTAssertEqual(resolved?.didRollOver, false)
        XCTAssertNil(resolved?.resetsAt, "a boundary already in the past is not worth showing")
    }

    func testReadingOlderThanAFullWindowIsDiscardedRatherThanShown() {
        // The Claude desktop app only samples while it is running, and reports
        // no reset time — age is the only roll-over protection it has.
        let window = RateLimitWindow(usedPercent: 100, resetsAt: nil, observedAt: base, source: .claudeDesktop)

        XCTAssertNil(window.resolve(at: base.addingTimeInterval(5 * 3600 + 1)))
        XCTAssertEqual(window.resolve(at: base.addingTimeInterval(5 * 3600 - 1))?.usedPercent, 100)
    }

    func testStalenessIsFlaggedButTheReadingIsStillShown() {
        let window = RateLimitWindow(usedPercent: 42, resetsAt: nil, observedAt: base, source: .claudeStatusLine)

        let fresh = window.resolve(at: base.addingTimeInterval(60))
        XCTAssertEqual(fresh?.isStale, false)
        XCTAssertEqual(fresh?.age, 60)

        let stale = window.resolve(at: base.addingTimeInterval(20 * 60))
        XCTAssertEqual(stale?.isStale, true)
        XCTAssertEqual(stale?.usedPercent, 42)
    }

    func testFutureResetTimeIsPreservedForTheCountdown() {
        let resetsAt = base.addingTimeInterval(4 * 3600)
        let window = RateLimitWindow(usedPercent: 12, resetsAt: resetsAt, observedAt: base, source: .codexAppServer)

        XCTAssertEqual(window.resolve(at: base)?.resetsAt, resetsAt)
    }

    func testAClockSkewedFutureObservationIsNotTreatedAsNegativelyAged() {
        let window = RateLimitWindow(usedPercent: 7, resetsAt: nil, observedAt: base.addingTimeInterval(30), source: .codexAppServer)
        XCTAssertEqual(window.resolve(at: base)?.age, 0)
    }
}
