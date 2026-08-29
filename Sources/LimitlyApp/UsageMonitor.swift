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
    func percentageText(for agent: AgentID) -> String { guard let usage = snapshot.currentUsage[agent], let value = settings.budget(for: agent).percentage(for: usage) else { return "—" }; return "\(Int(value.rounded()))%" }
    func weeklyText(for agent: AgentID) -> String { guard let usage = snapshot.weeklyUsage[agent] else { return "No data" }; let pct = settings.budget(for: agent).percentage(for: usage).map { " (\(Int($0.rounded()))%)" } ?? ""; return format(usage, unit: settings.budget(for: agent).unit) + pct }
    func usageText(for agent: AgentID) -> String { guard let usage = snapshot.currentUsage[agent] else { return "No usage today" }; return "Today: \(format(usage, unit: settings.budget(for: agent).unit))" }
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
        let dailyPercentages = percentages(result.currentUsage)
        let weeklyPercentages = percentages(result.weeklyUsage)
        let thresholdEvents = thresholdDetector.observe(percentages: dailyPercentages, thresholds: Dictionary(uniqueKeysWithValues: AgentID.allCases.map { ($0, settings.thresholds(for: $0)) }))
        let weeklyEvents = weeklyDetector.observe(percentages: weeklyPercentages, thresholds: Dictionary(uniqueKeysWithValues: AgentID.allCases.map { ($0, settings.config(for: $0).weeklyThreshold) }))
        let idleEvents = activityTracker.observe(usages: result.currentUsage, at: Date(), idleInterval: settings.idleSeconds)
        for event in thresholdEvents { deliver(title: "\(event.agent.displayName) usage alert", body: "Current-day usage reached \(Int(event.threshold))% (\(Int(event.percentage.rounded()))%).") }
        for event in weeklyEvents { deliver(title: "\(event.agent.displayName) weekly usage alert", body: "Trailing 7-day usage reached \(Int(event.threshold))% (\(Int(event.percentage.rounded()))%).") }
        for event in idleEvents { deliver(title: "\(event.agent.displayName) is idle", body: "No new usage has appeared for \(Int(settings.idleSeconds)) seconds.") }
    }
    private func record(_ error: Error) { lastError = "ccusage refresh failed: \(error.localizedDescription)" }
    private func percentages(_ usage: [AgentID: UsageTotals]) -> [AgentID: Double] { Dictionary(uniqueKeysWithValues: usage.compactMap { agent, totals in settings.budget(for: agent).percentage(for: totals).map { (agent, $0) } }) }
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
        var resetTimes: [AgentID: Date] = [:]
        if let blockData = try? run(["--yes", "ccusage@latest", "blocks", "--json", "--active", "--offline"]), let reset = try? SessionBlockCalculator.resetTime(for: parser.parseBlocks(blockData)) { resetTimes[.claude] = reset }
        return UsageSnapshot(currentUsage: parser.usages(on: now, rows: rows, calendar: calendar), weeklyUsage: parser.aggregate(rows), resetTimes: resetTimes)
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
