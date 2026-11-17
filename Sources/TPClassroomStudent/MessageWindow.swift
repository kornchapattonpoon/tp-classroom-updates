import AppKit
import SwiftUI

/// Shows a message the teacher sent, in a small window that floats above other apps.
@MainActor
final class MessageWindowController {
    private var windows: [NSWindow] = []

    func show(text: String, from teacher: String) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 180),
                            styleMask: [.titled, .closable],
                            backing: .buffered, defer: false)
        panel.title = "Message from \(teacher)"
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let view = MessageView(text: text, teacher: teacher) { [weak self, weak panel] in
            panel?.close()
            self?.windows.removeAll { $0 === panel }
        }
        let hosting = NSHostingView(rootView: view)
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        panel.center()

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        windows.append(panel)
    }
}

struct MessageView: View {
    let text: String
    let teacher: String
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "text.bubble.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Color.accentColor)
                Text(teacher)
                    .font(.headline)
            }
            Text(text)
                .font(.title3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack {
                Spacer()
                Button("OK") { onClose() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
