import Foundation

public struct CCUsageParser: Sendable {
    public init() {}

    public func parse(_ data: Data) throws -> [AgentID: UsageTotals] {
        let report = try JSONDecoder().decode(Report.self, from: data)
        guard report.daily != nil || report.totals != nil else {
            throw UsageParsingError.unsupportedDocument
        }

        var result: [AgentID: UsageTotals] = [:]
        for row in report.daily ?? [] {
            for breakdown in row.agents ?? [] {
                guard let agent = AgentID(rawValue: breakdown.agent.lowercased()) else { continue }
                let current = result[agent] ?? UsageTotals(totalTokens: 0, totalCost: 0)
                result[agent] = UsageTotals(
                    totalTokens: current.totalTokens + breakdown.totalTokens,
                    totalCost: current.totalCost + breakdown.totalCost
                )
            }

            if let agentName = row.agent,
               let agent = AgentID(rawValue: agentName.lowercased()),
               row.agents == nil {
                let current = result[agent] ?? UsageTotals(totalTokens: 0, totalCost: 0)
                result[agent] = UsageTotals(
                    totalTokens: current.totalTokens + row.totalTokens,
                    totalCost: current.totalCost + row.totalCost
                )
            }
        }

        return result
    }

    /// Groups per-agent daily rows so callers can independently derive a current-day
    /// number and a trailing-week number from one ccusage invocation.
    public func parseDailyRows(_ data: Data) throws -> [AgentID: [DatedUsage]] {
        let report = try JSONDecoder().decode(Report.self, from: data)
        guard report.daily != nil || report.totals != nil else { throw UsageParsingError.unsupportedDocument }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        var result: [AgentID: [DatedUsage]] = [:]
        for row in report.daily ?? [] {
            guard let period = row.period, let date = formatter.date(from: period) else { continue }
            for breakdown in row.agents ?? [] {
                guard let agent = AgentID(rawValue: breakdown.agent.lowercased()) else { continue }
                result[agent, default: []].append(DatedUsage(date: date, usage: UsageTotals(totalTokens: breakdown.totalTokens, totalCost: breakdown.totalCost)))
            }
            if let name = row.agent, let agent = AgentID(rawValue: name.lowercased()), row.agents == nil {
                result[agent, default: []].append(DatedUsage(date: date, usage: UsageTotals(totalTokens: row.totalTokens, totalCost: row.totalCost)))
            }
        }
        return result
    }

    public func aggregate(_ rows: [AgentID: [DatedUsage]]) -> [AgentID: UsageTotals] {
        rows.mapValues { values in
            values.reduce(UsageTotals(totalTokens: 0, totalCost: 0)) {
                UsageTotals(totalTokens: $0.totalTokens + $1.usage.totalTokens, totalCost: $0.totalCost + $1.usage.totalCost)
            }
        }
    }

    public func usages(on day: Date, rows: [AgentID: [DatedUsage]], calendar: Calendar = .current) -> [AgentID: UsageTotals] {
        aggregate(rows.mapValues { $0.filter { calendar.isDate($0.date, inSameDayAs: day) } })
    }

    /// Parses `ccusage blocks --json`; ccusage currently emits billing blocks for
    /// Claude data, so Codex receives no invented reset time.
    public func parseBlocks(_ data: Data) throws -> [SessionBlock] {
        let report = try JSONDecoder().decode(BlocksReport.self, from: data)
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let formatter = ISO8601DateFormatter()
        return report.blocks.compactMap { row in
            guard !row.isGap,
                  let start = fractionalFormatter.date(from: row.startTime) ?? formatter.date(from: row.startTime),
                  let end = fractionalFormatter.date(from: row.endTime) ?? formatter.date(from: row.endTime) else { return nil }
            return SessionBlock(
                startTime: start,
                endTime: end,
                isActive: row.isActive,
                usage: UsageTotals(totalTokens: row.totalTokens, totalCost: row.costUSD)
            )
        }
    }
}

private struct Report: Decodable {
    let daily: [DailyRow]?
    let totals: Totals?
}

private struct DailyRow: Decodable {
    let agent: String?
    let agents: [AgentBreakdown]?
    let period: String?
    let totalTokens: UInt64
    let totalCost: Double

    private enum CodingKeys: String, CodingKey {
        case agent, agents, period, totalTokens, totalCost
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agent = try container.decodeIfPresent(String.self, forKey: .agent)
        agents = try container.decodeIfPresent([AgentBreakdown].self, forKey: .agents)
        period = try container.decodeIfPresent(String.self, forKey: .period)
        totalTokens = try container.decodeIfPresent(UInt64.self, forKey: .totalTokens) ?? 0
        totalCost = try container.decodeIfPresent(Double.self, forKey: .totalCost) ?? 0
    }
}

private struct AgentBreakdown: Decodable {
    let agent: String
    let totalTokens: UInt64
    let totalCost: Double
}

private struct Totals: Decodable {}

private struct BlocksReport: Decodable { let blocks: [BlockRow] }
private struct BlockRow: Decodable {
    let startTime: String
    let endTime: String
    let isActive: Bool
    let isGap: Bool
    let totalTokens: UInt64
    let costUSD: Double

    private enum CodingKeys: String, CodingKey { case startTime, endTime, isActive, isGap, totalTokens, costUSD }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        startTime = try values.decode(String.self, forKey: .startTime)
        endTime = try values.decode(String.self, forKey: .endTime)
        isActive = try values.decode(Bool.self, forKey: .isActive)
        isGap = try values.decode(Bool.self, forKey: .isGap)
        totalTokens = try values.decodeIfPresent(UInt64.self, forKey: .totalTokens) ?? 0
        costUSD = try values.decodeIfPresent(Double.self, forKey: .costUSD) ?? 0
    }
}
