import Foundation

public struct ThresholdEvent: Equatable, Sendable {
    public let agent: AgentID
    public let threshold: Double
    public let percentage: Double

    public init(agent: AgentID, threshold: Double, percentage: Double) {
        self.agent = agent
        self.threshold = threshold
        self.percentage = percentage
    }
}

public struct ThresholdDetector: Sendable {
    private var previousPercentages: [AgentID: Double] = [:]

    public init() {}

    public mutating func observe(
        percentages: [AgentID: Double],
        thresholds: [AgentID: [Double]]
    ) -> [ThresholdEvent] {
        var events: [ThresholdEvent] = []

        for (agent, percentage) in percentages where percentage.isFinite {
            defer { previousPercentages[agent] = percentage }
            guard let previous = previousPercentages[agent] else { continue }

            let configured = Set((thresholds[agent] ?? []).filter { $0 >= 0 && $0.isFinite })
            for threshold in configured.sorted() where previous < threshold && percentage >= threshold {
                events.append(ThresholdEvent(agent: agent, threshold: threshold, percentage: percentage))
            }
        }

        return events
    }
}
