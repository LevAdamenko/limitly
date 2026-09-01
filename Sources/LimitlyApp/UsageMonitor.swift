import Foundation
import SwiftUI
import UserNotifications
import LimitlyCore

@MainActor
final class UsageMonitor: ObservableObject {
    @Published private(set) var snapshot = UsageSnapshot(currentUsage: [:], weeklyUsage: [:])
    @Published private(set) var lastError: String?
    let settings = SettingsStore()
    private var thresholdDetector = ThresholdDetector()
    private var weeklyDetector = WeeklyThresholdDetector()
    private var activityTracker = ActivityTracker()
    private var sessionActivityTracker = SessionActivityTracker()
    private var timer: Timer?
    private let banner = BannerController()
    /// `refresh()` shells out to `npx ccusage` (and, for Codex, spawns
    /// `codex app-server`); guarding against overlap keeps a single slow
    /// call from letting the 5-second timer pile up concurrent subprocesses
    /// that all contend for npm's shared package-install lock.
    private var isRefreshing = false

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }
    deinit { timer?.invalidate() }

    var menuBarTitle: String { "Claude \(percentageText(for: .claude)) · Codex \(percentageText(for: .codex))" }
    /// Prefers Anthropic's own real percentage (from the Claude desktop
    /// app's local cache) over the budget-derived estimate when available —
    /// see `realPercentage(for:)`.
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
    func resetText(for agent: AgentID) -> String? { guard let reset = snapshot.resetTimes[agent] else { return nil }; let interval = max(0, reset.timeIntervalSinceNow); let text = Self.durationFormatter.string(from: interval) ?? "soon"; return "Session resets in \(text)" }
    private static let durationFormatter: DateComponentsFormatter = { let f = DateComponentsFormatter(); f.allowedUnits = [.hour, .minute]; f.unitsStyle = .abbreviated; f.zeroFormattingBehavior = .dropAll; return f }()

    /// Fires a real alert through the same delivery path as a genuine
    /// threshold/idle event, so the user can check banner placement, sound,
    /// and (if switched to `.notification`) the native alert without
    /// waiting for real usage to cross a threshold.
    func sendTestAlert() { deliver(title: "Limitly test alert", body: "This is what a usage alert looks like.") }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        let idleNotificationsEnabled = settings.idleNotificationsEnabled
        Task.detached { [weak self] in
            do {
                let result = try CCUsageClient.fetch()
                // Skip the AppleScript round-trip entirely when idle
                // notifications are off — no point paying for it on every
                // 5-second refresh if nothing will use it.
                let terminals = idleNotificationsEnabled ? GhosttyController.openTerminals() : []
                await self?.apply(result, terminals: terminals)
            } catch { await self?.record(error) }
        }
    }

    private func apply(_ result: UsageSnapshot, terminals: [GhosttyTerminal]) {
        isRefreshing = false
        snapshot = result; lastError = nil
        let now = Date()
        let dailyPercentages = percentages(result)
        let weeklyPercentages = weeklyPercentages(result)
        let thresholdEvents = thresholdDetector.observe(percentages: dailyPercentages, thresholds: Dictionary(uniqueKeysWithValues: AgentID.allCases.map { ($0, settings.thresholds(for: $0)) }))
        let weeklyEvents = weeklyDetector.observe(percentages: weeklyPercentages, thresholds: Dictionary(uniqueKeysWithValues: AgentID.allCases.map { ($0, settings.config(for: $0).weeklyThreshold) }))
        for event in thresholdEvents { deliver(title: "\(event.agent.displayName) usage alert", body: "Current usage reached \(Int(event.threshold))% (\(Int(event.percentage.rounded()))%).") }
        for event in weeklyEvents { deliver(title: "\(event.agent.displayName) weekly usage alert", body: "Trailing 7-day usage reached \(Int(event.threshold))% (\(Int(event.percentage.rounded()))%).") }
        if settings.idleNotificationsEnabled {
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
            let fallbackUsages = result.currentUsage.filter { !sessionObservation.matchedAgents.contains($0.key) }
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
    }
    private func record(_ error: Error) { isRefreshing = false; lastError = "ccusage refresh failed: \(error.localizedDescription)" }
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

    static func fetch(now: Date = Date()) throws -> UsageSnapshot {
        let calendar = Calendar.current
        let since = calendar.date(byAdding: .day, value: -6, to: now) ?? now
        let formatter = DateFormatter(); formatter.calendar = calendar; formatter.dateFormat = "yyyy-MM-dd"
        let parser = CCUsageParser()

        // ccusage only backs the budget-estimate fallback (see the
        // Settings footnote) — the "real" percentage clients below are
        // independent of it. A ccusage failure shouldn't blank out
        // percentages that already came from those real sources, so it's
        // captured rather than thrown immediately.
        var ccusageError: Error?
        var rows: [AgentID: [DatedUsage]] = [:]
        do {
            let dailyData = try run(["--yes", ccusagePackage, "daily", "--json", "--by-agent", "--since", formatter.string(from: since), "--offline"])
            rows = try parser.parseDailyRows(dailyData)
        } catch {
            ccusageError = error
        }
        let blocks = (try? run(["--yes", ccusagePackage, "blocks", "--json", "--active", "--offline"]))
            .flatMap { try? parser.parseBlocks($0) } ?? []
        let activeBlock = blocks.first(where: \.isActive)
        var currentUsage = parser.usages(on: now, rows: rows, calendar: calendar)
        currentUsage[.claude] = activeBlock?.usage ?? UsageTotals(totalTokens: 0, totalCost: 0)
        var resetTimes: [AgentID: Date] = [:]
        if let reset = activeBlock?.endTime { resetTimes[.claude] = reset }

        var realCurrentPercentages: [AgentID: Double] = [:]
        var realWeeklyPercentages: [AgentID: Double] = [:]
        if let real = ClaudeDesktopUsageClient.currentSnapshot() {
            realCurrentPercentages[.claude] = real.fiveHourPercent
            realWeeklyPercentages[.claude] = real.sevenDayPercent
            resetTimes[.claude] = real.sessionResetTime
        }
        if let real = CodexRateLimitClient.shared.currentSnapshot() {
            realCurrentPercentages[.codex] = real.fiveHourPercent
            realWeeklyPercentages[.codex] = real.weeklyPercent
            if let reset = real.sessionResetTime { resetTimes[.codex] = reset }
        }

        // Only surface the ccusage failure if neither agent has a real
        // percentage to show anyway — otherwise this would still be a
        // useful, working refresh.
        if let ccusageError, realCurrentPercentages[.claude] == nil, realCurrentPercentages[.codex] == nil {
            throw ccusageError
        }

        return UsageSnapshot(
            currentUsage: currentUsage,
            weeklyUsage: parser.aggregate(rows),
            resetTimes: resetTimes,
            realCurrentPercentages: realCurrentPercentages,
            realWeeklyPercentages: realWeeklyPercentages
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
            if process.isRunning { process.terminate() }
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
    private var cached: CodexRateLimitSnapshot?
    private var lastFetch: Date?
    private let refreshInterval: TimeInterval = 90

    func currentSnapshot(now: Date = Date()) -> CodexRateLimitSnapshot? {
        lock.lock()
        if let cached, let lastFetch, now.timeIntervalSince(lastFetch) < refreshInterval {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let fetched = Self.probe()
        lock.lock()
        defer { lock.unlock() }
        if let fetched { cached = fetched; lastFetch = now }
        return fetched ?? cached
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
