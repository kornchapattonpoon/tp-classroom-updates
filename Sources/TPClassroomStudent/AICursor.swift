import SwiftUI
import AppKit

/// TP AI's own pointer, drawn above everything on the student's screen while the AI clicks and types,
/// so the student (and the teacher's live view) can see exactly what the AI is doing.
/// It never takes clicks or keyboard focus, and it hides by itself after a few seconds.
@MainActor
final class AICursorOverlay {
    private let state = AICursorState()
    private var window: NSPanel?
    private var hideTask: Task<Void, Never>?

    func handle(action: String, x: Double?, y: Double?, text: String?) {
        if action == "hide" {
            hide()
            return
        }
        showWindow()
        let point = CGPoint(x: min(max(x ?? state.point.x, 0), 1), y: min(max(y ?? state.point.y, 0), 1))
        switch action {
        case "click":
            state.point = point
            state.typing = nil
            state.clicks += 1
        case "type":
            state.typing = text ?? ""
        default: // move
            state.typing = nil
            if state.visible {
                withAnimation(.easeInOut(duration: 0.55)) { state.point = point }
            } else {
                state.point = point
            }
        }
        withAnimation(.easeOut(duration: 0.2)) { state.visible = true }

        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    private func hide() {
        hideTask?.cancel()
        withAnimation(.easeIn(duration: 0.25)) { state.visible = false }
        state.typing = nil
    }

    private func showWindow() {
        // Main screen = the one with the menu bar; input coordinates use it too.
        guard let screen = NSScreen.screens.first else { return }
        if window == nil {
            let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: AICursorView(state: state))
            window = panel
        }
        if window?.frame != screen.frame { window?.setFrame(screen.frame, display: true) }
        window?.orderFrontRegardless()
    }
}

@MainActor
final class AICursorState: ObservableObject {
    @Published var point = CGPoint(x: 0.5, y: 0.5)
    @Published var visible = false
    @Published var typing: String? = nil
    @Published var clicks = 0
}

struct AICursorView: View {
    @ObservedObject var state: AICursorState

    var body: some View {
        GeometryReader { geometry in
            let spot = CGPoint(x: state.point.x * geometry.size.width, y: state.point.y * geometry.size.height)
            ZStack(alignment: .topLeading) {
                if state.clicks > 0 {
                    ClickRipple()
                        .id(state.clicks)
                        .position(spot)
                }
                AIPointer(typing: state.typing)
                    .offset(x: spot.x, y: spot.y)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .opacity(state.visible ? 1 : 0)
        }
        .ignoresSafeArea()
    }
}

/// The arrow (tip at the exact spot) and its "TP AI" tag.
private struct AIPointer: View {
    let typing: String?

    private var gradient: LinearGradient {
        LinearGradient(colors: [Color(red: 0.55, green: 0.35, blue: 1.0), Color(red: 0.2, green: 0.55, blue: 1.0)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ArrowShape()
                .fill(gradient)
                .overlay(ArrowShape().stroke(Color.white, lineWidth: 2))
                .frame(width: 22, height: 32)
                .shadow(color: .black.opacity(0.35), radius: 3, y: 1)

            HStack(spacing: 5) {
                Image(systemName: typing == nil ? "sparkles" : "keyboard")
                Text(label)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(gradient))
            .overlay(Capsule().stroke(Color.white.opacity(0.9), lineWidth: 1.5))
            .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
            .fixedSize()
            .frame(maxWidth: 360, alignment: .leading)
            .offset(x: 20, y: 28)
        }
    }

    private var label: String {
        guard let typing else { return "TP AI" }
        let shown = typing.replacingOccurrences(of: "\n", with: " ⏎ ")
        return shown.isEmpty ? "TP AI is typing…" : "TP AI is typing: " + String(shown.suffix(40))
    }
}

private struct ArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width / 12, h = rect.height / 19
        var path = Path()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: 0, y: 16 * h))
        path.addLine(to: CGPoint(x: 4 * w, y: 12.5 * h))
        path.addLine(to: CGPoint(x: 7 * w, y: 19 * h))
        path.addLine(to: CGPoint(x: 9.5 * w, y: 18 * h))
        path.addLine(to: CGPoint(x: 6.5 * w, y: 11.5 * h))
        path.addLine(to: CGPoint(x: 12 * w, y: 11.5 * h))
        path.closeSubpath()
        return path
    }
}

/// A ring that grows and fades where TP AI clicks.
private struct ClickRipple: View {
    @State private var grown = false

    var body: some View {
        Circle()
            .stroke(Color(red: 0.45, green: 0.45, blue: 1.0), lineWidth: 4)
            .frame(width: 60, height: 60)
            .scaleEffect(grown ? 1.4 : 0.2)
            .opacity(grown ? 0 : 0.9)
            .onAppear {
                withAnimation(.easeOut(duration: 0.6)) { grown = true }
            }
    }
}
