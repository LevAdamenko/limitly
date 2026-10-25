import XCTest
@testable import LimitlyCore

final class LogActivityTrackerTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    func testFirstWriteIsBaselineNotActivity() {
        var tracker = LogActivityTracker()
        _ = tracker.observe(lastWrites: [.claude: start], at: start, idleInterval: 10)
        XCTAssertTrue(tracker.observe(lastWrites: [.claude: start], at: start.addingTimeInterval(60), idleInterval: 10).isEmpty)
    }

    func testIdleFiresOnceAfterLastWrite() {
        var tracker = LogActivityTracker()
        _ = tracker.observe(lastWrites: [.codex: start], at: start, idleInterval: 30)
        let write = start.addingTimeInterval(5)
        XCTAssertTrue(tracker.observe(lastWrites: [.codex: write], at: write, idleInterval: 30).isEmpty)
        XCTAssertTrue(tracker.observe(lastWrites: [.codex: write], at: write.addingTimeInterval(29), idleInterval: 30).isEmpty)
        XCTAssertEqual(
            tracker.observe(lastWrites: [.codex: write], at: write.addingTimeInterval(30), idleInterval: 30),
            [IdleEvent(agent: .codex, idleSince: write)]
        )
        XCTAssertTrue(tracker.observe(lastWrites: [.codex: write], at: write.addingTimeInterval(90), idleInterval: 30).isEmpty)
    }

    func testFurtherWritesKeepItActive() {
        var tracker = LogActivityTracker()
        _ = tracker.observe(lastWrites: [.claude: start], at: start, idleInterval: 30)
        for offset in stride(from: 10.0, through: 120, by: 10) {
            let write = start.addingTimeInterval(offset)
            XCTAssertTrue(tracker.observe(lastWrites: [.claude: write], at: write.addingTimeInterval(5), idleInterval: 30).isEmpty)
        }
    }
}
