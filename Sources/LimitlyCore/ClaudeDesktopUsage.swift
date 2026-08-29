import Foundation

/// One periodic sample from the Claude desktop app's own local usage cache
/// (`~/Library/Application Support/Claude/plan-usage-history.json`), written
/// by the already-authenticated app roughly every 15 minutes. `fh`/`sd` are
/// Anthropic's own real "five hour" (current session) and "seven day"
/// (weekly) percent-used figures — the same numbers shown on
/// claude.ai/settings/usage — not a locally-derived approximation.
public struct PlanUsageSample: Equatable, Sendable {
    public let timestamp: Date
    public let fiveHourPercent: Double
    public let sevenDayPercent: Double

    public init(timestamp: Date, fiveHourPercent: Double, sevenDayPercent: Double) {
        self.timestamp = timestamp
        self.fiveHourPercent = fiveHourPercent
        self.sevenDayPercent = sevenDayPercent
    }
}

public struct PlanUsageHistoryParser: Sendable {
    public init() {}

    public func parse(_ data: Data) throws -> [PlanUsageSample] {
        let report = try JSONDecoder().decode(Report.self, from: data)
        return report.samples.map { row in
            PlanUsageSample(
                timestamp: Date(timeIntervalSince1970: Double(row.t) / 1000),
                fiveHourPercent: row.u.fh,
                sevenDayPercent: row.u.sd
            )
        }
    }

    private struct Report: Decodable { let samples: [Sample] }
    private struct Sample: Decodable { let t: Int64; let u: Usage }
    private struct Usage: Decodable { let fh: Double; let sd: Double }
}

public struct PlanUsageSnapshot: Equatable, Sendable {
    public let fiveHourPercent: Double
    public let sevenDayPercent: Double
    public let sessionResetTime: Date

    public init(fiveHourPercent: Double, sevenDayPercent: Double, sessionResetTime: Date) {
        self.fiveHourPercent = fiveHourPercent
        self.sevenDayPercent = sevenDayPercent
        self.sessionResetTime = sessionResetTime
    }
}

public enum PlanUsageAnalyzer {
    /// The history has no explicit block-boundary field, so the current
    /// session's start is estimated by scanning backward from the latest
    /// sample while `fiveHourPercent` keeps non-decreasing; a drop marks
    /// where the previous 5-hour block ended and the current one began.
    ///
    /// The desktop app only samples every ~15 minutes, so `fiveHourPercent`
    /// can lag the true value by up to that long. `now` linearly
    /// extrapolates forward from the last two in-block samples' slope,
    /// bounded to `maxExtrapolation` so a stale/absent app doesn't produce
    /// an ever-growing guess.
    public static func current(
        from samples: [PlanUsageSample],
        now: Date = Date(),
        sessionLength: TimeInterval = 5 * 3600,
        maxExtrapolation: TimeInterval = 20 * 60
    ) -> PlanUsageSnapshot? {
        let sorted = samples.sorted { $0.timestamp < $1.timestamp }
        guard let latest = sorted.last else { return nil }

        var index = sorted.count - 1
        while index > 0, sorted[index].fiveHourPercent + 1 >= sorted[index - 1].fiveHourPercent {
            index -= 1
        }
        let blockStart = sorted[index].timestamp
        let blockSamples = Array(sorted[index...])

        return PlanUsageSnapshot(
            fiveHourPercent: extrapolatedFiveHourPercent(blockSamples: blockSamples, now: now, maxExtrapolation: maxExtrapolation),
            sevenDayPercent: latest.sevenDayPercent,
            sessionResetTime: blockStart.addingTimeInterval(sessionLength)
        )
    }

    private static func extrapolatedFiveHourPercent(
        blockSamples: [PlanUsageSample], now: Date, maxExtrapolation: TimeInterval
    ) -> Double {
        guard let latest = blockSamples.last else { return 0 }
        let elapsedSinceLatest = now.timeIntervalSince(latest.timestamp)
        guard elapsedSinceLatest > 0, elapsedSinceLatest <= maxExtrapolation, blockSamples.count >= 2 else {
            return latest.fiveHourPercent
        }

        let previous = blockSamples[blockSamples.count - 2]
        let sampleInterval = latest.timestamp.timeIntervalSince(previous.timestamp)
        guard sampleInterval > 0 else { return latest.fiveHourPercent }

        let ratePerSecond = (latest.fiveHourPercent - previous.fiveHourPercent) / sampleInterval
        let projected = latest.fiveHourPercent + ratePerSecond * elapsedSinceLatest
        return max(latest.fiveHourPercent, min(100, projected))
    }
}
