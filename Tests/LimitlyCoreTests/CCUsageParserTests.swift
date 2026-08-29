import XCTest
@testable import LimitlyCore

final class CCUsageParserTests: XCTestCase {
    func testParsesUnifiedPerAgentTotals() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "unified-daily", withExtension: "json"))
        let usages = try CCUsageParser().parse(Data(contentsOf: url))

        XCTAssertEqual(usages[.claude], UsageTotals(totalTokens: 1_000, totalCost: 2.50))
        XCTAssertEqual(usages[.codex], UsageTotals(totalTokens: 2_000, totalCost: 1.25))
    }

    func testMissingAgentRemainsMissing() throws {
        let json = Data(#"{"daily":[{"agent":"all","agents":[{"agent":"claude","totalTokens":100,"totalCost":0.25}]}],"totals":{}}"#.utf8)
        let usages = try CCUsageParser().parse(json)

        XCTAssertNotNil(usages[.claude])
        XCTAssertNil(usages[.codex])
    }

    func testDailyRowsSupportIndependentCurrentDayAndWeeklyAggregation() throws {
        let json = Data(#"{"daily":[{"period":"2026-08-28","agents":[{"agent":"claude","totalTokens":100,"totalCost":1}]},{"period":"2026-08-29","agents":[{"agent":"claude","totalTokens":50,"totalCost":0.5},{"agent":"codex","totalTokens":25,"totalCost":0.25}]}],"totals":{}}"#.utf8)
        let parser = CCUsageParser()
        let rows = try parser.parseDailyRows(json)
        let calendar = Calendar(identifier: .gregorian)
        let day = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-29T00:00:00Z"))
        XCTAssertEqual(parser.aggregate(rows)[.claude]?.totalTokens, 150)
        XCTAssertEqual(parser.usages(on: day, rows: rows, calendar: calendar)[.claude]?.totalTokens, 50)
        XCTAssertEqual(parser.usages(on: day, rows: rows, calendar: calendar)[.codex]?.totalTokens, 25)
    }
}
