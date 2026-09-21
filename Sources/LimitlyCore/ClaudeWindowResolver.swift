import Foundation

/// Picks which of the Claude sources to believe, in descending order of how
/// real their numbers are, and dates whatever it picks.
///
/// The order matters more than it looks. Only one of these three sources
/// reports Anthropic's own reset time; the other two reconstruct it, and a
/// reconstructed boundary that lands an hour early is what made the popover
/// disagree with the Claude app about when the session ends.
public enum ClaudeWindowResolver {
    /// How fresh the desktop app's samples must be before its estimated
    /// session boundary is worth showing at all. The app only writes samples
    /// while it is running, and the estimate is a backward scan for where the
    /// percentage dropped — on a machine where Claude Code does the work and
    /// the desktop app is rarely open, that scan lands on whichever sample
    /// happened to be written last, which is not a session boundary at all.
    private static let desktopResetTrustWindow: TimeInterval = 30 * 60
    private static let sessionUsableAge: TimeInterval = 5 * 3600
    private static let weeklyUsableAge: TimeInterval = 24 * 3600

    public static func windows(
        statusLine: ClaudeStatusLineSnapshot?,
        desktop: PlanUsageSnapshot?,
        ccusageBlockEnd: Date?,
        now: Date
    ) -> AgentUsageWindows? {
        let session = statusLineSession(statusLine, now: now)
            ?? desktopSession(desktop, ccusageBlockEnd: ccusageBlockEnd, now: now)
        let weekly = statusLineWeekly(statusLine, now: now)
            ?? desktopWeekly(desktop, now: now)

        // A lone reset time with no percentage to attach it to would be a
        // countdown to nothing.
        guard session != nil || weekly != nil else { return nil }
        return AgentUsageWindows(session: session, weekly: weekly)
    }

    /// Anthropic's own figures, relayed by Claude Code's status line — the
    /// only local source with a real `resets_at`.
    private static func statusLineSession(_ snapshot: ClaudeStatusLineSnapshot?, now: Date) -> RateLimitWindow? {
        guard let snapshot, now.timeIntervalSince(snapshot.observedAt) <= sessionUsableAge else { return nil }
        guard let percent = snapshot.fiveHourPercent else {
            // Claude Code omits a window from that payload once its reset has
            // passed, so an otherwise-present reading with no `five_hour` is a
            // positive statement that the session window is empty — not
            // missing data. This is the fast path that clears a stale 100%.
            return RateLimitWindow(usedPercent: 0, resetsAt: nil, observedAt: snapshot.observedAt, source: .claudeStatusLine)
        }
        return RateLimitWindow(
            usedPercent: percent,
            resetsAt: snapshot.fiveHourResetsAt,
            observedAt: snapshot.observedAt,
            source: .claudeStatusLine
        )
    }

    private static func statusLineWeekly(_ snapshot: ClaudeStatusLineSnapshot?, now: Date) -> RateLimitWindow? {
        guard let snapshot, now.timeIntervalSince(snapshot.observedAt) <= weeklyUsableAge,
              let percent = snapshot.sevenDayPercent else { return nil }
        return RateLimitWindow(
            usedPercent: percent,
            resetsAt: snapshot.sevenDayResetsAt,
            observedAt: snapshot.observedAt,
            source: .claudeStatusLine
        )
    }

    private static func desktopSession(_ desktop: PlanUsageSnapshot?, ccusageBlockEnd: Date?, now: Date) -> RateLimitWindow? {
        guard let desktop else { return nil }
        let sampleAge = now.timeIntervalSince(desktop.latestSampleTime)
        let estimatedReset = ccusageBlockEnd
            ?? (sampleAge <= desktopResetTrustWindow ? desktop.sessionResetTime : nil)
        return RateLimitWindow(
            usedPercent: desktop.fiveHourPercent,
            resetsAt: estimatedReset,
            // Both candidates above are local reconstructions, not Anthropic's
            // own boundary: ccusage floors a block's start to the hour, and
            // the desktop estimate scans for a drop between 15-minute samples.
            resetIsApproximate: true,
            observedAt: desktop.latestSampleTime,
            source: .claudeDesktop
        )
    }

    private static func desktopWeekly(_ desktop: PlanUsageSnapshot?, now: Date) -> RateLimitWindow? {
        guard let desktop else { return nil }
        return RateLimitWindow(
            usedPercent: desktop.sevenDayPercent,
            resetsAt: nil,
            observedAt: desktop.latestSampleTime,
            source: .claudeDesktop
        )
    }
}
