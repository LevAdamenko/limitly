import Foundation

public enum AgentID: String, Codable, CaseIterable, Sendable {
    case claude
    case codex

    public var displayName: String {
        rawValue.capitalized
    }
}

public struct UsageTotals: Equatable, Sendable {
    public var totalTokens: UInt64
    public var totalCost: Double

    public init(totalTokens: UInt64, totalCost: Double) {
        self.totalTokens = totalTokens
        self.totalCost = totalCost
    }
}

public struct DatedUsage: Equatable, Sendable {
    public let date: Date
    public let usage: UsageTotals

    public init(date: Date, usage: UsageTotals) {
        self.date = date
        self.usage = usage
    }
}

public struct UsageSnapshot: Equatable, Sendable {
    public let currentUsage: [AgentID: UsageTotals]
    public let weeklyUsage: [AgentID: UsageTotals]
    public let resetTimes: [AgentID: Date]
    /// Real, provider-computed percentages (e.g. Anthropic's own "five hour"
    /// figure from the Claude desktop app's local cache) where available —
    /// preferred over the budget-derived estimate for agents that have one.
    public let realCurrentPercentages: [AgentID: Double]
    public let realWeeklyPercentages: [AgentID: Double]

    public init(
        currentUsage: [AgentID: UsageTotals],
        weeklyUsage: [AgentID: UsageTotals],
        resetTimes: [AgentID: Date] = [:],
        realCurrentPercentages: [AgentID: Double] = [:],
        realWeeklyPercentages: [AgentID: Double] = [:]
    ) {
        self.currentUsage = currentUsage
        self.weeklyUsage = weeklyUsage
        self.resetTimes = resetTimes
        self.realCurrentPercentages = realCurrentPercentages
        self.realWeeklyPercentages = realWeeklyPercentages
    }
}

public enum BudgetUnit: String, Codable, CaseIterable, Sendable {
    case tokens
    case dollars

    public var displayName: String {
        switch self {
        case .tokens: "Tokens"
        case .dollars: "US dollars"
        }
    }
}

public struct UsageBudget: Equatable, Sendable {
    public var unit: BudgetUnit
    public var amount: Double

    public init(unit: BudgetUnit, amount: Double) {
        self.unit = unit
        self.amount = amount
    }

    public func percentage(for usage: UsageTotals) -> Double? {
        guard amount > 0, amount.isFinite else { return nil }

        let consumed: Double
        switch unit {
        case .tokens:
            consumed = Double(usage.totalTokens)
        case .dollars:
            consumed = usage.totalCost
        }

        guard consumed.isFinite, consumed >= 0 else { return nil }
        return consumed / amount * 100
    }
}

public enum UsageParsingError: Error, Equatable {
    case unsupportedDocument
}
