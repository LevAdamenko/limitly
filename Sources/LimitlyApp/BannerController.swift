import AppKit
import SwiftUI

@MainActor
final class BannerController {
    private var panel: NSPanel?
    private var dismissWorkItem: DispatchWorkItem?
    func show(title: String, body: String) {
        dismissWorkItem?.cancel()
        let view = BannerView(title: title, message: body)
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let frame = NSRect(x: 0, y: 0, width: max(360, size.width), height: max(74, size.height))
        let panel = self.panel ?? NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar; panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; panel.contentView = host
        if let screen = NSScreen.main { let visible = screen.visibleFrame; panel.setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2, y: visible.maxY - frame.height - 8)) }
        panel.orderFrontRegardless(); self.panel = panel
        let item = DispatchWorkItem { [weak panel] in panel?.orderOut(nil) }; dismissWorkItem = item; DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: item)
    }
}

private struct BannerView: View {
    let title: String; let message: String
    var body: some View { VStack(alignment: .leading, spacing: 4) { Text(title).font(.headline); Text(message).font(.subheadline).foregroundStyle(.secondary) }.padding(.horizontal, 20).padding(.vertical, 14).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14)) }
}
