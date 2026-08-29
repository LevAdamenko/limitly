import XCTest
@testable import LimitlyCore

final class SessionBlockTests: XCTestCase {
    func testComputesTimeRemainingUntilActiveBlockReset() {
        let start = Date(timeIntervalSince1970: 1_000)
        let block = SessionBlock(startTime: start, endTime: start.addingTimeInterval(5 * 60 * 60), isActive: true)
        XCTAssertEqual(block.remainingTime(at: start.addingTimeInterval(2 * 60 * 60 + 46 * 60)), 2 * 60 * 60 + 14 * 60)
        XCTAssertEqual(SessionBlockCalculator.resetTime(for: [block]), block.endTime)
    }

    func testInactiveBlockHasNoCountdown() {
        let block = SessionBlock(startTime: .now, endTime: .now.addingTimeInterval(100), isActive: false)
        XCTAssertNil(block.remainingTime(at: .now))
        XCTAssertNil(SessionBlockCalculator.resetTime(for: [block]))
    }
}
