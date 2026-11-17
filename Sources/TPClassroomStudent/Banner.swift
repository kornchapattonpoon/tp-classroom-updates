import AppKit
import SwiftUI

/// A small pill at the top of the screen telling the student what the teacher is doing.
/// It ignores the mouse, so it never gets in the way.
@MainActor
final class BannerController {
    enum Style {
        case info
        case viewing
        case controlling
    }

    private struct Content {
        let text: String
        let style: Style
    }

    private var panel: NSPanel?
    private var persistent: Content?
    private var flashTask: Task<Void, Never>?

    /// A banner that stays until replaced (e.g. "Your teacher is viewing your screen").
    func setPersistent(_ text: String?, style: Style = .viewing) {
        persistent = text.map { Content(text: $0, style: style) }
        if flashTask == nil { render(persistent) }
    }

    /// A banner shown for a few seconds, then the persistent one comes back.
    func flash(_ text: String, seconds: Double = 6) {
        flashTask?.cancel()
        render(Content(text: text, style: .info))
        flashTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.flashTask = nil
            self.render(self.persistent)
        }
    }

    private func render(_ content: Content?) {
        guard let content else {
            panel?.orderOut(nil)
            return
        }
        let panel = self.panel ?? makePanel()
        self.panel = panel

        let hosting = NSHostingView(rootView: BannerView(text: content.text, style: content.style))
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting

        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let area = screen.visibleFrame
            panel.setFrame(NSRect(x: area.midX - size.width / 2, y: area.maxY - size.height - 10,
                                  width: size.width, height: size.height), display: true)
        }
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 40),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        return panel
    }
}

struct BannerView: View {
    let text: String
    let style: BannerController.Style

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
            Text(text)
                .font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(Color.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Capsule().fill(color))
        .fixedSize()
        .padding(4)
    }

    private var icon: String {
        switch style {
        case .info: return "info.circle.fill"
        case .viewing: return "eye.fill"
        case .controlling: return "hand.point.up.left.fill"
        }
    }

    private var color: Color {
        switch style {
        case .info: return Color(red: 0.20, green: 0.35, blue: 0.85)
        case .viewing: return Color(red: 0.85, green: 0.45, blue: 0.05)
        case .controlling: return Color(red: 0.85, green: 0.15, blue: 0.20)
        }
    }
}
