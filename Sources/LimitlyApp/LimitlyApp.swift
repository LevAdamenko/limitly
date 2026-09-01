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

        let title = NSMutableAttributedString()
        for (index, agent) in AgentID.allCases.enumerated() {
            if index > 0 { title.append(NSAttributedString(string: "  ")) }
            let attachment = NSTextAttachment()
            let image = AgentGlyphImages.image(for: agent, colorMode: monitor.settings.iconColor).copy() as! NSImage
            let renderedSize = iconSize * AgentGlyphImages.sizeMultiplier(for: agent)
            image.size = NSSize(width: renderedSize, height: renderedSize)
            attachment.image = image
            // Vertically centers the icon on the title's text baseline.
            let baselineOffset = (font.capHeight - renderedSize) / 2
            attachment.bounds = CGRect(x: 0, y: baselineOffset, width: renderedSize, height: renderedSize)
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
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 7) {
                Image(systemName: "chart.bar.fill")
                    .foregroundStyle(.secondary)
                Text("Limitly")
                    .font(.title3.weight(.semibold))
            }

            ForEach(AgentID.allCases, id: \.self) { agent in
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 8) {
                        AgentGlyph(agent: agent, colorMode: monitor.settings.iconColor, size: 20)
                        Text(agent.displayName)
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(monitor.percentageText(for: agent))
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(progressColor(for: agent))
                    }

                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.secondary.opacity(0.16))
                            Capsule()
                                .fill(progressColor(for: agent))
                                .frame(width: geometry.size.width * progressFraction(for: agent))
                        }
                    }
                    .frame(height: 7)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(monitor.usageText(for: agent))
                        if let reset = monitor.resetText(for: agent) {
                            Text(reset)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(11)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("Weekly usage", systemImage: "calendar")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                VStack(spacing: 0) {
                    ForEach(Array(AgentID.allCases.enumerated()), id: \.element) { index, agent in
                        HStack(spacing: 8) {
                            AgentGlyph(agent: agent, colorMode: monitor.settings.iconColor, size: 16)
                            Text(agent.displayName)
                                .fontWeight(.medium)
                            Spacer()
                            Text(monitor.weeklyText(for: agent))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)

                        if index < AgentID.allCases.count - 1 {
                            Divider()
                                .padding(.leading, 34)
                        }
                    }
                }
                .font(.caption)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }

            if let error = monitor.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            Divider()

            HStack(spacing: 8) {
                Button {
                    monitor.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }

                SettingsLink {
                    Label("Settings…", systemImage: "gearshape")
                }

                Spacer()

                Button("Quit Limitly") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(16)
        .frame(width: 344)
    }

    // Deliberately grounded in the real used fraction, not
    // `monitor.percentageText`'s displayed number — the "Show percentage
    // as: Remaining" setting inverts the printed text, but a progress bar
    // and its severity color must always reflect actual usage, or a user
    // in "Remaining" mode would see a reassuring green, mostly-empty bar
    // while sitting at 95% used.
    private func progressFraction(for agent: AgentID) -> CGFloat {
        CGFloat(min(max(monitor.usedFraction(for: agent) ?? 0, 0), 100) / 100)
    }

    private func progressColor(for agent: AgentID) -> Color {
        guard let percentage = monitor.usedFraction(for: agent) else { return .secondary }
        if percentage >= 90 { return .red }
        if percentage >= 70 { return .orange }
        return .green
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
        let renderedSize = size * AgentGlyphImages.sizeMultiplier(for: agent)
        Image(nsImage: AgentGlyphImages.image(for: agent, colorMode: colorMode))
            .renderingMode(.template)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: renderedSize, height: renderedSize)
            .accessibilityLabel(agent.displayName)
    }
}

private enum AgentGlyphImages {
    static let claudeBase = localOverride(named: "ClaudeIcon") ?? symbolImage(named: "sparkle", accessibilityDescription: "Claude")
    /// The official Codex mark's local PNG override bakes a lit-3D-sphere
    /// shading gradient into its own alpha channel (verified pixel-by-pixel:
    /// not ordinary antialiasing, and not recoverable as a flat silhouette
    /// by any per-pixel filter — thresholding produces a "moon phase" cutout
    /// because part of the shading genuinely fades to near-zero alpha same
    /// as the true background). Rather than load that file's pixels, its
    /// mere presence is used as an opt-in signal for a small hand-drawn flat
    /// vector mark instead, which sidesteps the problem entirely.
    static let codexBase = hasLocalOverride(named: "CodexIcon") ? codexVectorGlyph() : symbolImage(named: "chevron.left.forwardslash.chevron.right", accessibilityDescription: "Codex")

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

    /// The Claude mark (a thin sparkle/asterisk) has much more built-in
    /// transparent padding around its silhouette than the Codex mark (a
    /// disc that nearly fills its canvas), so at matching frame sizes
    /// Claude visibly renders smaller. Scaling its frame up compensates —
    /// the extra padding scales with it, but so does the visible glyph.
    static func sizeMultiplier(for agent: AgentID) -> CGFloat { agent == .claude ? 1.4 : 0.9 }

    /// `destinationIn` masks the tint color by `image`'s own alpha channel.
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

    /// Same from-source-only local check as `localOverride`, but only
    /// tests for the file's presence — the caller draws its own glyph
    /// rather than loading this file's pixels. See `codexBase`.
    private static func hasLocalOverride(named name: String) -> Bool {
        let sourceDirectory = (#filePath as NSString).deletingLastPathComponent
        return FileManager.default.fileExists(atPath: "\(sourceDirectory)/Resources/\(name).png")
    }

    /// A small flat vector nod to the Codex mark — a scalloped "cloud" blob
    /// (the real icon's outline, built from overlapping circles rather than
    /// a plain disc) with a left-of-center chevron and trailing bar punched
    /// out, evoking a terminal prompt (`>_`). Every pixel is either fully
    /// opaque or fully transparent, so it tints and downscales cleanly at
    /// any menu-bar size, unlike the shaded PNG it replaces (see
    /// `codexBase`). Punching the glyph out of the blob (rather than
    /// drawing it in a second color) is the standard technique for a
    /// single-tint template icon, matching how the original reads as a
    /// light glyph on a colored blob.
    private static func codexVectorGlyph() -> NSImage {
        let canvas = NSSize(width: 88, height: 88)
        let image = NSImage(size: canvas)
        image.lockFocus()

        NSColor.black.setFill()
        let center = NSPoint(x: 44, y: 44)
        let mainRadius: CGFloat = 27
        NSBezierPath(ovalIn: NSRect(x: center.x - mainRadius, y: center.y - mainRadius, width: mainRadius * 2, height: mainRadius * 2)).fill()
        let bumpCount = 8
        let bumpRadius: CGFloat = 15
        let bumpDistance: CGFloat = 27
        for i in 0..<bumpCount {
            let angle = (CGFloat(i) / CGFloat(bumpCount)) * 2 * .pi + .pi / 2
            let x = center.x + bumpDistance * cos(angle)
            let y = center.y + bumpDistance * sin(angle)
            NSBezierPath(ovalIn: NSRect(x: x - bumpRadius, y: y - bumpRadius, width: bumpRadius * 2, height: bumpRadius * 2)).fill()
        }

        NSGraphicsContext.current?.compositingOperation = .destinationOut
        NSColor.black.setStroke()
        NSColor.black.setFill()

        let chevron = NSBezierPath()
        chevron.move(to: NSPoint(x: 26, y: 58))
        chevron.line(to: NSPoint(x: 43, y: 44))
        chevron.line(to: NSPoint(x: 26, y: 30))
        chevron.lineWidth = 9
        chevron.lineCapStyle = .round
        chevron.lineJoinStyle = .round
        chevron.stroke()

        NSBezierPath(roundedRect: NSRect(x: 48, y: 27, width: 20, height: 8), xRadius: 4, yRadius: 4).fill()

        NSGraphicsContext.current?.compositingOperation = .sourceOver
        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}
