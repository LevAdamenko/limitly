import Foundation
import SwiftUI
import UserNotifications
import LimitlyCore

@MainActor
final class UsageMonitor: ObservableObject {
    @Published private(set) var snapshot = UsageSnapshot(currentUsage: [:], weeklyUsage: [:])
    @Published private(set) var lastError: String?
    /// The moment `snapshot`'s windows were last interpreted. Republished on
    /// a short tick so countdowns advance and a window that has just passed
    /// its reset time drops to 0% on its own, without waiting for the next
    /// poll to land.
    @Published private(set) var resolvedAt = Date()
    @Published private(set) var isRefreshing = false
    let settings = SettingsStore()

    private var thresholdDetector = ThresholdDetector()
    private var weeklyDetector = WeeklyThresholdDetector()
    private var activityTracker = ActivityTracker()
    private var sessionActivityTracker = SessionActivityTracker()
    private let banner = BannerController()

    private var ccusageTimer: Timer?
    private var codexTimer: Timer?
    private var tickTimer: Timer?

    /// `refreshCCUsage` shells out to `npx ccusage` twice, each with a 20s
    /// timeout; guarding against overlap keeps a slow call from letting the
    /// timer pile up concurrent subprocesses that all contend for npm's
    /// shared package-install lock.
    private var isFetchingCCUsage = false
    /// Deliberately a *separate* guard from the one above. These two sources
    /// used to share one serialized path, so a single slow `npx` run starved
    /// the Codex probe for tens of seconds at a time — the main reason Codex's
    /// number went stale far more often than Claude's.
    private var isProbingCodex = false

    private var ccusagePortion = CCUsagePortion()
    private var codexWindows: AgentUsageWindows?

    init() {
        refresh()
        ccusageTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshCCUsage() }
        }
        codexTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshCodex() }
        }
        tickTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.rebuild() }
        }
    }
    deinit { ccusageTimer?.invalidate(); codexTimer?.invalidate(); tickTimer?.invalidate() }

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
        // Polled every 30 seconds; five minutes without a fresh reading means
        // the local app-server is failing, not merely idle.
        case .codexAppServer: return 5 * 60
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
        refreshCCUsage()
        refreshCodex(force: force)
    }

    private func refreshCCUsage() {
        guard !isFetchingCCUsage else { return }
        isFetchingCCUsage = true
        updateBusyFlag()
        let idleNotificationsEnabled = settings.idleNotificationsEnabled
        Task.detached { [weak self] in
            let result = Result { try CCUsageClient.fetch() }
            // Skip the AppleScript round-trip entirely when idle
            // notifications are off — no point paying for it on every
            // 5-second refresh if nothing will use it.
            let terminals = idleNotificationsEnabled ? GhosttyController.openTerminals() : []
            await self?.applyCCUsage(result, terminals: terminals)
        }
    }

    /// `force` bypasses the probe's short cache — the automatic timer never
    /// sets it (that cache is what keeps polling cheap), but the manual
    /// Refresh button does, since silently returning the same cached Codex
    /// numbers made the button look like it wasn't doing anything.
    private func refreshCodex(force: Bool = false) {
        guard !isProbingCodex else { return }
        isProbingCodex = true
        updateBusyFlag()
        Task.detached { [weak self] in
            let dated = CodexRateLimitClient.shared.currentSnapshot(forceRefresh: force)
            await self?.applyCodex(dated)
        }
    }

    private func applyCCUsage(_ result: Result<CCUsagePortion, Error>, terminals: [GhosttyTerminal]) {
        isFetchingCCUsage = false
        updateBusyFlag()
        switch result {
        case .success(let portion):
            ccusagePortion = portion
            lastError = nil
        case .failure(let error):
            // Don't blank out what the independent real-percentage sources
            // already gave us — a ccusage failure only costs the
            // budget-estimate fallback and the token/dollar totals.
            lastError = "ccusage refresh failed: \(error.localizedDescription)"
        }
        rebuild()
        evaluateIdle(terminals: terminals)
    }

    private func applyCodex(_ dated: DatedCodexSnapshot?) {
        isProbingCodex = false
        updateBusyFlag()
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
    /// republishes. Cheap and side-effect-free apart from threshold alerts,
    /// which is why the display tick can call it every few seconds.
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

        snapshot = UsageSnapshot(
            currentUsage: ccusagePortion.currentUsage,
            weeklyUsage: ccusagePortion.weeklyUsage,
            resetTimes: resets,
            realCurrentPercentages: realCurrent,
            realWeeklyPercentages: realWeekly,
            windows: windows
        )
        resolvedAt = now
        evaluateThresholds()
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
        let fallbackUsages = snapshot.currentUsage.filter { !sessionObservation.matchedAgents.contains($0.key) }
        let idleEvents = activityTracker.observe(usages: fallbackUsages, at: now, idleInterval: settings.idleSeconds)
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

/// Everything one `ccusage` pass produces: the locally-measured token/dollar
/// totals that back the budget estimate, plus whatever Claude windows the
/// local sources could supply.
private struct CCUsagePortion: Sendable {
    var currentUsage: [AgentID: UsageTotals] = [:]
    var weeklyUsage: [AgentID: UsageTotals] = [:]
    var claude: AgentUsageWindows?
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

    static func fetch(now: Date = Date()) throws -> CCUsagePortion {
        let calendar = Calendar.current
        let since = calendar.date(byAdding: .day, value: -6, to: now) ?? now
        let formatter = DateFormatter(); formatter.calendar = calendar; formatter.dateFormat = "yyyy-MM-dd"
        let parser = CCUsageParser()

        var ccusageError: Error?
        var rows: [AgentID: [DatedUsage]] = [:]
        do {
            let dailyData = try run(["--yes", ccusagePackage, "daily", "--json", "--by-agent", "--since", formatter.string(from: since), "--offline"])
            rows = try parser.parseDailyRows(dailyData)
        } catch {
            ccusageError = error
        }
        var blocksFetchSucceeded = false
        var blocks: [SessionBlock] = []
        if let blocksData = try? run(["--yes", ccusagePackage, "blocks", "--json", "--active", "--offline"]),
           let parsedBlocks = try? parser.parseBlocks(blocksData) {
            blocksFetchSucceeded = true
            blocks = parsedBlocks
        }
        let activeBlock = blocks.first(where: \.isActive)
        var currentUsage = parser.usages(on: now, rows: rows, calendar: calendar)
        if let activeBlock {
            currentUsage[.claude] = activeBlock.usage
        } else if blocksFetchSucceeded {
            // Genuinely no active session, as opposed to the `blocks`
            // subprocess call itself failing (network hiccup, non-zero
            // exit, bad JSON) — in that failure case, overwriting with a
            // hard zero would visibly contradict a real non-zero percent
            // shown from the independent real sources.
            currentUsage[.claude] = UsageTotals(totalTokens: 0, totalCost: 0)
        }

        let claudeWindows = ClaudeWindowResolver.windows(
            statusLine: ClaudeStatusLineUsageFile.currentSnapshot(),
            desktop: ClaudeDesktopUsageClient.currentSnapshot(),
            ccusageBlockEnd: activeBlock?.endTime,
            now: now
        )

        // Only surface the ccusage failure if there is no real percentage to
        // fall back on anyway — otherwise this would still be a useful,
        // working refresh.
        if let ccusageError, claudeWindows == nil {
            throw ccusageError
        }

        return CCUsagePortion(
            currentUsage: currentUsage,
            weeklyUsage: parser.aggregate(rows),
            claude: claudeWindows
        )
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
        var environment = ProcessInfo.processInfo.environment; environment["npm_config_cache"] = FileManager.default.temporaryDirectory.appendingPathComponent("limitly-npm-cache", isDirectory: true).path; environment["NO_COLOR"] = "1"; process.environment = environment
        let output = Pipe(); let errors = Pipe(); process.standardOutput = output; process.standardError = errors
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
    /// Comfortably under the caller's 30-second poll, so a scheduled poll
    /// always produces a real probe instead of occasionally landing just
    /// inside the cache and doubling the effective staleness.
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
        let stdin = Pipe(); let stdout = Pipe()
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = Pipe()
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
