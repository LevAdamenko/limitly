import XCTest
@testable import LimitlyCore

final class ActivityTrackerTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    func testActiveToIdleTransitionFiresOnce() {
        var tracker = ActivityTracker()
        _ = tracker.observe(usages: [.claude: usage(100)], at: start, idleInterval: 30)
        _ = tracker.observe(usages: [.claude: usage(110)], at: start.addingTimeInterval(5), idleInterval: 30)

        XCTAssertTrue(tracker.observe(
            usages: [.claude: usage(110)],
            at: start.addingTimeInterval(34),
            idleInterval: 30
        ).isEmpty)

        let events = tracker.observe(
            usages: [.claude: usage(110)],
            at: start.addingTimeInterval(35),
            idleInterval: 30
        )
        XCTAssertEqual(events, [IdleEvent(agent: .claude, idleSince: start.addingTimeInterval(5))])

        XCTAssertTrue(tracker.observe(
            usages: [.claude: usage(110)],
            at: start.addingTimeInterval(60),
            idleInterval: 30
        ).isEmpty)
    }

    func testInitialUsageIsBaselineNotActivity() {
        var tracker = ActivityTracker()
        _ = tracker.observe(usages: [.codex: usage(100)], at: start, idleInterval: 10)
        XCTAssertTrue(tracker.observe(
            usages: [.codex: usage(100)],
            at: start.addingTimeInterval(20),
            idleInterval: 10
        ).isEmpty)
    }

    func testMissingAgentDoesNotCreateIdleEvent() {
        var tracker = ActivityTracker()
        _ = tracker.observe(usages: [.claude: usage(100)], at: start, idleInterval: 10)
        _ = tracker.observe(usages: [.claude: usage(110)], at: start.addingTimeInterval(1), idleInterval: 10)

        XCTAssertTrue(tracker.observe(usages: [:], at: start.addingTimeInterval(20), idleInterval: 10).isEmpty)
    }

    func testSessionBlockRolloverResetsActivityWithoutIdleEvent() {
        var tracker = ActivityTracker()
        _ = tracker.observe(usages: [.claude: usage(100)], at: start, idleInterval: 10)
        _ = tracker.observe(usages: [.claude: usage(110)], at: start.addingTimeInterval(1), idleInterval: 10)

        XCTAssertTrue(tracker.observe(
            usages: [.claude: usage(5)],
            at: start.addingTimeInterval(20),
            idleInterval: 10
        ).isEmpty)
        XCTAssertTrue(tracker.observe(
            usages: [.claude: usage(5)],
            at: start.addingTimeInterval(40),
            idleInterval: 10
        ).isEmpty)
    }

    private func usage(_ tokens: UInt64) -> UsageTotals {
        UsageTotals(totalTokens: tokens, totalCost: Double(tokens) / 1_000)
    }
}
