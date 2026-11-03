import XCTest
@testable import LimitlyCore

final class CCUsageRefreshPolicyTests: XCTestCase {
    private let policy = CCUsageRefreshPolicy(blocksInterval: 30, dailyInterval: 60, safetyInterval: 900)
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    /// 2026-10-25 12:00:00 UTC — well clear of a day boundary.
    private let noon = Date(timeIntervalSince1970: 1_793_448_000)

    func testFirstRunFetchesBoth() {
        XCTAssertEqual(policy.plan(now: noon, state: .init(), calendar: calendar), .init(blocks: true, daily: true))
    }

    func testNothingRunsWhileLogsAreQuiet() {
        let state = CCUsageRefreshPolicy.State(lastBlocksRun: noon, lastDailyRun: noon)
        XCTAssertTrue(policy.plan(now: noon.addingTimeInterval(899), state: state, calendar: calendar).isEmpty)
    }

    func testSafetyNetRunsBothEventually() {
        let state = CCUsageRefreshPolicy.State(lastBlocksRun: noon, lastDailyRun: noon)
        XCTAssertEqual(policy.plan(now: noon.addingTimeInterval(900), state: state, calendar: calendar), .init(blocks: true, daily: true))
    }

    func testChangedLogsAreRateLimitedPerPass() {
        let state = CCUsageRefreshPolicy.State(lastBlocksRun: noon, lastDailyRun: noon, logsChangedSinceBlocks: true, logsChangedSinceDaily: true)
        XCTAssertTrue(policy.plan(now: noon.addingTimeInterval(29), state: state, calendar: calendar).isEmpty)
        XCTAssertEqual(policy.plan(now: noon.addingTimeInterval(30), state: state, calendar: calendar), .init(blocks: true, daily: false))
        XCTAssertEqual(policy.plan(now: noon.addingTimeInterval(60), state: state, calendar: calendar), .init(blocks: true, daily: true))
    }

    func testExpiredBlockTriggersBlocksOnce() {
        let end = noon.addingTimeInterval(100)
        var state = CCUsageRefreshPolicy.State(lastBlocksRun: noon, lastDailyRun: noon, activeBlockEnd: end)
        XCTAssertTrue(policy.plan(now: end.addingTimeInterval(-1), state: state, calendar: calendar).isEmpty)
        XCTAssertEqual(policy.plan(now: end, state: state, calendar: calendar), .init(blocks: true, daily: false))
        state.lastBlocksRun = end
        XCTAssertTrue(policy.plan(now: end.addingTimeInterval(5), state: state, calendar: calendar).isEmpty)
    }

    func testMidnightTriggersDaily() {
        let beforeMidnight = noon.addingTimeInterval(12 * 3600 - 10)
        let state = CCUsageRefreshPolicy.State(lastBlocksRun: beforeMidnight, lastDailyRun: beforeMidnight)
        XCTAssertEqual(policy.plan(now: beforeMidnight.addingTimeInterval(20), state: state, calendar: calendar), .init(blocks: false, daily: true))
    }

    func testFirstRunHappensEvenWhenNothingNeedsTheResult() {
        let state = CCUsageRefreshPolicy.State(resultNeeded: false)
        XCTAssertEqual(policy.plan(now: noon, state: state, calendar: calendar), .init(blocks: true, daily: true))
    }

    func testNothingRunsWhenNothingNeedsTheResult() {
        let state = CCUsageRefreshPolicy.State(lastBlocksRun: noon, lastDailyRun: noon, logsChangedSinceBlocks: true, logsChangedSinceDaily: true, resultNeeded: false)
        // Past every trigger: changed logs, the safety net and midnight.
        XCTAssertTrue(policy.plan(now: noon.addingTimeInterval(24 * 3600), state: state, calendar: calendar).isEmpty)
    }

    func testChangedLogsRunAsSoonAsTheResultIsNeededAgain() {
        let state = CCUsageRefreshPolicy.State(lastBlocksRun: noon, lastDailyRun: noon, logsChangedSinceBlocks: true, logsChangedSinceDaily: true, resultNeeded: true)
        XCTAssertEqual(policy.plan(now: noon.addingTimeInterval(120), state: state, calendar: calendar), .init(blocks: true, daily: true))
    }

    func testClockGoingBackwardsRefetches() {
        let state = CCUsageRefreshPolicy.State(lastBlocksRun: noon, lastDailyRun: noon)
        XCTAssertEqual(policy.plan(now: noon.addingTimeInterval(-60), state: state, calendar: calendar), .init(blocks: true, daily: true))
    }
}
