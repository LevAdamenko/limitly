import Foundation

public struct SessionBlock: Equatable, Sendable {
    public let startTime: Date
    public let endTime: Date
    public let isActive: Bool
    public let usage: UsageTotals

    public init(startTime: Date, endTime: Date, isActive: Bool, usage: UsageTotals = UsageTotals(totalTokens: 0, totalCost: 0)) {
        self.startTime = startTime
        self.endTime = endTime
        self.isActive = isActive
        self.usage = usage
    }
    public func remainingTime(at date: Date) -> TimeInterval? { guard isActive else { return nil }; return max(0, endTime.timeIntervalSince(date)) }
}

public enum SessionBlockCalculator {
    public static func resetTime(for blocks: [SessionBlock]) -> Date? { blocks.first(where: \.isActive)?.endTime }
}
