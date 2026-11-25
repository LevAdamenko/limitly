import XCTest
@testable import LimitlyCore

final class UsageFormatTests: XCTestCase {
    func testCompactTokens() {
        XCTAssertEqual(UsageFormat.compactTokens(0), "0 tokens")
        XCTAssertEqual(UsageFormat.compactTokens(950), "950 tokens")
        XCTAssertEqual(UsageFormat.compactTokens(12_300), "12.3K tokens")
        XCTAssertEqual(UsageFormat.compactTokens(1_000_000), "1M tokens")
        XCTAssertEqual(UsageFormat.compactTokens(412_345_678), "412M tokens")
        XCTAssertEqual(UsageFormat.compactTokens(2_450_000_000), "2.5B tokens")
    }

    func testDollars() {
        XCTAssertEqual(UsageFormat.dollars(3.456), "$3.46")
        XCTAssertEqual(UsageFormat.dollars(830.4), "$830")
        XCTAssertEqual(UsageFormat.dollars(.nan), "$0")
    }

    func testClampedPercentNeverLeavesZeroToHundred() {
        XCTAssertEqual(UsageFormat.clampedPercent(4_812_000), 100)
        XCTAssertEqual(UsageFormat.clampedPercent(-3), 0)
        XCTAssertEqual(UsageFormat.clampedPercent(.infinity), 0)
        XCTAssertEqual(UsageFormat.clampedPercent(71.4), 71.4)
    }
}
