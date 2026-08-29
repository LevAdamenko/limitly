import XCTest
@testable import LimitlyCore

final class ThresholdDetectorTests: XCTestCase {
    func testFiresWhenValueLandsExactlyOnThreshold() {
        var detector = ThresholdDetector()
        _ = detector.observe(percentages: [.claude: 49], thresholds: [.claude: [50]])

        let events = detector.observe(percentages: [.claude: 50], thresholds: [.claude: [50]])

        XCTAssertEqual(events, [ThresholdEvent(agent: .claude, threshold: 50, percentage: 50)])
    }

    func testFiresEveryCrossedThresholdInAscendingOrder() {
        var detector = ThresholdDetector()
        _ = detector.observe(percentages: [.codex: 40], thresholds: [.codex: [100, 50, 80]])

        let events = detector.observe(percentages: [.codex: 105], thresholds: [.codex: [100, 50, 80]])

        XCTAssertEqual(events.map(\.threshold), [50, 80, 100])
    }

    func testInitialObservationDoesNotFire() {
        var detector = ThresholdDetector()
        let events = detector.observe(percentages: [.claude: 90], thresholds: [.claude: [50, 80]])
        XCTAssertTrue(events.isEmpty)
    }

    func testMissingAgentDoesNotResetItsPreviousValue() {
        var detector = ThresholdDetector()
        _ = detector.observe(percentages: [.claude: 40, .codex: 20], thresholds: [.claude: [50]])
        _ = detector.observe(percentages: [.codex: 25], thresholds: [.claude: [50]])

        let events = detector.observe(percentages: [.claude: 50], thresholds: [.claude: [50]])

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.agent, .claude)
    }

    func testZeroBudgetProducesNoPercentageAndNoThresholdEvent() {
        let usage = UsageTotals(totalTokens: 10_000, totalCost: 10)
        let percentage = UsageBudget(unit: .tokens, amount: 0).percentage(for: usage)
        var detector = ThresholdDetector()

        let percentages = percentage.map { [AgentID.claude: $0] } ?? [:]
        XCTAssertTrue(detector.observe(percentages: percentages, thresholds: [.claude: [50]]).isEmpty)
    }
}
