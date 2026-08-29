import Foundation

public struct IdleEvent: Equatable, Sendable {
    public let agent: AgentID
    public let idleSince: Date

    public init(agent: AgentID, idleSince: Date) {
        self.agent = agent
        self.idleSince = idleSince
    }
}

public struct ActivityTracker: Sendable {
    private struct State: Sendable {
        var usage: UsageTotals
        var lastActivity: Date?
        var isActive: Bool
    }

    private var states: [AgentID: State] = [:]

    public init() {}

    public mutating func observe(
        usages: [AgentID: UsageTotals],
        at date: Date,
        idleInterval: TimeInterval
    ) -> [IdleEvent] {
        var idleEvents: [IdleEvent] = []

        for (agent, usage) in usages {
            guard var state = states[agent] else {
                states[agent] = State(usage: usage, lastActivity: nil, isActive: false)
                continue
            }

            let increased = usage.totalTokens > state.usage.totalTokens || usage.totalCost > state.usage.totalCost
            let reset = usage.totalTokens < state.usage.totalTokens || usage.totalCost < state.usage.totalCost

            if increased {
                state.lastActivity = date
                state.isActive = true
            } else if reset {
                state.lastActivity = nil
                state.isActive = false
            } else if state.isActive,
                      let lastActivity = state.lastActivity,
                      date.timeIntervalSince(lastActivity) >= max(0, idleInterval) {
                idleEvents.append(IdleEvent(agent: agent, idleSince: lastActivity))
                state.isActive = false
            }

            state.usage = usage
            states[agent] = state
        }

        return idleEvents
    }
}
