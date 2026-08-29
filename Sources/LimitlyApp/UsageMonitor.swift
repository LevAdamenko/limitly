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
    private var timer: Timer?
    private let banner = BannerController()

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
    func percentageText(for agent: AgentID) -> String { guard let value = realPercentage(for: agent) else { return "—" }; return "\(Int(value.rounded()))%" }
    func weeklyText(for agent: AgentID) -> String { guard let usage = snapshot.weeklyUsage[agent] else { return "No data" }; let real = snapshot.realWeeklyPercentages[agent]; let pct = (real ?? settings.weeklyBudget(for: agent).percentage(for: usage)).map { " (\(Int($0.rounded()))%)" } ?? ""; return format(usage, unit: settings.budget(for: agent).unit) + pct }
    private func realPercentage(for agent: AgentID) -> Double? {
        if let real = snapshot.realCurrentPercentages[agent] { return real }
        guard let usage = snapshot.currentUsage[agent] else { return nil }
        return settings.budget(for: agent).percentage(for: usage)
    }
    func usageText(for agent: AgentID) -> String { guard let usage = snapshot.currentUsage[agent] else { return agent == .claude ? "No usage in current session" : "No usage today" }; let label = agent == .claude ? "Current session" : "Today"; return "\(label): \(format(usage, unit: settings.budget(for: agent).unit))" }
    func resetText(for agent: AgentID) -> String? { guard let reset = snapshot.resetTimes[agent] else { return nil }; let interval = max(0, reset.timeIntervalSinceNow); let text = Self.durationFormatter.string(from: interval) ?? "soon"; return "Session resets in \(text)" }
    private static let durationFormatter: DateComponentsFormatter = { let f = DateComponentsFormatter(); f.allowedUnits = [.hour, .minute]; f.unitsStyle = .abbreviated; f.zeroFormattingBehavior = .dropAll; return f }()

    func refresh() {
        Task.detached { [weak self] in
            do {
                let result = try CCUsageClient.fetch()
                await self?.apply(result)
            } catch { await self?.record(error) }
        }
    }

    private func apply(_ result: UsageSnapshot) {
        snapshot = result; lastError = nil
        let dailyPercentages = percentages(result)
        let weeklyPercentages = weeklyPercentages(result)
        let thresholdEvents = thresholdDetector.observe(percentages: dailyPercentages, thresholds: Dictionary(uniqueKeysWithValues: AgentID.allCases.map { ($0, settings.thresholds(for: $0)) }))
        let weeklyEvents = weeklyDetector.observe(percentages: weeklyPercentages, thresholds: Dictionary(uniqueKeysWithValues: AgentID.allCases.map { ($0, settings.config(for: $0).weeklyThreshold) }))
        let idleEvents = activityTracker.observe(usages: result.currentUsage, at: Date(), idleInterval: settings.idleSeconds)
        for event in thresholdEvents { deliver(title: "\(event.agent.displayName) usage alert", body: "Current usage reached \(Int(event.threshold))% (\(Int(event.percentage.rounded()))%).") }
        for event in weeklyEvents { deliver(title: "\(event.agent.displayName) weekly usage alert", body: "Trailing 7-day usage reached \(Int(event.threshold))% (\(Int(event.percentage.rounded()))%).") }
        for event in idleEvents { deliver(title: "\(event.agent.displayName) is idle", body: "No new usage has appeared for \(Int(settings.idleSeconds)) seconds.") }
    }
    private func record(_ error: Error) { lastError = "ccusage refresh failed: \(error.localizedDescription)" }
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
    private func deliver(title: String, body: String) { if settings.delivery == .banner { banner.show(title: title, body: body) } else { UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }; let content = UNMutableNotificationContent(); content.title = title; content.body = body; let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil); UNUserNotificationCenter.current().add(request) } }
}

private enum CCUsageClient {
    static func fetch(now: Date = Date()) throws -> UsageSnapshot {
        let calendar = Calendar.current
        let since = calendar.date(byAdding: .day, value: -6, to: now) ?? now
        let formatter = DateFormatter(); formatter.calendar = calendar; formatter.dateFormat = "yyyy-MM-dd"
        let dailyData = try run(["--yes", "ccusage@latest", "daily", "--json", "--by-agent", "--since", formatter.string(from: since), "--offline"])
        let parser = CCUsageParser(); let rows = try parser.parseDailyRows(dailyData)
        let blocks = (try? run(["--yes", "ccusage@latest", "blocks", "--json", "--active", "--offline"]))
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

        return UsageSnapshot(
            currentUsage: currentUsage,
            weeklyUsage: parser.aggregate(rows),
            resetTimes: resetTimes,
            realCurrentPercentages: realCurrentPercentages,
            realWeeklyPercentages: realWeeklyPercentages
        )
    }
    private static func run(_ arguments: [String]) throws -> Data {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/env"); process.arguments = ["npx"] + arguments
        var environment = ProcessInfo.processInfo.environment; environment["npm_config_cache"] = FileManager.default.temporaryDirectory.appendingPathComponent("limitly-npm-cache", isDirectory: true).path; environment["NO_COLOR"] = "1"; process.environment = environment
        let output = Pipe(); let errors = Pipe(); process.standardOutput = output; process.standardError = errors; try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ClientError.failed(String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "unknown error") }
        return output.fileHandleForReading.readDataToEndOfFile()
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
