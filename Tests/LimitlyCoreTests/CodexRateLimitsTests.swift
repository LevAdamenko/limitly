import XCTest
@testable import LimitlyCore

final class CodexRateLimitsTests: XCTestCase {
    func testParsesRealShapedAppServerOutput() {
        let output = """
        {"id":0,"result":{"userAgent":"limitly/1.0.0"}}
        {"method":"remoteControl/status/changed","params":{"status":"disabled"}}
        {"id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":0,"windowDurationMins":300,"resetsAt":1788049960},"secondary":{"usedPercent":55,"windowDurationMins":10080,"resetsAt":1788453028},"planType":"plus"}}}
        """

        let snapshot = CodexRateLimitParser.parse(output)
        XCTAssertEqual(snapshot?.fiveHourPercent, 0)
        XCTAssertEqual(snapshot?.weeklyPercent, 55)
        XCTAssertEqual(snapshot?.sessionResetTime, Date(timeIntervalSince1970: 1788049960))
        XCTAssertEqual(snapshot?.weeklyResetTime, Date(timeIntervalSince1970: 1788453028))
    }

    func testIgnoresUnrelatedLinesAndOutOfOrderNotifications() {
        let output = """
        garbage, not json at all
        {"id":0,"result":{"userAgent":"limitly/1.0.0"}}
        {"method":"some/notification","params":{}}
        {"id":2,"result":{"rateLimits":{"primary":{"usedPercent":42,"resetsAt":100},"secondary":{"usedPercent":10,"resetsAt":200}}}}
        {"method":"trailing/notification","params":{}}
        """

        let snapshot = CodexRateLimitParser.parse(output)
        XCTAssertEqual(snapshot?.fiveHourPercent, 42)
        XCTAssertEqual(snapshot?.weeklyPercent, 10)
    }

    func testReturnsNilWhenNoRateLimitResponsePresent() {
        let output = """
        {"id":0,"result":{"userAgent":"limitly/1.0.0"}}
        {"method":"remoteControl/status/changed","params":{"status":"disabled"}}
        """

        XCTAssertNil(CodexRateLimitParser.parse(output))
    }

    func testMissingResetTimestampsProduceNilDatesNotCrash() {
        let output = """
        {"id":2,"result":{"rateLimits":{"primary":{"usedPercent":5},"secondary":{"usedPercent":3}}}}
        """

        let snapshot = CodexRateLimitParser.parse(output)
        XCTAssertEqual(snapshot?.fiveHourPercent, 5)
        XCTAssertEqual(snapshot?.weeklyPercent, 3)
        XCTAssertNil(snapshot?.sessionResetTime)
        XCTAssertNil(snapshot?.weeklyResetTime)
    }
}
