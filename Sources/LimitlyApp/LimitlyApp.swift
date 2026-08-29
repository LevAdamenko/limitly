import AppKit
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

/// Abstract agent glyphs, displayed as cached AppKit template images.
///
/// `MenuBarExtra` labels can discard non-Text SwiftUI views. Rasterizing these
/// simple paths once keeps the label entirely on AppKit's well-supported image
/// path while allowing the same glyphs to be reused in the menu content.
private struct AgentGlyph: View {
    let agent: AgentID
    var size: CGFloat = 15

    var body: some View {
        Image(nsImage: agent == .claude
              ? AgentGlyphImages.claudeTemplateImage
              : AgentGlyphImages.codexTemplateImage)
        .renderingMode(.template)
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(width: size, height: size)
        .accessibilityLabel(agent.displayName)
    }
}

private enum AgentGlyphImages {
    /// 32pt source images provide crisp downsampling at the 14–15pt menu-bar size.
    static let claudeTemplateImage = templateImage { rect in
        ClaudeGlyph().path(in: rect)
    }

    static let codexTemplateImage = templateImage { rect in
        CodexGlyph().path(in: rect)
    }

    private static func templateImage(path: @escaping (CGRect) -> Path) -> NSImage {
        let image = NSImage(size: CGSize(width: 32, height: 32), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(cgPath: path(rect).cgPath).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// A chunky eight-ray asterisk, intentionally not based on a brand mark.
private struct ClaudeGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let side = min(rect.width, rect.height)
        let rayLength = side * 0.27
        let rayWidth = side * 0.14
        let rayCenterDistance = side * 0.24
        var path = Path()

        for index in 0..<8 {
            let angle = CGFloat(index) * .pi / 4
            let ray = Path(roundedRect: CGRect(
                x: -rayWidth / 2,
                y: -rayCenterDistance - rayLength / 2,
                width: rayWidth,
                height: rayLength
            ), cornerRadius: rayWidth / 2)
            path.addPath(ray.applying(CGAffineTransform(translationX: center.x, y: center.y)
                .rotated(by: angle)))
        }
        path.addEllipse(in: CGRect(x: center.x - rayWidth * 0.7, y: center.y - rayWidth * 0.7,
                                   width: rayWidth * 1.4, height: rayWidth * 1.4))
        return path
    }
}

/// A solid six-petal radial knot: deliberately bold enough to remain legible at 15pt.
private struct CodexGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let petalWidth = side * 0.22
        let petalLength = side * 0.33
        let petalCenterDistance = side * 0.24
        var path = Path()

        for index in 0..<6 {
            let angle = CGFloat(index) * .pi / 3
            let petal = Path(roundedRect: CGRect(
                x: -petalWidth / 2,
                y: -petalCenterDistance - petalLength / 2,
                width: petalWidth,
                height: petalLength
            ), cornerRadius: petalWidth / 2)
            path.addPath(petal.applying(CGAffineTransform(translationX: center.x, y: center.y)
                .rotated(by: angle)))
        }
        return path
    }
}
