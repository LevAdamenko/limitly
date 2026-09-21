import SwiftUI
import LimitlyCore

enum AlertDelivery: String, Codable, CaseIterable { case banner, notification }

enum PercentageDisplayMode: String, Codable, CaseIterable {
    case used, remaining
    var displayName: String { self == .used ? "Used" : "Remaining" }
}

/// How a window's reset is written out. "Resets in 4h 8m" is useless for
/// planning a day around the limit — the clock time is what the user compares
/// against a meeting or a bedtime — so the default shows both.
enum ResetDisplayMode: String, Codable, CaseIterable {
    case both, absolute, relative
    var displayName: String {
        switch self {
        case .both: "Clock time and countdown"
        case .absolute: "Clock time"
        case .relative: "Countdown"
        }
    }
}

enum IconColorMode: String, Codable, CaseIterable {
    case automatic, black, white
    var displayName: String {
        switch self {
        case .automatic: "Automatic"
        case .black: "Black"
        case .white: "White"
        }
    }
}

struct AgentSettings: Codable {
    var budgetUnit: BudgetUnit
    var budgetAmount: Double
    var weeklyBudgetAmount: Double
    var thresholds: String
    var weeklyThreshold: Double
    var thresholdNotificationsEnabled: Bool

    init(budgetUnit: BudgetUnit = .dollars, budgetAmount: Double = 20, weeklyBudgetAmount: Double = 140, thresholds: String = "50, 80, 100", weeklyThreshold: Double = 80, thresholdNotificationsEnabled: Bool = true) {
        self.budgetUnit = budgetUnit
        self.budgetAmount = budgetAmount
        self.weeklyBudgetAmount = weeklyBudgetAmount
        self.thresholds = thresholds
        self.weeklyThreshold = weeklyThreshold
        self.thresholdNotificationsEnabled = thresholdNotificationsEnabled
    }

    private enum CodingKeys: String, CodingKey { case budgetUnit, budgetAmount, weeklyBudgetAmount, thresholds, weeklyThreshold, thresholdNotificationsEnabled }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        budgetUnit = try values.decodeIfPresent(BudgetUnit.self, forKey: .budgetUnit) ?? .dollars
        budgetAmount = try values.decodeIfPresent(Double.self, forKey: .budgetAmount) ?? 20
        // Keep existing installations valid while giving their old $20 default a $140 weekly counterpart.
        weeklyBudgetAmount = try values.decodeIfPresent(Double.self, forKey: .weeklyBudgetAmount) ?? 140
        thresholds = try values.decodeIfPresent(String.self, forKey: .thresholds) ?? "50, 80, 100"
        weeklyThreshold = try values.decodeIfPresent(Double.self, forKey: .weeklyThreshold) ?? 80
        thresholdNotificationsEnabled = try values.decodeIfPresent(Bool.self, forKey: .thresholdNotificationsEnabled) ?? true
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    @Published var claude = AgentSettings()
    @Published var codex = AgentSettings()
    @Published var delivery: AlertDelivery = .banner
    @Published var idleSeconds: Double = 60
    @Published var idleNotificationsEnabled: Bool = true
    @Published var percentageDisplay: PercentageDisplayMode = .used
    @Published var iconColor: IconColorMode = .automatic
    @Published var resetDisplay: ResetDisplayMode = .both
    private let key = "Limitly.Settings.v1"

    init() { load() }
    func config(for agent: AgentID) -> AgentSettings { agent == .claude ? claude : codex }
    func budget(for agent: AgentID) -> UsageBudget { let c = config(for: agent); return UsageBudget(unit: c.budgetUnit, amount: c.budgetAmount) }
    func weeklyBudget(for agent: AgentID) -> UsageBudget { let c = config(for: agent); return UsageBudget(unit: c.budgetUnit, amount: c.weeklyBudgetAmount) }
    func thresholds(for agent: AgentID) -> [Double] { config(for: agent).thresholds.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) } }
    func displayed(_ percentage: Double) -> Double { percentageDisplay == .used ? percentage : max(0, 100 - percentage) }
    func save() { let value = Persisted(claude: claude, codex: codex, delivery: delivery, idleSeconds: idleSeconds, idleNotificationsEnabled: idleNotificationsEnabled, percentageDisplay: percentageDisplay, iconColor: iconColor, resetDisplay: resetDisplay); if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) } }
    private func load() { guard let data = UserDefaults.standard.data(forKey: key), let value = try? JSONDecoder().decode(Persisted.self, from: data) else { return }; claude = value.claude; codex = value.codex; delivery = value.delivery; idleSeconds = value.idleSeconds; idleNotificationsEnabled = value.idleNotificationsEnabled ?? true; percentageDisplay = value.percentageDisplay ?? .used; iconColor = value.iconColor ?? .automatic; resetDisplay = value.resetDisplay ?? .both }
    private struct Persisted: Codable { var claude: AgentSettings; var codex: AgentSettings; var delivery: AlertDelivery; var idleSeconds: Double; var idleNotificationsEnabled: Bool?; var percentageDisplay: PercentageDisplayMode?; var iconColor: IconColorMode?; var resetDisplay: ResetDisplayMode? }
}

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    let sendTestAlert: () -> Void
    @State private var statusLineState: ClaudeStatusLineInstaller.State = .notInstalled
    @State private var statusLineError: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                settingsCard(title: "Display", symbol: "slider.horizontal.3") {
                    settingRow("Show percentage as") {
                        Picker("Show percentage as", selection: $settings.percentageDisplay) {
                            ForEach(PercentageDisplayMode.allCases, id: \.self) {
                                Text($0.displayName).tag($0)
                            }
                        }
                        .labelsHidden()
                        .onChange(of: settings.percentageDisplay) { _, _ in settings.save() }
                    }

                    rowDivider

                    settingRow("Show reset time as") {
                        Picker("Show reset time as", selection: $settings.resetDisplay) {
                            ForEach(ResetDisplayMode.allCases, id: \.self) {
                                Text($0.displayName).tag($0)
                            }
                        }
                        .labelsHidden()
                        .onChange(of: settings.resetDisplay) { _, _ in settings.save() }
                    }

                    rowDivider

                    settingRow("Icon color") {
                        Picker("Icon color", selection: $settings.iconColor) {
                            ForEach(IconColorMode.allCases, id: \.self) {
                                Text($0.displayName).tag($0)
                            }
                        }
                        .labelsHidden()
                        .onChange(of: settings.iconColor) { _, _ in settings.save() }
                    }
                }

                settingsCard(title: "Alerts", symbol: "bell.badge") {
                    settingRow("Deliver alerts as") {
                        Picker("Deliver alerts as", selection: $settings.delivery) {
                            Text("Top banner").tag(AlertDelivery.banner)
                            Text("macOS notification").tag(AlertDelivery.notification)
                        }
                        .labelsHidden()
                        .onChange(of: settings.delivery) { _, _ in settings.save() }
                    }

                    rowDivider

                    settingRow("Notify when idle") {
                        Toggle("Notify when idle", isOn: $settings.idleNotificationsEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .onChange(of: settings.idleNotificationsEnabled) { _, _ in settings.save() }
                    }

                    rowDivider

                    settingRow("Idle after seconds") {
                        TextField("Idle after seconds", value: $settings.idleSeconds, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .disabled(!settings.idleNotificationsEnabled)
                            .onChange(of: settings.idleSeconds) { _, _ in settings.save() }
                    }

                    rowDivider

                    settingRow("") {
                        Button("Send test alert", action: sendTestAlert)
                            .buttonStyle(.borderedProminent)
                    }
                }

                settingsCard(title: "Claude data source", symbol: "antenna.radiowaves.left.and.right") {
                    settingRow("Claude Code status line") {
                        HStack(spacing: 8) {
                            Text(statusLineStatusText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(statusLineIsInstalled ? "Disconnect" : "Connect") {
                                toggleStatusLine()
                            }
                        }
                    }

                    if let statusLineError {
                        Label(statusLineError, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text("Connecting adds a small script to Claude Code\u{2019}s status line. It is the only place on this Mac that reports Anthropic\u{2019}s own five-hour and seven-day percentages together with their real reset times, so Limitly can show exactly when the limit comes back instead of estimating. Any status line you already use keeps working \u{2014} it is chained, not replaced, and your settings.json is backed up first.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                agentSection("Claude", symbol: "sparkles", binding: $settings.claude)
                agentSection("Codex", symbol: "terminal", binding: $settings.codex)

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                    Text("Both percentages are the providers\u{2019} own real usage figures, not an estimate \u{2014} Codex\u{2019}s read live from the \u{2018}codex\u{2019} CLI\u{2019}s account status, Claude\u{2019}s from its status line when connected above, otherwise from the Claude desktop app\u{2019}s local cache. The budget fields below are only a fallback for when no real figure is available. Weekly alerts use the trailing seven days; \u{201C}Remaining\u{201D} inverts both the current and weekly percentage.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.65))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 1)
                }
            }
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(width: 500, height: 700)
        .navigationTitle("Limitly Settings")
        .onAppear { statusLineState = ClaudeStatusLineInstaller.state() }
    }

    private var statusLineIsInstalled: Bool {
        switch statusLineState {
        case .installed, .installedAlongside: return true
        case .notInstalled, .claudeSettingsUnreadable: return false
        }
    }

    private var statusLineStatusText: String {
        switch statusLineState {
        case .installed: return "Connected"
        case .installedAlongside(let existing): return "Connected, chained to \(existing)"
        case .notInstalled: return "Not connected"
        case .claudeSettingsUnreadable(let reason): return reason
        }
    }

    private func toggleStatusLine() {
        statusLineError = nil
        do {
            if statusLineIsInstalled {
                try ClaudeStatusLineInstaller.uninstall()
            } else {
                try ClaudeStatusLineInstaller.install()
            }
        } catch {
            statusLineError = error.localizedDescription
        }
        statusLineState = ClaudeStatusLineInstaller.state()
    }

    @ViewBuilder
    private func agentSection(_ name: String, symbol: String, binding: Binding<AgentSettings>) -> some View {
        settingsCard(title: name, symbol: symbol) {
            settingRow("Budget unit") {
                Picker("Budget unit", selection: binding.budgetUnit) {
                    ForEach(BudgetUnit.allCases, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                .labelsHidden()
                .onChange(of: binding.budgetUnit.wrappedValue) { _, _ in settings.save() }
            }

            rowDivider

            settingRow("Usage budget") {
                TextField("Usage budget", value: binding.budgetAmount, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: binding.budgetAmount.wrappedValue) { _, _ in settings.save() }
            }

            rowDivider

            settingRow("Notify at thresholds") {
                Toggle("Notify at thresholds", isOn: binding.thresholdNotificationsEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .onChange(of: binding.thresholdNotificationsEnabled.wrappedValue) { _, _ in settings.save() }
            }

            rowDivider

            settingRow("Usage thresholds (%)") {
                TextField("Usage thresholds (%)", text: binding.thresholds)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!binding.thresholdNotificationsEnabled.wrappedValue)
                    .onChange(of: binding.thresholds.wrappedValue) { _, _ in settings.save() }
            }

            rowDivider

            settingRow("Weekly budget") {
                TextField("Weekly budget", value: binding.weeklyBudgetAmount, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: binding.weeklyBudgetAmount.wrappedValue) { _, _ in settings.save() }
            }

            rowDivider

            settingRow("Weekly threshold (%)") {
                TextField("Weekly threshold (%)", value: binding.weeklyThreshold, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!binding.thresholdNotificationsEnabled.wrappedValue)
                    .onChange(of: binding.weeklyThreshold.wrappedValue) { _, _ in settings.save() }
            }
        }
    }

    private func settingsCard<Content: View>(
        title: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(Color.accentColor.opacity(0.13))
                    )

                Text(title)
                    .font(.headline)
                    .fontWeight(.semibold)
            }

            Divider()

            VStack(spacing: 11) {
                content()
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
        }
        .shadow(color: Color.primary.opacity(0.05), radius: 4, y: 1)
    }

    private func settingRow<Control: View>(
        _ label: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: 16) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 165, alignment: .leading)

            Spacer(minLength: 0)

            control()
                .frame(width: 210, alignment: .trailing)
        }
    }

    private var rowDivider: some View {
        Divider()
            .padding(.leading, 181)
    }
}
