import Foundation

/// Where a percentage came from, so the UI can be honest about how real it is.
public enum UsageSource: String, Equatable, Sendable {
    /// Anthropic's own API figures, relayed by Claude Code's status line.
    case claudeStatusLine
    /// Anthropic's own API figures, but sampled ~every 15 minutes by the
    /// Claude desktop app and only while that app is running.
    case claudeDesktop
    /// OpenAI's own API figures, from the local `codex` app-server.
    case codexAppServer
    /// ccusage's reconstruction of the 5-hour block from local CLI logs.
    case ccusageBlocks
    /// Tokens/dollars measured locally, divided by a budget the user typed in.
    case budgetEstimate

    /// Whether this source reports the provider's own number rather than a
    /// locally-derived approximation.
    public var isAuthoritative: Bool {
        switch self {
        case .claudeStatusLine, .claudeDesktop, .codexAppServer: return true
        case .ccusageBlocks, .budgetEstimate: return false
        }
    }
}

/// One usage window (the ~5-hour session window or the 7-day weekly one) as
/// it was observed at a particular moment.
///
/// The whole point of carrying `observedAt` and `resetsAt` together is that a
/// percentage alone is meaningless without them: every local source here is a
/// snapshot that can be minutes or days old, and every window silently rolls
/// over to 0% at its reset time whether or not anything wrote a new snapshot.
/// `resolve(at:)` is what turns "what we last saw" into "what is true now".
public struct RateLimitWindow: Equatable, Sendable {
    public let usedPercent: Double
    /// Epoch at which this window rolls over, when the source reports one.
    public let resetsAt: Date?
    /// `resetsAt` was reconstructed locally (ccusage's hour-floored block
    /// boundaries, or the desktop cache's percentage-drop scan) rather than
    /// reported by the provider. Approximate reset times are shown with a "~"
    /// and, crucially, are never used to roll the window over to 0% — they can
    /// sit up to an hour before the real boundary, and zeroing a window that
    /// is genuinely still at 80% is a worse error than briefly showing a
    /// percentage that is too high.
    public let resetIsApproximate: Bool
    /// When this measurement was taken — *not* when we read it off disk.
    public let observedAt: Date
    public let source: UsageSource

    public init(usedPercent: Double, resetsAt: Date?, resetIsApproximate: Bool = false, observedAt: Date, source: UsageSource) {
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.resetIsApproximate = resetIsApproximate
        self.observedAt = observedAt
        self.source = source
    }
}

/// A window interpreted against the current time.
public struct ResolvedRateLimit: Equatable, Sendable {
    public let usedPercent: Double
    public let resetsAt: Date?
    public let resetIsApproximate: Bool
    public let source: UsageSource
    /// How old the underlying measurement is.
    public let age: TimeInterval
    /// The measurement is older than the source's expected refresh cadence —
    /// the number is probably still roughly right, but say so in the UI.
    public let isStale: Bool
    /// The window's reset time has passed since it was measured, so the
    /// percentage was reset to 0 here without waiting for a fresh reading.
    public let didRollOver: Bool

    public init(usedPercent: Double, resetsAt: Date?, resetIsApproximate: Bool = false, source: UsageSource, age: TimeInterval, isStale: Bool, didRollOver: Bool) {
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.resetIsApproximate = resetIsApproximate
        self.source = source
        self.age = age
        self.isStale = isStale
        self.didRollOver = didRollOver
    }
}

extension RateLimitWindow {
    /// Interprets the stored measurement at `now`.
    ///
    /// Three things happen here, in order:
    ///
    /// 1. **Roll-over.** If `resetsAt` has passed, the window is empty again —
    ///    report 0% immediately rather than repeating a stale "100%" until
    ///    some log or poll happens to refresh. The new reset time is genuinely
    ///    unknown (these windows are anchored to the first request of the next
    ///    session, not to a fixed clock grid), so it becomes `nil` rather than
    ///    a guess.
    /// 2. **Expiry.** A measurement older than `discardAfter` is dropped
    ///    entirely (`nil`), because a source that has gone quiet for longer
    ///    than a full window tells us nothing about now. Sources without a
    ///    `resetsAt` rely on this as their only roll-over protection.
    /// 3. **Staleness.** Anything older than `staleAfter` is still shown, but
    ///    flagged so the UI can date it.
    public func resolve(
        at now: Date = Date(),
        staleAfter: TimeInterval = 10 * 60,
        discardAfter: TimeInterval = 5 * 3600
    ) -> ResolvedRateLimit? {
        let age = max(0, now.timeIntervalSince(observedAt))
        guard age <= discardAfter else { return nil }

        if let resetsAt, !resetIsApproximate, now >= resetsAt {
            return ResolvedRateLimit(
                usedPercent: 0,
                resetsAt: nil,
                source: source,
                age: age,
                // A rolled-over window is a *fresh* fact ("it is empty now"),
                // derived from the reset time rather than from the old
                // reading, so it must not inherit the reading's staleness.
                isStale: false,
                didRollOver: true
            )
        }

        return ResolvedRateLimit(
            usedPercent: usedPercent,
            // An approximate boundary that has already gone by tells the user
            // nothing useful, so it is dropped rather than shown in the past.
            resetsAt: resetsAt.flatMap { $0 > now ? $0 : nil },
            resetIsApproximate: resetIsApproximate,
            source: source,
            age: age,
            isStale: age > staleAfter,
            didRollOver: false
        )
    }
}

/// The pair of windows Limitly tracks for one agent.
public struct AgentUsageWindows: Equatable, Sendable {
    public var session: RateLimitWindow?
    public var weekly: RateLimitWindow?

    public init(session: RateLimitWindow? = nil, weekly: RateLimitWindow? = nil) {
        self.session = session
        self.weekly = weekly
    }
}
