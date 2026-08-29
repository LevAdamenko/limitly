import XCTest
@testable import LimitlyCore

final class ClaudeDesktopUsageTests: XCTestCase {
    func testParsesRealShapedHistoryFile() throws {
        let json = """
        {
          "version": 2,
          "samples": [
            { "t": 1788009999236, "org": "org-a", "u": { "fh": 24, "sd": 38 } },
            { "t": 1788010599236, "org": "org-a", "u": { "fh": 94, "sd": 45 } }
          ]
        }
        """.data(using: .utf8)!

        let samples = try PlanUsageHistoryParser().parse(json)
        XCTAssertEqual(samples.count, 2)
        XCTAssertEqual(samples.last?.fiveHourPercent, 94)
        XCTAssertEqual(samples.last?.sevenDayPercent, 45)
    }

    func testCurrentUsesLatestSampleForFiveHourAndSevenDayPercent() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let samples = [
            PlanUsageSample(timestamp: base, fiveHourPercent: 24, sevenDayPercent: 38),
            PlanUsageSample(timestamp: base.addingTimeInterval(900), fiveHourPercent: 94, sevenDayPercent: 45)
        ]

        let result = PlanUsageAnalyzer.current(from: samples)
        XCTAssertEqual(result?.fiveHourPercent, 94)
        XCTAssertEqual(result?.sevenDayPercent, 45)
    }

    func testResetTimeIsEstimatedFromLastMonotonicDrop() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        // Block A: rises then a new block starts (fh drops) at t+1800, block B rises again.
        let blockAStart = base
        let blockBStart = base.addingTimeInterval(1_800)
        let samples = [
            PlanUsageSample(timestamp: blockAStart, fiveHourPercent: 10, sevenDayPercent: 20),
            PlanUsageSample(timestamp: blockAStart.addingTimeInterval(900), fiveHourPercent: 80, sevenDayPercent: 21),
            PlanUsageSample(timestamp: blockBStart, fiveHourPercent: 5, sevenDayPercent: 22),
            PlanUsageSample(timestamp: blockBStart.addingTimeInterval(900), fiveHourPercent: 40, sevenDayPercent: 23)
        ]

        let result = PlanUsageAnalyzer.current(from: samples)
        XCTAssertEqual(result?.sessionResetTime, blockBStart.addingTimeInterval(5 * 3600))
    }

    func testEmptyHistoryProducesNoSnapshot() {
        XCTAssertNil(PlanUsageAnalyzer.current(from: []))
    }

    func testSingleSampleTreatsItsOwnTimestampAsBlockStart() {
        let sample = PlanUsageSample(timestamp: .init(timeIntervalSince1970: 1_000), fiveHourPercent: 12, sevenDayPercent: 5)
        let result = PlanUsageAnalyzer.current(from: [sample])
        XCTAssertEqual(result?.sessionResetTime, sample.timestamp.addingTimeInterval(5 * 3600))
    }

    func testExtrapolatesForwardFromTheLastTwoSamplesSlope() {
        // Matches the real-world case that surfaced this: 0% -> 9% over 15
        // minutes, checked again 8 minutes later — should read ~13-14%, not
        // a stale 9%.
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let samples = [
            PlanUsageSample(timestamp: base, fiveHourPercent: 0, sevenDayPercent: 45),
            PlanUsageSample(timestamp: base.addingTimeInterval(900), fiveHourPercent: 9, sevenDayPercent: 46)
        ]

        let now = base.addingTimeInterval(900 + 480) // 8 minutes after the latest sample
        let result = PlanUsageAnalyzer.current(from: samples, now: now)
        XCTAssertEqual(result?.fiveHourPercent ?? 0, 13.8, accuracy: 0.1)
    }

    func testDoesNotExtrapolateBeyondTheStalenessWindow() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let samples = [
            PlanUsageSample(timestamp: base, fiveHourPercent: 0, sevenDayPercent: 45),
            PlanUsageSample(timestamp: base.addingTimeInterval(900), fiveHourPercent: 9, sevenDayPercent: 46)
        ]

        let now = base.addingTimeInterval(900 + 3600) // an hour later — app likely not running
        let result = PlanUsageAnalyzer.current(from: samples, now: now)
        XCTAssertEqual(result?.fiveHourPercent, 9)
    }

    func testExtrapolationNeverExceedsOneHundredPercent() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let samples = [
            PlanUsageSample(timestamp: base, fiveHourPercent: 40, sevenDayPercent: 45),
            PlanUsageSample(timestamp: base.addingTimeInterval(900), fiveHourPercent: 95, sevenDayPercent: 46)
        ]

        let now = base.addingTimeInterval(900 + 600)
        let result = PlanUsageAnalyzer.current(from: samples, now: now)
        XCTAssertEqual(result?.fiveHourPercent, 100)
    }
}
