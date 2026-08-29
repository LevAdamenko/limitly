import SwiftUI
import LimitlyCore

enum AlertDelivery: String, Codable, CaseIterable { case banner, notification }

struct AgentSettings: Codable {
    var budgetUnit: BudgetUnit
    var budgetAmount: Double
    var weeklyBudgetAmount: Double
    var thresholds: String
    var weeklyThreshold: Double

    init(budgetUnit: BudgetUnit = .dollars, budgetAmount: Double = 20, weeklyBudgetAmount: Double = 140, thresholds: String = "50, 80, 100", weeklyThreshold: Double = 80) {
        self.budgetUnit = budgetUnit
        self.budgetAmount = budgetAmount
        self.weeklyBudgetAmount = weeklyBudgetAmount
        self.thresholds = thresholds
        self.weeklyThreshold = weeklyThreshold
    }

    private enum CodingKeys: String, CodingKey { case budgetUnit, budgetAmount, weeklyBudgetAmount, thresholds, weeklyThreshold }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        budgetUnit = try values.decodeIfPresent(BudgetUnit.self, forKey: .budgetUnit) ?? .dollars
        budgetAmount = try values.decodeIfPresent(Double.self, forKey: .budgetAmount) ?? 20
        // Keep existing installations valid while giving their old $20 default a $140 weekly counterpart.
        weeklyBudgetAmount = try values.decodeIfPresent(Double.self, forKey: .weeklyBudgetAmount) ?? 140
        thresholds = try values.decodeIfPresent(String.self, forKey: .thresholds) ?? "50, 80, 100"
        weeklyThreshold = try values.decodeIfPresent(Double.self, forKey: .weeklyThreshold) ?? 80
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    @Published var claude = AgentSettings()
    @Published var codex = AgentSettings()
    @Published var delivery: AlertDelivery = .banner
    @Published var idleSeconds: Double = 60
    private let key = "Limitly.Settings.v1"

    init() { load() }
    func config(for agent: AgentID) -> AgentSettings { agent == .claude ? claude : codex }
    func budget(for agent: AgentID) -> UsageBudget { let c = config(for: agent); return UsageBudget(unit: c.budgetUnit, amount: c.budgetAmount) }
    func weeklyBudget(for agent: AgentID) -> UsageBudget { let c = config(for: agent); return UsageBudget(unit: c.budgetUnit, amount: c.weeklyBudgetAmount) }
    func thresholds(for agent: AgentID) -> [Double] { config(for: agent).thresholds.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) } }
    func save() { let value = Persisted(claude: claude, codex: codex, delivery: delivery, idleSeconds: idleSeconds); if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) } }
    private func load() { guard let data = UserDefaults.standard.data(forKey: key), let value = try? JSONDecoder().decode(Persisted.self, from: data) else { return }; claude = value.claude; codex = value.codex; delivery = value.delivery; idleSeconds = value.idleSeconds }
    private struct Persisted: Codable { var claude: AgentSettings; var codex: AgentSettings; var delivery: AlertDelivery; var idleSeconds: Double }
}

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    var body: some View {
        Form {
            Section("Alerts") {
                Picker("Deliver alerts as", selection: $settings.delivery) { Text("Top banner").tag(AlertDelivery.banner); Text("macOS notification").tag(AlertDelivery.notification) }
                TextField("Idle after seconds", value: $settings.idleSeconds, format: .number).onChange(of: settings.idleSeconds) { _, _ in settings.save() }
            }
            agentSection("Claude", binding: $settings.claude)
            agentSection("Codex", binding: $settings.codex)
            Text("Claude’s current percentage is its active ~5-hour session block; Codex’s is today because ccusage does not expose Codex session blocks. Dollars are the default because cached tokens can inflate raw token counts unpredictably; weekly alerts use the trailing seven days.").font(.caption).foregroundStyle(.secondary)
        }
        .padding().frame(width: 470).navigationTitle("Limitly Settings")
    }
    @ViewBuilder private func agentSection(_ name: String, binding: Binding<AgentSettings>) -> some View {
        Section(name) {
            Picker("Budget unit", selection: binding.budgetUnit) { ForEach(BudgetUnit.allCases, id: \.self) { Text($0.displayName).tag($0) } }.onChange(of: binding.budgetUnit.wrappedValue) { _, _ in settings.save() }
            TextField("Usage budget", value: binding.budgetAmount, format: .number).onChange(of: binding.budgetAmount.wrappedValue) { _, _ in settings.save() }
            TextField("Usage thresholds (%)", text: binding.thresholds).onChange(of: binding.thresholds.wrappedValue) { _, _ in settings.save() }
            TextField("Weekly budget", value: binding.weeklyBudgetAmount, format: .number).onChange(of: binding.weeklyBudgetAmount.wrappedValue) { _, _ in settings.save() }
            TextField("Weekly threshold (%)", value: binding.weeklyThreshold, format: .number).onChange(of: binding.weeklyThreshold.wrappedValue) { _, _ in settings.save() }
        }
    }
}
