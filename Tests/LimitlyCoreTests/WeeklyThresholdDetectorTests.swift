import XCTest
@testable import LimitlyCore

final class WeeklyThresholdDetectorTests: XCTestCase {
    func testWeeklyThresholdCrossingIsIndependentOfDailyThresholds() {
        var detector = WeeklyThresholdDetector()
        XCTAssertTrue(detector.observe(percentages: [.claude: 79], thresholds: [.claude: 80]).isEmpty)
        XCTAssertEqual(detector.observe(percentages: [.claude: 80], thresholds: [.claude: 80]), [WeeklyThresholdEvent(agent: .claude, threshold: 80, percentage: 80)])
    }

    func testMissingWeeklyDataDoesNotTrigger() {
        var detector = WeeklyThresholdDetector()
        _ = detector.observe(percentages: [.claude: 70], thresholds: [.claude: 80])
        XCTAssertTrue(detector.observe(percentages: [:], thresholds: [.claude: 80]).isEmpty)
    }
}
