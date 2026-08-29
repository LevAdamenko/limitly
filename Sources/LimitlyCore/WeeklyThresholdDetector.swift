import Foundation

public struct WeeklyThresholdEvent: Equatable, Sendable {
    public let agent: AgentID
    public let threshold: Double
    public let percentage: Double
    public init(agent: AgentID, threshold: Double, percentage: Double) { self.agent = agent; self.threshold = threshold; self.percentage = percentage }
}

public struct WeeklyThresholdDetector: Sendable {
    private var previousPercentages: [AgentID: Double] = [:]
    public init() {}
    public mutating func observe(percentages: [AgentID: Double], thresholds: [AgentID: Double]) -> [WeeklyThresholdEvent] {
        var events: [WeeklyThresholdEvent] = []
        for (agent, percentage) in percentages where percentage.isFinite {
            defer { previousPercentages[agent] = percentage }
            guard let previous = previousPercentages[agent], let threshold = thresholds[agent], threshold.isFinite, threshold >= 0, previous < threshold, percentage >= threshold else { continue }
            events.append(WeeklyThresholdEvent(agent: agent, threshold: threshold, percentage: percentage))
        }
        return events
    }
}
