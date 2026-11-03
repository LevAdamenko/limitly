import Foundation

/// Decides when the two `ccusage` passes are worth paying for.
///
/// Each pass starts Node and re-reads every local usage log — about a second
/// of CPU apiece against a large `~/.claude/projects`. Running both every five
/// seconds kept a core near half busy around the clock and drained the
/// battery even while nothing was being used. Nothing in their output can
/// change unless a log is written, a day ends, or the active block expires, so
/// those are the only things that trigger a pass — plus a slow safety net for
/// a missed filesystem event.
///
/// Even then, a pass only runs when its output would be looked at: the menu
/// bar shows the providers' real percentages, so the token and dollar totals
/// matter only in the open popover or when a real figure is missing.
public struct CCUsageRefreshPolicy: Sendable {
    public struct State: Equatable, Sendable {
        public var lastBlocksRun: Date?
        public var lastDailyRun: Date?
        public var logsChangedSinceBlocks: Bool
        public var logsChangedSinceDaily: Bool
        public var activeBlockEnd: Date?
        /// Something will read the result. After the first pass of each kind,
        /// no pass starts while this is false.
        public var resultNeeded: Bool

        public init(
            lastBlocksRun: Date? = nil,
            lastDailyRun: Date? = nil,
            logsChangedSinceBlocks: Bool = false,
            logsChangedSinceDaily: Bool = false,
            activeBlockEnd: Date? = nil,
            resultNeeded: Bool = true
        ) {
            self.lastBlocksRun = lastBlocksRun
            self.lastDailyRun = lastDailyRun
            self.logsChangedSinceBlocks = logsChangedSinceBlocks
            self.logsChangedSinceDaily = logsChangedSinceDaily
            self.activeBlockEnd = activeBlockEnd
            self.resultNeeded = resultNeeded
        }
    }

    public struct Plan: Equatable, Sendable {
        public var blocks: Bool
        public var daily: Bool
        public var isEmpty: Bool { !blocks && !daily }

        public init(blocks: Bool, daily: Bool) {
            self.blocks = blocks
            self.daily = daily
        }
    }

    /// While logs keep changing, the current block's totals are re-measured
    /// at most this often.
    public var blocksInterval: TimeInterval
    /// The 7-day totals move slowly and are the heavier pass.
    public var dailyInterval: TimeInterval
    /// Re-runs both regardless, in case a filesystem event was missed.
    public var safetyInterval: TimeInterval

    public init(blocksInterval: TimeInterval = 30, dailyInterval: TimeInterval = 60, safetyInterval: TimeInterval = 15 * 60) {
        self.blocksInterval = blocksInterval
        self.dailyInterval = dailyInterval
        self.safetyInterval = safetyInterval
    }

    public func plan(now: Date, state: State, calendar: Calendar = .current) -> Plan {
        Plan(blocks: blocksDue(now: now, state: state), daily: dailyDue(now: now, state: state, calendar: calendar))
    }

    private func blocksDue(now: Date, state: State) -> Bool {
        guard let last = state.lastBlocksRun else { return true }
        guard state.resultNeeded else { return false }
        let elapsed = now.timeIntervalSince(last)
        if elapsed >= safetyInterval || elapsed < 0 { return true }
        if state.logsChangedSinceBlocks && elapsed >= blocksInterval { return true }
        // The block ran out since we last looked: its totals must drop to
        // zero now, not up to `safetyInterval` later.
        if let end = state.activeBlockEnd, now >= end, last < end { return true }
        return false
    }

    private func dailyDue(now: Date, state: State, calendar: Calendar) -> Bool {
        guard let last = state.lastDailyRun else { return true }
        guard state.resultNeeded else { return false }
        let elapsed = now.timeIntervalSince(last)
        if elapsed >= safetyInterval || elapsed < 0 { return true }
        if state.logsChangedSinceDaily && elapsed >= dailyInterval { return true }
        // "Today" and the trailing 7-day range both move at midnight.
        if !calendar.isDate(last, inSameDayAs: now) { return true }
        return false
    }
}
