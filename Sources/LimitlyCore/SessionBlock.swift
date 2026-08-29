import Foundation

public struct SessionBlock: Equatable, Sendable {
    public let startTime: Date
    public let endTime: Date
    public let isActive: Bool
    public init(startTime: Date, endTime: Date, isActive: Bool) { self.startTime = startTime; self.endTime = endTime; self.isActive = isActive }
    public func remainingTime(at date: Date) -> TimeInterval? { guard isActive else { return nil }; return max(0, endTime.timeIntervalSince(date)) }
}

public enum SessionBlockCalculator {
    public static func resetTime(for blocks: [SessionBlock]) -> Date? { blocks.first(where: \.isActive)?.endTime }
}
