import AppKit
import Combine
import Foundation
import SwiftUI
import UserNotifications
import LimitlyCore

@MainActor
final class UsageMonitor: ObservableObject {
    @Published private(set) var snapshot = UsageSnapshot(currentUsage: [:], weeklyUsage: [:])
    @Published private(set) var lastError: String?
    /// The moment `snapshot`'s windows were last interpreted. While the popover
    /// is closed it only moves along with `snapshot`, since nothing reads it.
    @Published private(set) var resolvedAt = Date()
    @Published private(set) var isRefreshing = false
    let settings = SettingsStore()

    private var thresholdDetector = ThresholdDetector()
    private var weeklyDetector = WeeklyThresholdDetector()
    private var logActivityTracker = LogActivityTracker()
    private var sessionActivityTracker = SessionActivityTracker()
    private let banner = BannerController()

    /// A slow housekeeping pass: changes normally arrive through the watchers
    /// below, so this only has to catch what they cannot report. See
    /// `tickInterval`.
    private var tickTimer: Timer?
    /// Fires exactly when the next real reset time passes, so a window drops
    /// to 0% on time without a fast timer running all day.
    private var resetTimer: Timer?
    private var scheduledResetDate: Date?
    private var logWatcher: LogWatcher?
    /// Reports new status-line readings as soon as they land.
    private var statusLineWatcher: DirectoryWatcher?
    private var settingsCancellable: AnyCancellable?
    private var wakeObserver: NSObjectProtocol?
    private var isPopoverVisible = false

    /// `refreshCCUsage` shells out to `npx ccusage` (up to twice), each with
    /// a 20s timeout; guarding against overlap keeps a slow call from letting
    /// the timer pile up concurrent subprocesses that all contend for npm's
    /// shared package-install lock.
    private var isFetchingCCUsage = false
    /// Deliberately a *separate* guard from the one above. These two sources
    /// used to share one serialized path, so a single slow `npx` run starved
    /// the Codex probe for tens of seconds at a time — the main reason Codex's
    /// number went stale far more often than Claude's.
    private var isProbingCodex = false
    /// Kept apart from `npx` for the same reason: the real Claude percentages
    /// come from these files, and must not wait on a `ccusage` run.
    private var isReadingLocal = false

    private let ccusagePolicy = CCUsageRefreshPolicy()
    private let codexPolicy = CodexProbePolicy()
    private var lastCodexProbe: Date?
    private var lastCodexProbeFailed = false
    private var codexLogGeneration = 0
    private var codexSeenGeneration = 0
    private var lastBlocksRun: Date?
    private var lastDailyRun: Date?
    /// Bumped on every batch of log writes the watcher reports; a pass that
    /// succeeds records the value it started from, so writes that land
    /// mid-run still count as unseen.
    private var logGeneration = 0
    private var claudeLogGeneration = 0
    private var dailySeenGeneration = -1
    private var blocksSeenGeneration = -1
    /// When each agent's logs were last written, as reported by `logWatcher`.
    private var lastLogWrite: [AgentID: Date] = [:]

    private var ccusageRows: [AgentID: [DatedUsage]]?
    /// `nil` until a `blocks` pass has succeeded — distinct from an empty
    /// list, which positively means no session is active.
    private var ccusageBlocks: [SessionBlock]?
    private var ccusageError: String?
    private var localSources = LocalClaudeSources()
    private var ccusagePortion = CCUsagePortion()
    private var codexWindows: AgentUsageWindows?

    init() {
        logWatcher = LogWatcher { [weak self] agents in
            let now = Date()
            Task { @MainActor in self?.noteLogWrites(agents, at: now) }
        }
        ClaudeStatusLineInstaller.refreshScriptIfInstalled()
        watchStatusLineIfNeeded()
        refresh()
        rescheduleTick()
        settingsCancellable = settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rescheduleTick() }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // The network usually needs a moment after waking up.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                MainActor.assumeIsolated {
                    self?.refreshLocal()
                    self?.refreshCodex(force: true)
                }
            }
        }
    }
    deinit {
        tickTimer?.invalidate()
        resetTimer?.invalidate()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }

    /// Countdowns in the open popover and idle detection are the only things
    /// that need a quicker pace.
    private var tickInterval: TimeInterval { isPopoverVisible || settings.idleNotificationsEnabled ? 15 : 60 }

    private func rescheduleTick() {
        let interval = tickInterval
        if let tickTimer, tickTimer.isValid, tickTimer.timeInterval == interval { return }
        tickTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // Lets macOS batch this wake-up with others.
        timer.tolerance = interval / 3
        tickTimer = timer
    }

    private func tick() {
        watchStatusLineIfNeeded()
        refreshLocal()
        refreshCCUsage()
        refreshCodexIfDue()
    }

    /// `~/.limitly` only exists once the status line has been connected.
    private func watchStatusLineIfNeeded() {
        guard statusLineWatcher == nil else { return }
        statusLineWatcher = DirectoryWatcher(url: ClaudeStatusLineInstaller.limitlyDirectoryURL) { [weak self] in
            Task { @MainActor in self?.refreshLocal() }
        }
    }

    /// Called by the status item as the popover opens and closes.
    func setPopoverVisible(_ visible: Bool) {
        guard visible != isPopoverVisible else { return }
        isPopoverVisible = visible
        rescheduleTick()
        guard visible else { return }
        refreshLocal()
        refreshCCUsage()
        refreshCodexIfDue()
    }

    // MARK: - Display

    var menuBarTitle: String { "Claude \(percentageText(for: .claude)) · Codex \(percentageText(for: .codex))" }
    /// Prefers the provider's own real percentage over the budget-derived
    /// estimate when one is available — see `realPercentage(for:)`.
    func percentageText(for agent: AgentID) -> String { guard let value = realPercentage(for: agent) else { return "—" }; return "\(Int(settings.displayed(value).rounded()))%" }
    /// The actual fraction of budget used, ignoring the "Show percentage
    /// as" display toggle — for UI that visualizes severity (progress bars,
    /// color coding), which must reflect real usage even when the user has
    /// chosen to display the inverted "Remaining" number as text.
    func usedFraction(for agent: AgentID) -> Double? { realPercentage(for: agent) }
    func weeklyText(for agent: AgentID) -> String { guard let usage = snapshot.weeklyUsage[agent] else { return "No data" }; let real = snapshot.realWeeklyPercentages[agent]; let pct = (real ?? settings.weeklyBudget(for: agent).percentage(for: usage)).map { " (\(Int(settings.displayed($0).rounded()))%)" } ?? ""; return format(usage, unit: settings.budget(for: agent).unit) + pct }
    private func realPercentage(for agent: AgentID) -> Double? {
        if let real = snapshot.realCurrentPercentages[agent] { return real }
        guard let usage = snapshot.currentUsage[agent] else { return nil }
        return settings.budget(for: agent).percentage(for: usage)
    }
    func usageText(for agent: AgentID) -> String { guard let usage = snapshot.currentUsage[agent] else { return agent == .claude ? "No usage in current session" : "No usage today" }; let label = agent == .claude ? "Current session" : "Today"; return "\(label): \(format(usage, unit: settings.budget(for: agent).unit))" }

    func resetText(for agent: AgentID) -> String? {
        guard let resolved = resolvedSession(for: agent) else { return nil }
        return resetPhrase(resolved, label: "Session")
    }

    func weeklyResetText(for agent: AgentID) -> String? {
        guard let resolved = resolvedWeekly(for: agent) else { return nil }
        return resetPhrase(resolved, label: "Weekly")
    }

    /// Dates the number when its source has gone quiet, so a figure that is
    /// quietly hours old never passes for a live one.
    func freshnessText(for agent: AgentID) -> String? {
        guard let resolved = resolvedSession(for: agent), resolved.isStale else { return nil }
        let age = Self.durationFormatter.string(from: resolved.age) ?? "a while"
        return "Last reading \(age) ago"
    }

    func resolvedSession(for agent: AgentID) -> ResolvedRateLimit? {
        guard let window = snapshot.windows[agent]?.session else { return nil }
        return window.resolve(at: resolvedAt, staleAfter: Self.staleAfter(window.source), discardAfter: Self.sessionDiscardAfter)
    }

    func resolvedWeekly(for agent: AgentID) -> ResolvedRateLimit? {
        guard let window = snapshot.windows[agent]?.weekly else { return nil }
        return window.resolve(at: resolvedAt, staleAfter: Self.staleAfter(window.source), discardAfter: Self.weeklyDiscardAfter)
    }

    /// One full session window: past that, a reading that nothing has
    /// refreshed says nothing about now.
    private static let sessionDiscardAfter: TimeInterval = 5 * 3600
    /// A weekly window moves slowly, so an older reading is still a useful
    /// floor — but not one from days ago.
    private static let weeklyDiscardAfter: TimeInterval = 24 * 3600

    private static func staleAfter(_ source: UsageSource) -> TimeInterval {
        switch source {
        // Probed at least every five minutes, even on a quiet machine; a
        // reading older than two missed probes means the probe is failing.
        case .codexAppServer: return 12 * 60
        // Only written while some Claude Code session renders its status
        // line — but while nobody is using Claude Code, the figure is not
        // going anywhere either, and the window's real reset time (which this
        // source does report) covers the one way it can silently expire. The
        // case this guards is usage arriving from claude.ai or the desktop
        // app, which never touches the status line.
        case .claudeStatusLine: return 30 * 60
        // The desktop app samples roughly every 15 minutes, and only while it
        // is running at all.
        case .claudeDesktop: return 25 * 60
        case .ccusageBlocks, .budgetEstimate: return 5 * 60
        }
    }

    private func resetPhrase(_ resolved: ResolvedRateLimit, label: String) -> String? {
        guard let reset = resolved.resetsAt else { return nil }
        let now = Date()
        let tilde = resolved.resetIsApproximate ? "~" : ""
        let clock = Self.clockText(for: reset, now: now)
        let relative = Self.durationFormatter.string(from: max(0, reset.timeIntervalSince(now))) ?? "under a minute"
        switch settings.resetDisplay {
        case .absolute: return "\(label) resets at \(tilde)\(clock)"
        case .relative: return "\(label) resets in \(tilde)\(relative)"
        case .both: return "\(label) resets at \(tilde)\(clock) · in \(relative)"
        }
    }

    /// Same-day resets read as a bare clock time; a weekly window landing
    /// days out needs the day name to mean anything.
    private static func clockText(for date: Date, now: Date) -> String {
        Calendar.current.isDate(date, inSameDayAs: now)
            ? timeFormatter.string(from: date)
            : dayAndTimeFormatter.string(from: date)
    }
    private static let timeFormatter: DateFormatter = { let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none; return f }()
    private static let dayAndTimeFormatter: DateFormatter = { let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("EEE jm"); return f }()
    private static let durationFormatter: DateComponentsFormatter = { let f = DateComponentsFormatter(); f.allowedUnits = [.hour, .minute]; f.unitsStyle = .abbreviated; f.zeroFormattingBehavior = .dropAll; return f }()

    /// Fires a real alert through the same delivery path as a genuine
    /// threshold/idle event, so the user can check banner placement, sound,
    /// and (if switched to `.notification`) the native alert without
    /// waiting for real usage to cross a threshold.
    func sendTestAlert() { deliver(title: "Limitly test alert", body: "This is what a usage alert looks like.") }

    // MARK: - Refresh

    func refresh(force: Bool = false) {
        refreshLocal()
        refreshCCUsage(force: force)
        refreshCodex(force: force)
    }

    private func refreshLocal() {
        guard !isReadingLocal else { return }
        isReadingLocal = true
        let idleNotificationsEnabled = settings.idleNotificationsEnabled
        Task.detached(priority: .utility) { [weak self] in
            let sources = LocalClaudeSources(
                statusLine: ClaudeStatusLineUsageFile.currentSnapshot(),
                desktop: ClaudeDesktopUsageClient.currentSnapshot()
            )
            // Skip the AppleScript round-trip entirely when idle
            // notifications are off — no point paying for it on every
            // refresh if nothing will use it.
            let terminals = idleNotificationsEnabled ? GhosttyController.openTerminals() : []
            await self?.applyLocal(sources, terminals: terminals)
        }
    }

    /// Runs only the `ccusage` passes `ccusagePolicy` says are due — nothing
    /// at all while no log is being written or nothing would read the result.
    /// `force` (the manual Refresh button) runs both.
    private func refreshCCUsage(force: Bool = false) {
        guard !isFetchingCCUsage else { return }
        let now = Date()
        let state = CCUsageRefreshPolicy.State(
            lastBlocksRun: lastBlocksRun,
            lastDailyRun: lastDailyRun,
            logsChangedSinceBlocks: claudeLogGeneration != blocksSeenGeneration,
            logsChangedSinceDaily: logGeneration != dailySeenGeneration,
            activeBlockEnd: ccusageBlocks?.first(where: \.isActive)?.endTime,
            resultNeeded: isPopoverVisible || isMissingRealPercentage
        )
        let plan = force ? CCUsageRefreshPolicy.Plan(blocks: true, daily: true) : ccusagePolicy.plan(now: now, state: state)
        guard !plan.isEmpty else { return }
        isFetchingCCUsage = true
        updateBusyFlag()
        let generation = logGeneration
        let claudeGeneration = claudeLogGeneration
        Task.detached(priority: .utility) { [weak self] in
            let fetched = CCUsageClient.fetch(plan)
            await self?.applyCCUsage(fetched, plan: plan, startedAt: now, generation: generation, claudeGeneration: claudeGeneration)
        }
    }

    /// The budget estimate behind a missing real percentage comes from
    /// `ccusage`, for both the menu bar and threshold alerts. With every real
    /// figure present, its totals only appear in the popover.
    private var isMissingRealPercentage: Bool {
        AgentID.allCases.contains { snapshot.realCurrentPercentages[$0] == nil || snapshot.realWeeklyPercentages[$0] == nil }
    }

    private func noteLogWrites(_ agents: Set<AgentID>, at date: Date) {
        for agent in agents { lastLogWrite[agent] = date }
        logGeneration += 1
        if agents.contains(.claude) { claudeLogGeneration += 1 }
        if agents.contains(.codex) { codexLogGeneration += 1 }
        refreshCCUsage()
        refreshCodexIfDue()
    }

    private func refreshCodexIfDue() {
        let state = CodexProbePolicy.State(
            lastAttempt: lastCodexProbe,
            logsChangedSinceProbe: codexLogGeneration != codexSeenGeneration,
            lastAttemptFailed: lastCodexProbeFailed,
            isForeground: isPopoverVisible
        )
        if codexPolicy.isDue(now: Date(), state: state) { refreshCodex() }
    }

    /// `force` bypasses the probe's short cache — the automatic timer never
    /// sets it (that cache is what keeps polling cheap), but the manual
    /// Refresh button does, since silently returning the same cached Codex
    /// numbers made the button look like it wasn't doing anything.
    private func refreshCodex(force: Bool = false) {
        guard !isProbingCodex else { return }
        isProbingCodex = true
        updateBusyFlag()
        let startedAt = Date()
        let generation = codexLogGeneration
        lastCodexProbe = startedAt
        Task.detached(priority: .utility) { [weak self] in
            let dated = CodexRateLimitClient.shared.currentSnapshot(now: startedAt, forceRefresh: force)
            await self?.applyCodex(dated, startedAt: startedAt, generation: generation)
        }
    }

    private func applyLocal(_ sources: LocalClaudeSources, terminals: [GhosttyTerminal]) {
        isReadingLocal = false
        localSources = sources
        recompose()
        rebuild()
        evaluateIdle(terminals: terminals)
    }

    private func applyCCUsage(_ fetched: CCUsageFetch, plan: CCUsageRefreshPolicy.Plan, startedAt: Date, generation: Int, claudeGeneration: Int) {
        isFetchingCCUsage = false
        updateBusyFlag()
        // A failed pass still counts as a run, so a broken `npx` is retried
        // at the policy's pace rather than on every tick — but its generation
        // is not marked seen, so the retry does come.
        if plan.daily {
            lastDailyRun = startedAt
            if let rows = fetched.rows {
                ccusageRows = rows
                ccusageError = nil
                dailySeenGeneration = generation
            } else {
                ccusageError = fetched.dailyError
            }
        }
        if plan.blocks {
            lastBlocksRun = startedAt
            if let blocks = fetched.blocks {
                ccusageBlocks = blocks
                blocksSeenGeneration = claudeGeneration
            }
        }
        recompose()
        rebuild()
    }

    /// Combines the last `ccusage` results with the latest local readings.
    /// Cheap, so it runs on every local tick: that is what lets the real
    /// percentages stay live while `ccusage` itself sits idle.
    private func recompose(now: Date = Date()) {
        let parser = CCUsageParser()
        let rows = ccusageRows ?? [:]
        var currentUsage = parser.usages(on: now, rows: rows)
        // A cached block that has run out is no longer active, even before
        // the `blocks` pass that will confirm it lands.
        let activeBlock = ccusageBlocks?.first { $0.isActive && $0.endTime > now }
        if let activeBlock {
            currentUsage[.claude] = activeBlock.usage
        } else if ccusageBlocks != nil {
            // Genuinely no active session, as opposed to the `blocks`
            // subprocess call itself failing (network hiccup, non-zero
            // exit, bad JSON) — in that failure case, overwriting with a
            // hard zero would visibly contradict a real non-zero percent
            // shown from the independent real sources.
            currentUsage[.claude] = UsageTotals(totalTokens: 0, totalCost: 0)
        }
        let claudeWindows = ClaudeWindowResolver.windows(
            statusLine: localSources.statusLine,
            desktop: localSources.desktop,
            ccusageBlockEnd: activeBlock?.endTime,
            now: now
        )
        ccusagePortion = CCUsagePortion(currentUsage: currentUsage, weeklyUsage: parser.aggregate(rows), claude: claudeWindows)
        // Don't surface a ccusage failure while a real percentage is there
        // to fall back on — that is still a useful, working display; it only
        // costs the budget-estimate fallback and the token/dollar totals.
        if let ccusageError, claudeWindows == nil {
            lastError = "ccusage refresh failed: \(ccusageError)"
        } else {
            lastError = nil
        }
    }

    private func applyCodex(_ dated: DatedCodexSnapshot?, startedAt: Date, generation: Int) {
        isProbingCodex = false
        updateBusyFlag()
        // A failed probe hands back the previous reading with its original
        // date, so an old date is what failure looks like from here.
        let succeeded = dated.map { $0.observedAt >= startedAt } ?? false
        lastCodexProbeFailed = !succeeded
        if succeeded { codexSeenGeneration = generation }
        if let dated {
            codexWindows = AgentUsageWindows(
                session: RateLimitWindow(
                    usedPercent: dated.snapshot.fiveHourPercent,
                    resetsAt: dated.snapshot.sessionResetTime,
                    observedAt: dated.observedAt,
                    source: .codexAppServer
                ),
                weekly: dated.snapshot.weeklyPercent.map {
                    RateLimitWindow(
                        usedPercent: $0,
                        resetsAt: dated.snapshot.weeklyResetTime,
                        observedAt: dated.observedAt,
                        source: .codexAppServer
                    )
                }
            )
        }
        rebuild()
    }

    private func updateBusyFlag() { isRefreshing = isFetchingCCUsage || isProbingCodex }

    // MARK: - Resolution

    /// Re-interprets everything currently known against the clock and
    /// publishes only what changed, so an unchanged reading redraws nothing.
    /// Cheap and side-effect-free apart from threshold alerts.
    private func rebuild(now: Date = Date()) {
        var windows: [AgentID: AgentUsageWindows] = [:]
        if let claude = ccusagePortion.claude { windows[.claude] = claude }
        if let codex = codexWindows { windows[.codex] = codex }

        var realCurrent: [AgentID: Double] = [:]
        var realWeekly: [AgentID: Double] = [:]
        var resets: [AgentID: Date] = [:]
        for agent in AgentID.allCases {
            if let session = windows[agent]?.session,
               let resolved = session.resolve(at: now, staleAfter: Self.staleAfter(session.source), discardAfter: Self.sessionDiscardAfter) {
                realCurrent[agent] = resolved.usedPercent
                if let reset = resolved.resetsAt { resets[agent] = reset }
            }
            if let weekly = windows[agent]?.weekly,
               let resolved = weekly.resolve(at: now, staleAfter: Self.staleAfter(weekly.source), discardAfter: Self.weeklyDiscardAfter) {
                realWeekly[agent] = resolved.usedPercent
            }
        }

        let rebuilt = UsageSnapshot(
            currentUsage: ccusagePortion.currentUsage,
            weeklyUsage: ccusagePortion.weeklyUsage,
            resetTimes: resets,
            realCurrentPercentages: realCurrent,
            realWeeklyPercentages: realWeekly,
            windows: windows
        )
        let changed = rebuilt != snapshot
        if changed { snapshot = rebuilt }
        if changed || isPopoverVisible { resolvedAt = now }
        evaluateThresholds()
        scheduleResetTimer(windows: windows, now: now)
    }

    /// Only real reset times count: an approximate one never rolls a window
    /// over. See `RateLimitWindow.resetIsApproximate`.
    private func scheduleResetTimer(windows: [AgentID: AgentUsageWindows], now: Date) {
        let next = windows.values
            .flatMap { [$0.session, $0.weekly] }
            .compactMap { $0 }
            .filter { !$0.resetIsApproximate }
            .compactMap(\.resetsAt)
            .filter { $0 > now }
            .min()
        guard next != scheduledResetDate else { return }
        scheduledResetDate = next
        resetTimer?.invalidate()
        resetTimer = nil
        guard let next else { return }
        let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.scheduledResetDate = nil
                self?.rebuild()
            }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        resetTimer = timer
    }

    // MARK: - Alerts

    private func evaluateThresholds() {
        let dailyPercentages = percentages(snapshot)
        let weeklyPercentages = weeklyPercentages(snapshot)
        let thresholdEvents = thresholdDetector.observe(percentages: dailyPercentages, thresholds: Dictionary(uniqueKeysWithValues: AgentID.allCases.map { ($0, settings.thresholds(for: $0)) }))
        let weeklyEvents = weeklyDetector.observe(percentages: weeklyPercentages, thresholds: Dictionary(uniqueKeysWithValues: AgentID.allCases.map { ($0, settings.config(for: $0).weeklyThreshold) }))
        // The detectors still observe every tick regardless of this toggle
        // (cheap, and keeps their crossing state correct for whenever it's
        // turned back on) — only delivery is gated per agent.
        for event in thresholdEvents where settings.config(for: event.agent).thresholdNotificationsEnabled {
            deliver(title: "\(event.agent.displayName) usage alert", body: "Current usage reached \(Int(event.threshold))% (\(Int(event.percentage.rounded()))%).")
        }
        for event in weeklyEvents where settings.config(for: event.agent).thresholdNotificationsEnabled {
            deliver(title: "\(event.agent.displayName) weekly usage alert", body: "Trailing 7-day usage reached \(Int(event.threshold))% (\(Int(event.percentage.rounded()))%).")
        }
    }

    private func evaluateIdle(terminals: [GhosttyTerminal]) {
        guard settings.idleNotificationsEnabled else { return }
        let now = Date()
        let candidates = terminals.flatMap { terminal in
            AgentID.allCases.map {
                SessionCandidate(agent: $0, workingDirectory: terminal.workingDirectory, tabTitle: terminal.title)
            }
        }
        let sessionObservation = sessionActivityTracker.observe(
            candidates: candidates,
            at: now,
            idleInterval: settings.idleSeconds
        )
        let fallbackWrites = lastLogWrite.filter { !sessionObservation.matchedAgents.contains($0.key) }
        let idleEvents = logActivityTracker.observe(lastWrites: fallbackWrites, at: now, idleInterval: settings.idleSeconds)
        for event in sessionObservation.idleEvents {
            deliver(
                title: "\(event.agent.displayName) is idle",
                body: "No new activity in \"\(event.tabTitle)\" for \(Int(settings.idleSeconds))s.",
                workingDirectory: event.workingDirectory
            )
        }
        for event in idleEvents { deliver(title: "\(event.agent.displayName) is idle", body: "No new usage has appeared for \(Int(settings.idleSeconds)) seconds.") }
    }

    private func percentages(_ snapshot: UsageSnapshot) -> [AgentID: Double] {
        Dictionary(uniqueKeysWithValues: AgentID.allCases.compactMap { agent -> (AgentID, Double)? in
            if let real = snapshot.realCurrentPercentages[agent] { return (agent, real) }
            guard let totals = snapshot.currentUsage[agent], let value = settings.budget(for: agent).percentage(for: totals) else { return nil }
            return (agent, value)
        })
    }
    private func weeklyPercentages(_ snapshot: UsageSnapshot) -> [AgentID: Double] {
        Dictionary(uniqueKeysWithValues: AgentID.allCases.compactMap { agent -> (AgentID, Double)? in
            if let real = snapshot.realWeeklyPercentages[agent] { return (agent, real) }
            guard let totals = snapshot.weeklyUsage[agent], let value = settings.weeklyBudget(for: agent).percentage(for: totals) else { return nil }
            return (agent, value)
        })
    }
    private func format(_ usage: UsageTotals, unit: BudgetUnit) -> String { switch unit { case .tokens: return "\(usage.totalTokens.formatted()) tokens"; case .dollars: return usage.totalCost.formatted(.currency(code: "USD")) } }
    private func deliver(title: String, body: String, workingDirectory: String? = nil) {
        if settings.delivery == .banner {
            let onClick: (() -> Void)? = workingDirectory.map { directory in
                {
                    _ = Task.detached { GhosttyController.focusTerminal(workingDirectory: directory) }
                }
            }
            banner.show(title: title, body: body, onClick: onClick)
        } else {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            if let workingDirectory {
                content.userInfo[IdleNotificationUserInfo.workingDirectory] = workingDirectory
            }
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }
    }
}

/// An app launched from Finder or at login inherits launchd's bare
/// `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, not the shell's, so `/usr/bin/env`
/// can't find `codex` or `npx` (nor the `node` their shebangs need) in
/// `/usr/local/bin` or Homebrew. Only launching from a terminal hid this.
/// Appending the usual install locations fixes it without overriding a PATH
/// that already has them.
private enum ToolEnvironment {
    static let current: [String: String] = {
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var entries = (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        for extra in ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.volta/bin", "\(home)/.bun/bin"] where !entries.contains(extra) {
            entries.append(extra)
        }
        environment["PATH"] = entries.joined(separator: ":")
        return environment
    }()
}

/// Everything the `ccusage` side contributes: the locally-measured
/// token/dollar totals that back the budget estimate, plus whatever Claude
/// windows the local sources could supply.
private struct CCUsagePortion: Sendable {
    var currentUsage: [AgentID: UsageTotals] = [:]
    var weeklyUsage: [AgentID: UsageTotals] = [:]
    var claude: AgentUsageWindows?
}

private struct LocalClaudeSources: Sendable {
    var statusLine: ClaudeStatusLineSnapshot?
    var desktop: PlanUsageSnapshot?
}

/// What one `CCUsageClient.fetch` produced; `nil` for a pass that was not
/// run or failed.
private struct CCUsageFetch: Sendable {
    var rows: [AgentID: [DatedUsage]]?
    var dailyError: String?
    var blocks: [SessionBlock]?
}

private struct DatedCodexSnapshot: Sendable {
    let snapshot: CodexRateLimitSnapshot
    /// When the probe that produced this actually ran.
    let observedAt: Date
}

private enum CCUsageClient {
    /// Pinned to an exact version rather than `@latest`. `@latest` is a
    /// dist-tag, which npm/npx refuses to trust from any local cache and
    /// re-resolves against the registry on *every* invocation — confirmed
    /// by direct measurement to take 25-30s+ against this app's isolated
    /// `npm_config_cache` (vs. under a second once pinned to an exact
    /// version, which npx can resolve entirely from local cache with zero
    /// network calls). That 25-30s comfortably exceeds `run`'s 20s timeout,
    /// so `@latest` was making this fail on every single 5-second refresh.
    private static let ccusagePackage = "ccusage@20.0.20"

    /// Runs only the passes `plan` asks for. Failures come back as `nil`
    /// results so the caller can keep the last good figures.
    static func fetch(_ plan: CCUsageRefreshPolicy.Plan, now: Date = Date()) -> CCUsageFetch {
        let parser = CCUsageParser()
        var result = CCUsageFetch()
        if plan.daily {
            let calendar = Calendar.current
            let since = calendar.date(byAdding: .day, value: -6, to: now) ?? now
            let formatter = DateFormatter(); formatter.calendar = calendar; formatter.dateFormat = "yyyy-MM-dd"
            do {
                let dailyData = try run(["--yes", ccusagePackage, "daily", "--json", "--by-agent", "--since", formatter.string(from: since), "--offline"])
                result.rows = try parser.parseDailyRows(dailyData)
            } catch {
                result.dailyError = error.localizedDescription
            }
        }
        if plan.blocks,
           let blocksData = try? run(["--yes", ccusagePackage, "blocks", "--json", "--active", "--offline"]),
           let blocks = try? parser.parseBlocks(blocksData) {
            result.blocks = blocks
        }
        return result
    }

    /// `npx` can stall for minutes if it contends with another concurrent
    /// invocation over npm's shared package-install lock (the caller
    /// already guards against overlapping refreshes, but this is a second,
    /// independent backstop). `timeout` bounds that; draining both pipes
    /// concurrently — rather than after `waitUntilExit()` — also avoids
    /// deadlocking against a child that fills either OS pipe buffer before
    /// exiting.
    private static func run(_ arguments: [String], timeout: TimeInterval = 20) throws -> Data {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/env"); process.arguments = ["npx"] + arguments
        var environment = ToolEnvironment.current; environment["npm_config_cache"] = FileManager.default.temporaryDirectory.appendingPathComponent("limitly-npm-cache", isDirectory: true).path; environment["NO_COLOR"] = "1"; process.environment = environment
        let output = Pipe(); let errors = Pipe(); process.standardOutput = output; process.standardError = errors
        process.qualityOfService = .utility
        try process.run()

        var outputData = Data(); var errorData = Data()
        let group = DispatchGroup()
        group.enter(); DispatchQueue.global(qos: .utility).async { outputData = output.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter(); DispatchQueue.global(qos: .utility).async { errorData = errors.fileHandleForReading.readDataToEndOfFile(); group.leave() }

        guard group.wait(timeout: .now() + timeout) == .success else {
            if process.isRunning { process.terminate(); process.waitUntilExit() }
            throw ClientError.failed("ccusage timed out after \(Int(timeout))s")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ClientError.failed(String(data: errorData, encoding: .utf8) ?? "unknown error") }
        return outputData
    }
    enum ClientError: LocalizedError { case failed(String); var errorDescription: String? { switch self { case .failed(let text): return text.trimmingCharacters(in: .whitespacesAndNewlines) } } }
}

/// Reads Anthropic's own real usage percentages straight from the Claude
/// desktop app's local cache — a plain JSON file the already-authenticated
/// app writes to disk itself roughly every 15 minutes. No login or network
/// call of our own: this is read-only access to a file our own user account
/// already owns, the same local-data approach ccusage itself uses.
private enum ClaudeDesktopUsageClient {
    static func currentSnapshot() -> PlanUsageSnapshot? {
        guard let url = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ).appendingPathComponent("Claude/plan-usage-history.json"),
        let data = try? Data(contentsOf: url),
        let samples = try? PlanUsageHistoryParser().parse(data) else { return nil }
        return PlanUsageAnalyzer.current(from: samples)
    }
}

/// Reads OpenAI's own real Codex usage percentages by asking the local
/// `codex` CLI's app-server for `account/rateLimits/read` over JSON-RPC —
/// the same figures the CLI's own status line uses. No login or network
/// call of our own: this shells out to the already-authenticated `codex`
/// binary, the same local-tool approach `CCUsageClient` uses for ccusage
/// itself. Spawning `codex app-server` costs real wall-clock time (it's a
/// persistent process we start, prod, and kill), so results are cached and
/// only re-probed every `refreshInterval`.
private final class CodexRateLimitClient: @unchecked Sendable {
    static let shared = CodexRateLimitClient()
    private let lock = NSLock()
    private var cached: DatedCodexSnapshot?
    /// Comfortably under `CodexProbePolicy`'s shortest interval, so a scheduled
    /// probe always runs for real instead of occasionally landing just inside
    /// the cache and doubling the effective staleness.
    private let refreshInterval: TimeInterval = 20

    func currentSnapshot(now: Date = Date(), forceRefresh: Bool = false) -> DatedCodexSnapshot? {
        lock.lock()
        if !forceRefresh, let cached, now.timeIntervalSince(cached.observedAt) < refreshInterval {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let fetched = Self.probe()
        lock.lock()
        defer { lock.unlock() }
        if let fetched {
            cached = DatedCodexSnapshot(snapshot: fetched, observedAt: now)
        }
        // On failure the previous reading is returned *with its original
        // timestamp*, never re-dated to now. That is the whole point: the
        // caller ages it, flags it as stale, and eventually drops it, instead
        // of a failed probe silently pinning a long-dead percentage on screen.
        return cached
    }

    /// Newer `codex` builds drop the `account/rateLimits/read` request
    /// on the floor if it (and `initialized`) arrive before the server has
    /// finished replying to `initialize` — sending all three requests in one
    /// blast (the previous approach) got silently ignored, which is why the
    /// menu bar stopped showing a Codex percentage at all. Waiting for the
    /// `"id":0` reply before writing the rest mirrors how a real client
    /// drives the handshake and reliably gets a response.
    private static func probe(timeout: TimeInterval = 5) -> CodexRateLimitSnapshot? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["codex", "app-server", "--listen", "stdio://"]
        process.environment = ToolEnvironment.current
        let stdin = Pipe(); let stdout = Pipe()
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = Pipe()
        process.qualityOfService = .utility
        guard (try? process.run()) != nil else { return nil }
        defer { if process.isRunning { process.terminate() } }

        let initializeRequest = #"{"method":"initialize","id":0,"params":{"clientInfo":{"name":"limitly","title":"Limitly","version":"1.0.0"}}}"#
        let followUpRequests = [
            #"{"method":"initialized","params":{}}"#,
            #"{"method":"account/rateLimits/read","id":2}"#
        ]
        stdin.fileHandleForWriting.write(Data((initializeRequest + "\n").utf8))

        let box = OutputBox()
        let semaphore = DispatchSemaphore(value: 0)
        let handle = stdout.fileHandleForReading
        let sentFollowUp = Locked(false)
        handle.readabilityHandler = { fh in
            let chunk = fh.availableData
            guard !chunk.isEmpty else { return }
            box.append(chunk)
            if box.text.contains("\"id\":0") && sentFollowUp.trySet() {
                stdin.fileHandleForWriting.write(Data(followUpRequests.map { $0 + "\n" }.joined().utf8))
            }
            if box.text.contains("\"id\":2") { semaphore.signal() }
        }
        _ = semaphore.wait(timeout: .now() + timeout)
        handle.readabilityHandler = nil
        return CodexRateLimitParser.parse(box.text)
    }

    /// Guards the "have we already sent the follow-up requests" flag against
    /// the readability handler firing again (with more buffered output)
    /// before the first follow-up write completes.
    private final class Locked: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Bool
        init(_ value: Bool) { self.value = value }
        /// Sets the flag and returns whether this call was the one that
        /// changed it from `false` to `true`.
        func trySet() -> Bool { lock.lock(); defer { lock.unlock() }; if value { return false }; value = true; return true }
    }

    private final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
        var text: String { lock.lock(); defer { lock.unlock() }; return String(data: data, encoding: .utf8) ?? "" }
    }
}
