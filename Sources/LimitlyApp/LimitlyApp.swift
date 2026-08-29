import SwiftUI
import LimitlyCore

@main
struct LimitlyApp: App {
    @StateObject private var monitor = UsageMonitor()

    var body: some Scene {
        MenuBarExtra { MenuContentView(monitor: monitor) } label: {
            MenuBarLabel(monitor: monitor)
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
                    HStack {
                        AgentGlyph(agent: agent)
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

private struct MenuBarLabel: View {
    @ObservedObject var monitor: UsageMonitor

    var body: some View {
        HStack(spacing: 4) {
            AgentGlyph(agent: .claude)
            Text(monitor.percentageText(for: .claude)).monospacedDigit()
            Text("·")
            AgentGlyph(agent: .codex)
            Text(monitor.percentageText(for: .codex)).monospacedDigit()
        }
    }
}

/// Original abstract agent glyphs, drawn as template-style monochrome vectors.
private struct AgentGlyph: View {
    let agent: AgentID
    var size: CGFloat = 15

    var body: some View {
        Group {
            switch agent {
            case .claude:
                ClaudeGlyph().fill(.primary)
            case .codex:
                CodexGlyph().stroke(.primary, lineWidth: 1.4)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(agent.displayName)
    }
}

/// A twelve-point radiating asterisk, intentionally not based on a brand mark.
private struct ClaudeGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        let inner = outer * 0.43
        var path = Path()

        for index in 0..<24 {
            let angle = CGFloat(index) * .pi / 12 - .pi / 2
            let radius = index.isMultiple(of: 2) ? outer : inner
            let point = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
            index == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        path.closeSubpath()
        return path
    }
}

/// A small six-petal outline flower made from overlapping circular loops.
private struct CodexGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let radius = min(rect.width, rect.height)
        let loopRadius = radius * 0.27
        let orbit = radius * 0.20
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()

        for index in 0..<6 {
            let angle = CGFloat(index) * .pi / 3 - .pi / 2
            let loopCenter = CGPoint(x: center.x + cos(angle) * orbit, y: center.y + sin(angle) * orbit)
            path.addEllipse(in: CGRect(x: loopCenter.x - loopRadius, y: loopCenter.y - loopRadius, width: loopRadius * 2, height: loopRadius * 2))
        }
        return path
    }
}
