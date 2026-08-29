import AppKit
import Combine
import SwiftUI
import LimitlyCore

@main
struct LimitlyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { SettingsView(settings: appDelegate.monitor.settings, sendTestAlert: appDelegate.monitor.sendTestAlert) }
    }
}

/// Single NSStatusItem with a manually-composed attributed title (icon,
/// percent, icon, percent) and one NSPopover for the dropdown.
///
/// Two prior approaches both broke: one `MenuBarExtra` label containing a
/// compound HStack (icon+text+"·"+icon+text) got silently truncated to its
/// first element, and two separate `MenuBarExtra` scenes each opened their
/// own full-content popover — clicking either could leave two duplicate
/// dropdowns open at once. A single hand-built NSStatusItem sidesteps both:
/// AppKit's NSAttributedString/NSTextAttachment title composition is the
/// same mechanism every other real menu-bar app already uses successfully.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let monitor = UsageMonitor()
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var snapshotCancellable: AnyCancellable?
    private var iconColorCancellable: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        statusItem = item

        let pop = NSPopover()
        pop.behavior = .transient
        pop.contentViewController = NSHostingController(rootView: MenuContentView(monitor: monitor))
        popover = pop

        updateTitle()
        snapshotCancellable = monitor.$snapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateTitle() }
        iconColorCancellable = monitor.settings.$iconColor
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateTitle() }
    }

    private func updateTitle() {
        guard let button = statusItem?.button else { return }
        let font = NSFont.menuBarFont(ofSize: 0)
        let iconSize: CGFloat = 17
        // Vertically centers the icon on the title's text baseline.
        let baselineOffset = (font.capHeight - iconSize) / 2

        let title = NSMutableAttributedString()
        for (index, agent) in AgentID.allCases.enumerated() {
            if index > 0 { title.append(NSAttributedString(string: "  ")) }
            let attachment = NSTextAttachment()
            let image = AgentGlyphImages.image(for: agent, colorMode: monitor.settings.iconColor).copy() as! NSImage
            image.size = NSSize(width: iconSize, height: iconSize)
            attachment.image = image
            attachment.bounds = CGRect(x: 0, y: baselineOffset, width: iconSize, height: iconSize)
            title.append(NSAttributedString(attachment: attachment))
            title.append(NSAttributedString(
                string: " \(monitor.percentageText(for: agent))",
                attributes: [.font: font]
            ))
        }
        button.attributedTitle = title
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button, let pop = popover else { return }
        if pop.isShown {
            pop.performClose(nil)
        } else {
            pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
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
                        AgentGlyph(agent: agent, colorMode: monitor.settings.iconColor)
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
                    AgentGlyph(agent: agent, colorMode: monitor.settings.iconColor, size: 17)
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

/// Per-agent glyphs. Ships as generic SF Symbols so the repository stays
/// free of any third-party trademarked artwork; a developer's own local
/// checkout can drop PNGs into `Resources/` (gitignored, never published —
/// see .gitignore) to use nicer icons on their own machine only.
private struct AgentGlyph: View {
    let agent: AgentID
    let colorMode: IconColorMode
    var size: CGFloat = 19

    var body: some View {
        Image(nsImage: AgentGlyphImages.image(for: agent, colorMode: colorMode))
            .renderingMode(.template)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .accessibilityLabel(agent.displayName)
    }
}

private enum AgentGlyphImages {
    static let claudeBase = localOverride(named: "ClaudeIcon") ?? symbolImage(named: "sparkle", accessibilityDescription: "Claude")
    static let codexBase = localOverride(named: "CodexIcon") ?? symbolImage(named: "chevron.left.forwardslash.chevron.right", accessibilityDescription: "Codex")

    /// `.automatic` keeps the image a template (macOS adapts it to light/dark
    /// menu bars); `.black`/`.white` bake in a specific color instead, so it
    /// stays fixed regardless of menu bar appearance.
    static func image(for agent: AgentID, colorMode: IconColorMode) -> NSImage {
        let base = agent == .claude ? claudeBase : codexBase
        switch colorMode {
        case .automatic: return base
        case .black: return tinted(base, color: .black)
        case .white: return tinted(base, color: .white)
        }
    }

    private static func tinted(_ image: NSImage, color: NSColor) -> NSImage {
        let size = image.size
        let result = NSImage(size: size)
        result.lockFocus()
        color.set()
        NSRect(origin: .zero, size: size).fill()
        image.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .destinationIn, fraction: 1.0)
        result.unlockFocus()
        result.isTemplate = false
        return result
    }

    private static func symbolImage(named name: String, accessibilityDescription: String) -> NSImage {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: accessibilityDescription) else {
            return NSImage(size: NSSize(width: 1, height: 1))
        }
        image.isTemplate = true
        return image
    }

    /// `#filePath` resolves to this exact source file's absolute path on the
    /// machine that compiled it, so this only ever finds anything on a
    /// from-source local build — never in a build from a fresh clone, and
    /// never bundled into anything distributed.
    private static func localOverride(named name: String) -> NSImage? {
        let sourceDirectory = (#filePath as NSString).deletingLastPathComponent
        let path = "\(sourceDirectory)/Resources/\(name).png"
        guard FileManager.default.fileExists(atPath: path), let image = NSImage(contentsOfFile: path) else { return nil }
        image.isTemplate = true
        return image
    }
}
