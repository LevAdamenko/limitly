import AppKit
import SwiftUI
import LimitlyCore

@main
struct LimitlyApp: App {
    @StateObject private var monitor = UsageMonitor()

    var body: some Scene {
        // Two separate MenuBarExtra scenes, not one combined label: a single
        // compound HStack (icon+text+"·"+icon+text) was silently truncated by
        // AppKit's status-item sizing to just its first element. Two simple
        // one-icon-one-text labels are the pattern every other menu-bar app
        // uses and are what reliably renders in full.
        MenuBarExtra { MenuContentView(monitor: monitor) } label: {
            AgentTitle(monitor: monitor, agent: .claude)
        }
        .menuBarExtraStyle(.window)

        MenuBarExtra { MenuContentView(monitor: monitor) } label: {
            AgentTitle(monitor: monitor, agent: .codex)
        }
        .menuBarExtraStyle(.window)

        Settings { SettingsView(settings: monitor.settings) }
    }
}

private struct AgentTitle: View {
    @ObservedObject var monitor: UsageMonitor
    let agent: AgentID

    var body: some View {
        HStack(spacing: 4) {
            AgentGlyph(agent: agent)
            Text(monitor.percentageText(for: agent)).monospacedDigit()
        }
    }
}

private struct MenuContentView: View {
    @ObservedObject var monitor: UsageMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Limitly").font(.headline)
            ForEach(AgentID.allCases, id: \.self) { agent in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        AgentGlyph(agent: agent)
                        Text(agent.displayName)
                        Spacer()
                        Text(monitor.percentageText(for: agent)).monospacedDigit()
                    }
                    Text(monitor.usageText(for: agent)).font(.caption).foregroundStyle(.secondary)
                    if let reset = monitor.resetText(for: agent) { Text(reset).font(.caption).foregroundStyle(.secondary) }
                }
            }
            Divider()
            Text("Weekly usage").font(.subheadline.weight(.semibold))
            ForEach(AgentID.allCases, id: \.self) { agent in
                HStack(spacing: 5) {
                    AgentGlyph(agent: agent, size: 14)
                    Text(monitor.weeklyText(for: agent))
                }
                .font(.caption)
            }
            if let error = monitor.lastError { Text(error).font(.caption).foregroundStyle(.red).lineLimit(2) }
            Divider()
            HStack { Button("Refresh") { monitor.refresh() }; Spacer(); SettingsLink { Text("Settings…") } }
            Button("Quit Limitly") { NSApplication.shared.terminate(nil) }
        }
        .padding(14)
        .frame(width: 300)
    }
}

/// Real per-agent monochrome template icons, taken directly from the
/// official Claude and ChatGPT desktop apps' own tray-icon assets
/// (personal, non-distributed use — not our own artwork).
private struct AgentGlyph: View {
    let agent: AgentID
    var size: CGFloat = 15

    var body: some View {
        Image(nsImage: AgentGlyphImages.image(for: agent))
            .renderingMode(.template)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .accessibilityLabel(agent.displayName)
    }
}

private enum AgentGlyphImages {
    static let claudeImage = loadTemplateImage(named: "ClaudeIcon")
    static let codexImage = loadTemplateImage(named: "CodexIcon")

    static func image(for agent: AgentID) -> NSImage {
        agent == .claude ? claudeImage : codexImage
    }

    private static func loadTemplateImage(named name: String) -> NSImage {
        guard let url = Bundle.module.url(forResource: name, withExtension: "png"),
              let image = NSImage(contentsOf: url) else {
            return NSImage(size: NSSize(width: 1, height: 1))
        }
        image.isTemplate = true
        return image
    }
}
