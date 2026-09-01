import AppKit
import SwiftUI

@MainActor
final class BannerController {
    private var panel: NSPanel?
    private var dismissWorkItem: DispatchWorkItem?
    private var pending: [(title: String, body: String, onClick: (() -> Void)?)] = []
    private var isShowing = false

    /// Queues rather than shows immediately if a banner is already up —
    /// the panel is a single reused window, so a second `show()` call
    /// arriving before the first banner's 6s auto-dismiss (e.g. a
    /// threshold alert and a weekly alert both firing out of the same
    /// synchronous refresh pass) used to silently overwrite it before the
    /// user ever saw it.
    func show(title: String, body: String, onClick: (() -> Void)? = nil) {
        guard !isShowing else {
            pending.append((title, body, onClick))
            return
        }
        present(title: title, body: body, onClick: onClick)
    }

    private func present(title: String, body: String, onClick: (() -> Void)?) {
        isShowing = true
        dismissWorkItem?.cancel()
        let view = BannerView(title: title, message: body, onClick: onClick)
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let width = size.width; let height = size.height
        let panel = self.panel ?? NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar; panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; panel.contentView = host
        // The panel is reused across calls, so its size must be reset here
        // too, not just its position — otherwise a later banner with longer
        // text keeps an earlier, differently-sized banner's window bounds
        // while being centered as if it had the new width, throwing off the
        // apparent center. On a multi-monitor setup neither `NSScreen.main`
        // (whichever screen last had focus) nor the menu-bar screen is
        // reliably the one the user is actually looking at, so target
        // whichever screen currently has the mouse cursor instead.
        let cursor = NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first(where: { $0.frame.contains(cursor) })
            ?? NSScreen.screens.first(where: { $0.frame.origin == .zero })
            ?? NSScreen.main
        if let screen = targetScreen {
            let visible = screen.visibleFrame
            let origin = NSPoint(x: visible.midX - width / 2, y: visible.maxY - height - 8)
            panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
        }
        panel.orderFrontRegardless(); self.panel = panel
        // `NSSound.beep()` is a system alert call routed through NSApp — on
        // some setups that can trigger the "flash screen instead of sound"
        // accessibility behavior or otherwise touch window/focus state,
        // which is disruptive if the user has a fullscreen game capturing
        // the cursor. Playing a specific named sound directly is a plain
        // audio call with no such side effects.
        NSSound(named: "Glass")?.play()
        let item = DispatchWorkItem { [weak self, weak panel] in
            panel?.orderOut(nil)
            self?.advanceQueue()
        }
        dismissWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: item)
    }

    private func advanceQueue() {
        isShowing = false
        guard !pending.isEmpty else { return }
        let next = pending.removeFirst()
        present(title: next.title, body: next.body, onClick: next.onClick)
    }
}

private struct BannerView: View {
    let title: String; let message: String
    let onClick: (() -> Void)?
    // `minWidth` is applied here, before `.background`, so the visible
    // rounded-rect grows (and its short-text content re-centers) to fill
    // that minimum — putting a `max(360, ...)` on the AppKit window's width
    // instead left the window wider than the actual SwiftUI content, which
    // sat pinned to the window's leading edge, throwing the *visible*
    // banner off-center from the window frame it was centered by.
    var body: some View {
        if let onClick {
            content
                .contentShape(Rectangle())
                .onTapGesture(perform: onClick)
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(message).font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(minWidth: 360, minHeight: 74)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}
