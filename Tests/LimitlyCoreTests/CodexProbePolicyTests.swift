import XCTest
@testable import LimitlyCore

final class CodexProbePolicyTests: XCTestCase {
    private let policy = CodexProbePolicy(foregroundInterval: 30, activeInterval: 60, idleInterval: 300)
    private let start = Date(timeIntervalSince1970: 1_793_448_000)

    func testFirstProbeRunsImmediately() {
        XCTAssertTrue(policy.isDue(now: start, state: .init()))
    }

    func testQuietMachineProbesOnlyAtTheIdlePace() {
        let state = CodexProbePolicy.State(lastAttempt: start)
        XCTAssertFalse(policy.isDue(now: start.addingTimeInterval(299), state: state))
        XCTAssertTrue(policy.isDue(now: start.addingTimeInterval(300), state: state))
    }

    func testCodexActivityProbesAtTheActivePace() {
        let state = CodexProbePolicy.State(lastAttempt: start, logsChangedSinceProbe: true)
        XCTAssertFalse(policy.isDue(now: start.addingTimeInterval(59), state: state))
        XCTAssertTrue(policy.isDue(now: start.addingTimeInterval(60), state: state))
    }

    func testFailureRetriesAtTheActivePace() {
        let state = CodexProbePolicy.State(lastAttempt: start, lastAttemptFailed: true)
        XCTAssertFalse(policy.isDue(now: start.addingTimeInterval(59), state: state))
        XCTAssertTrue(policy.isDue(now: start.addingTimeInterval(60), state: state))
    }

    func testOpenPopoverProbesAtTheForegroundPace() {
        let state = CodexProbePolicy.State(lastAttempt: start, isForeground: true)
        XCTAssertFalse(policy.isDue(now: start.addingTimeInterval(29), state: state))
        XCTAssertTrue(policy.isDue(now: start.addingTimeInterval(30), state: state))
    }

    func testClockGoingBackwardsProbes() {
        XCTAssertTrue(policy.isDue(now: start.addingTimeInterval(-60), state: .init(lastAttempt: start)))
    }
}
