import AppKit
import Combine
import SwiftUI
import LimitlyCore

@main
struct LimitlyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { SettingsView(settings: appDelegate.monitor.settings) }
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
    private var cancellable: AnyCancellable?

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
        cancellable = monitor.$snapshot
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
            let image = AgentGlyphImages.image(for: agent).copy() as! NSImage
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
                    AgentGlyph(agent: agent, size: 17)
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
    var size: CGFloat = 19

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
