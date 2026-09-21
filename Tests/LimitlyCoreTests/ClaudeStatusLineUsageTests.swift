import XCTest
@testable import LimitlyCore

final class ClaudeStatusLineUsageTests: XCTestCase {
    func testBothWindowsPresent() {
        let json = """
        {
            "writtenAt": 1790013265,
            "rate_limits": {
                "five_hour": { "used_percentage": 12.5, "resets_at": 1790013265 },
                "seven_day": { "used_percentage": 36.0, "resets_at": 1790422228 },
                "spend_limit": { "used_percentage": 4.0, "resets_at": 1790422228 }
            }
        }
        """
        let data = json.data(using: .utf8)!
        let snapshot = ClaudeStatusLineUsageParser.parse(data)
        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot?.fiveHourPercent, 12.5)
        XCTAssertEqual(snapshot?.fiveHourResetsAt, Date(timeIntervalSince1970: 1790013265))
        XCTAssertEqual(snapshot?.sevenDayPercent, 36.0)
        XCTAssertEqual(snapshot?.sevenDayResetsAt, Date(timeIntervalSince1970: 1790422228))
        XCTAssertEqual(snapshot?.observedAt, Date(timeIntervalSince1970: 1790013265))
    }

    func testOnlyFiveHourPresent() {
        let json = """
        {
            "writtenAt": 1790013265,
            "rate_limits": {
                "five_hour": { "used_percentage": 42.0, "resets_at": 1790013265 }
            }
        }
        """
        let data = json.data(using: .utf8)!
        let snapshot = ClaudeStatusLineUsageParser.parse(data)
        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot?.fiveHourPercent, 42.0)
        XCTAssertEqual(snapshot?.fiveHourResetsAt, Date(timeIntervalSince1970: 1790013265))
        XCTAssertNil(snapshot?.sevenDayPercent)
        XCTAssertNil(snapshot?.sevenDayResetsAt)
        XCTAssertEqual(snapshot?.observedAt, Date(timeIntervalSince1970: 1790013265))
    }

    func testOnlySevenDayPresent() {
        let json = """
        {
            "writtenAt": 1790013265,
            "rate_limits": {
                "seven_day": { "used_percentage": 85.5, "resets_at": 1790422228 }
            }
        }
        """
        let data = json.data(using: .utf8)!
        let snapshot = ClaudeStatusLineUsageParser.parse(data)
        XCTAssertNotNil(snapshot)
        XCTAssertNil(snapshot?.fiveHourPercent)
        XCTAssertNil(snapshot?.fiveHourResetsAt)
        XCTAssertEqual(snapshot?.sevenDayPercent, 85.5)
        XCTAssertEqual(snapshot?.sevenDayResetsAt, Date(timeIntervalSince1970: 1790422228))
        XCTAssertEqual(snapshot?.observedAt, Date(timeIntervalSince1970: 1790013265))
    }

    func testRateLimitsAbsentReturnsNil() {
        // Missing rate_limits entirely
        let noLimitsJSON = """
        { "writtenAt": 1790013265 }
        """
        XCTAssertNil(ClaudeStatusLineUsageParser.parse(noLimitsJSON.data(using: .utf8)!))

        // Null rate_limits
        let nullLimitsJSON = """
        { "writtenAt": 1790013265, "rate_limits": null }
        """
        XCTAssertNil(ClaudeStatusLineUsageParser.parse(nullLimitsJSON.data(using: .utf8)!))

        // Empty rate_limits
        let emptyLimitsJSON = """
        { "writtenAt": 1790013265, "rate_limits": {} }
        """
        XCTAssertNil(ClaudeStatusLineUsageParser.parse(emptyLimitsJSON.data(using: .utf8)!))

        // rate_limits with only spend_limit (enterprise gateway, should be ignored)
        let onlySpendLimitJSON = """
        {
            "writtenAt": 1790013265,
            "rate_limits": {
                "spend_limit": { "used_percentage": 4.0, "resets_at": 1790422228 }
            }
        }
        """
        XCTAssertNil(ClaudeStatusLineUsageParser.parse(onlySpendLimitJSON.data(using: .utf8)!))
    }

    func testMalformedOrTruncatedJSONReturnsNil() {
        // Truncated JSON
        let truncated = "{\"writtenAt\": 1790013265, \"rate_limits\": { \"five_h"
        XCTAssertNil(ClaudeStatusLineUsageParser.parse(truncated.data(using: .utf8)!))

        // Empty data
        XCTAssertNil(ClaudeStatusLineUsageParser.parse(Data()))

        // Garbage text
        let garbage = "not a json string at all".data(using: .utf8)!
        XCTAssertNil(ClaudeStatusLineUsageParser.parse(garbage))

        // Top-level not an object
        let arrayJSON = "[1, 2, 3]".data(using: .utf8)!
        XCTAssertNil(ClaudeStatusLineUsageParser.parse(arrayJSON))

        // Unexpected rate_limits type
        let wrongType = "{\"rate_limits\": \"not-a-dictionary\"}".data(using: .utf8)!
        XCTAssertNil(ClaudeStatusLineUsageParser.parse(wrongType))
    }

    func testWrittenAtMissingFallsBackToMtime() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("claude-rate-limits.json")
        let jsonWithoutWrittenAt = """
        {
            "rate_limits": {
                "five_hour": { "used_percentage": 25.0, "resets_at": 1790013265 }
            }
        }
        """
        try jsonWithoutWrittenAt.data(using: .utf8)!.write(to: fileURL)

        let knownMtime = Date(timeIntervalSince1970: 1780000000)
        try FileManager.default.setAttributes([.modificationDate: knownMtime], ofItemAtPath: fileURL.path)

        let snapshot = ClaudeStatusLineUsageFile.currentSnapshot(at: fileURL)
        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot?.fiveHourPercent, 25.0)
        if let observedAt = snapshot?.observedAt {
            XCTAssertEqual(floor(observedAt.timeIntervalSince1970), floor(knownMtime.timeIntervalSince1970))
        } else {
            XCTFail("ObservedAt should not be nil")
        }
    }

    func testWrittenAtMissingParserFallback() {
        let json = """
        {
            "rate_limits": {
                "five_hour": { "used_percentage": 10.0, "resets_at": 1790013265 }
            }
        }
        """
        let data = json.data(using: .utf8)!

        let fallbackDate = Date(timeIntervalSince1970: 1785000000)
        let snapshotWithFallback = ClaudeStatusLineUsageParser.parse(data, fallbackDate: fallbackDate)
        XCTAssertEqual(snapshotWithFallback?.observedAt, fallbackDate)

        let before = Date()
        let snapshotDefault = ClaudeStatusLineUsageParser.parse(data)
        let after = Date()
        XCTAssertNotNil(snapshotDefault)
        if let observedAt = snapshotDefault?.observedAt {
            XCTAssertGreaterThanOrEqual(observedAt, before.addingTimeInterval(-1))
            XCTAssertLessThanOrEqual(observedAt, after.addingTimeInterval(1))
        }
    }

    func testEpochSecondsToDateConversion() {
        let writtenEpoch: Double = 1790013265
        let fiveHourResetEpoch: Double = 1790020000
        let sevenDayResetEpoch: Double = 1790422228

        let json = """
        {
            "writtenAt": \(Int(writtenEpoch)),
            "rate_limits": {
                "five_hour": { "used_percentage": 15.0, "resets_at": \(Int(fiveHourResetEpoch)) },
                "seven_day": { "used_percentage": 50.0, "resets_at": \(Int(sevenDayResetEpoch)) }
            }
        }
        """
        let snapshot = ClaudeStatusLineUsageParser.parse(json.data(using: .utf8)!)
        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot?.observedAt, Date(timeIntervalSince1970: writtenEpoch))
        XCTAssertEqual(snapshot?.fiveHourResetsAt, Date(timeIntervalSince1970: fiveHourResetEpoch))
        XCTAssertEqual(snapshot?.sevenDayResetsAt, Date(timeIntervalSince1970: sevenDayResetEpoch))
    }

    func testObservedAtUsesWrittenAtOverMtime() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("claude-rate-limits.json")
        let json = """
        {
            "writtenAt": 1790013265,
            "rate_limits": {
                "five_hour": { "used_percentage": 25.0, "resets_at": 1790013265 }
            }
        }
        """
        try json.data(using: .utf8)!.write(to: fileURL)

        let oldMtime = Date(timeIntervalSince1970: 1770000000)
        try FileManager.default.setAttributes([.modificationDate: oldMtime], ofItemAtPath: fileURL.path)

        let snapshot = ClaudeStatusLineUsageFile.currentSnapshot(at: fileURL)
        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot?.observedAt, Date(timeIntervalSince1970: 1790013265))
    }

    func testUsageFileURLAndMissingFileHandling() {
        let expectedSuffix = ".limitly/claude-rate-limits.json"
        XCTAssertTrue(ClaudeStatusLineUsageFile.url.path.hasSuffix(expectedSuffix))

        let nonExistentURL = URL(fileURLWithPath: "/path/to/nonexistent/claude-rate-limits.json")
        XCTAssertNil(ClaudeStatusLineUsageFile.currentSnapshot(at: nonExistentURL))
    }
}
