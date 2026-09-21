import Foundation

public struct ClaudeStatusLineSnapshot: Equatable, Sendable {
    public let fiveHourPercent: Double?
    public let fiveHourResetsAt: Date?
    public let sevenDayPercent: Double?
    public let sevenDayResetsAt: Date?
    /// When the sidecar wrote this file (its own `writtenAt` epoch-seconds field),
    /// i.e. when Claude Code last rendered its status line. NOT the file mtime.
    public let observedAt: Date

    public init(
        fiveHourPercent: Double?,
        fiveHourResetsAt: Date?,
        sevenDayPercent: Double?,
        sevenDayResetsAt: Date?,
        observedAt: Date
    ) {
        self.fiveHourPercent = fiveHourPercent
        self.fiveHourResetsAt = fiveHourResetsAt
        self.sevenDayPercent = sevenDayPercent
        self.sevenDayResetsAt = sevenDayResetsAt
        self.observedAt = observedAt
    }
}

public enum ClaudeStatusLineUsageParser {
    /// Parses the sidecar file's contents. Returns nil when the payload carries
    /// neither window (so the caller can fall back to another source rather than
    /// showing a fabricated 0%).
    public static func parse(_ data: Data) -> ClaudeStatusLineSnapshot? {
        parse(data, fallbackDate: nil)
    }

    public static func parse(_ data: Data, fallbackDate: Date?) -> ClaudeStatusLineSnapshot? {
        guard let payload = try? JSONDecoder().decode(SidecarPayload.self, from: data) else {
            return nil
        }
        guard let rateLimits = payload.rateLimits else {
            return nil
        }
        let fiveHour = rateLimits.fiveHour
        let sevenDay = rateLimits.sevenDay

        guard fiveHour?.usedPercentage != nil || sevenDay?.usedPercentage != nil else {
            return nil
        }

        let observedAt: Date
        if let writtenAt = payload.writtenAt {
            observedAt = Date(timeIntervalSince1970: writtenAt)
        } else if let fallbackDate = fallbackDate {
            observedAt = fallbackDate
        } else {
            observedAt = Date()
        }

        return ClaudeStatusLineSnapshot(
            fiveHourPercent: fiveHour?.usedPercentage,
            fiveHourResetsAt: fiveHour?.resetsAt.map { Date(timeIntervalSince1970: $0) },
            sevenDayPercent: sevenDay?.usedPercentage,
            sevenDayResetsAt: sevenDay?.resetsAt.map { Date(timeIntervalSince1970: $0) },
            observedAt: observedAt
        )
    }

    private struct SidecarPayload: Decodable {
        let writtenAt: Double?
        let rateLimits: RateLimitsPayload?

        enum CodingKeys: String, CodingKey {
            case writtenAt
            case written_at
            case rateLimits = "rate_limits"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.writtenAt = try container.decodeIfPresent(Double.self, forKey: .writtenAt)
                ?? container.decodeIfPresent(Double.self, forKey: .written_at)
            self.rateLimits = try container.decodeIfPresent(RateLimitsPayload.self, forKey: .rateLimits)
        }
    }

    private struct RateLimitsPayload: Decodable {
        let fiveHour: WindowPayload?
        let sevenDay: WindowPayload?

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
        }
    }

    private struct WindowPayload: Decodable {
        let usedPercentage: Double?
        let resetsAt: Double?

        enum CodingKeys: String, CodingKey {
            case usedPercentage = "used_percentage"
            case resetsAt = "resets_at"
        }
    }
}

public enum ClaudeStatusLineUsageFile {
    /// ~/.limitly/claude-rate-limits.json
    public static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".limitly", isDirectory: true)
            .appendingPathComponent("claude-rate-limits.json")
    }

    public static func currentSnapshot(at url: URL = ClaudeStatusLineUsageFile.url) -> ClaudeStatusLineSnapshot? {
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            ?? (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        return ClaudeStatusLineUsageParser.parse(data, fallbackDate: mtime)
    }
}
