import SwiftUI
import LimitlyCore

@main
struct LimitlyApp: App {
    @StateObject private var monitor = UsageMonitor()

    var body: some Scene {
        MenuBarExtra { MenuContentView(monitor: monitor) } label: {
            Text(monitor.menuBarTitle)
        }
        .menuBarExtraStyle(.window)

        Settings { SettingsView(settings: monitor.settings) }
    }
}

private struct MenuContentView: View {
    @ObservedObject var monitor: UsageMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Limitly").font(.headline)
            ForEach(AgentID.allCases, id: \.self) { agent in
                VStack(alignment: .leading, spacing: 3) {
                    HStack { Text(agent.displayName); Spacer(); Text(monitor.percentageText(for: agent)).monospacedDigit() }
                    Text(monitor.usageText(for: agent)).font(.caption).foregroundStyle(.secondary)
                    if let reset = monitor.resetText(for: agent) { Text(reset).font(.caption).foregroundStyle(.secondary) }
                }
            }
            Divider()
            Text("Weekly usage").font(.subheadline.weight(.semibold))
            ForEach(AgentID.allCases, id: \.self) { agent in Text("\(agent.displayName): \(monitor.weeklyText(for: agent))").font(.caption) }
            if let error = monitor.lastError { Text(error).font(.caption).foregroundStyle(.red).lineLimit(2) }
            Divider()
            HStack { Button("Refresh") { monitor.refresh() }; Spacer(); SettingsLink { Text("Settings…") } }
            Button("Quit Limitly") { NSApplication.shared.terminate(nil) }
        }
        .padding(14)
        .frame(width: 300)
    }
}
