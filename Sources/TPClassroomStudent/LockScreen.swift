import AppKit
import SwiftUI

/// Borderless windows can't normally take keyboard focus; the lock window needs it
/// so typing goes nowhere while the screen is locked.
final class LockWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Covers every display with a "locked" screen when the teacher locks this Mac.
@MainActor
final class LockScreenController {
    private(set) var isLocked = false
    /// Checks an admin PIN typed on the lock screen; returns true if it unlocked.
    var verifyPIN: (@MainActor (String) -> Bool)?

    private var windows: [NSWindow] = []

    func lock(message: String, teacher: String, allowAdminUnlock: Bool) {
        removeWindows()
        for (index, screen) in NSScreen.screens.enumerated() {
            let window = LockWindow(contentRect: screen.frame, styleMask: [.borderless],
                                    backing: .buffered, defer: false)
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.backgroundColor = .black
            window.isOpaque = true
            window.hasShadow = false
            window.isReleasedWhenClosed = false

            let view = LockView(message: message,
                                teacher: teacher,
                                showAdminUnlock: allowAdminUnlock && index == 0,
                                onAdminUnlock: { [weak self] pin in
                                    self?.verifyPIN?(pin) ?? false
                                })
            window.contentView = NSHostingView(rootView: view)
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
            if index == 0 { window.makeKey() }
            windows.append(window)
        }
        NSApp.activate(ignoringOtherApps: true)
        NSApp.presentationOptions = [.hideDock, .hideMenuBar, .disableProcessSwitching,
                                     .disableForceQuit, .disableSessionTermination, .disableHideApplication]
        isLocked = true
    }

    func unlock() {
        removeWindows()
        NSApp.presentationOptions = []
        isLocked = false
    }

    private func removeWindows() {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
    }
}

struct LockView: View {
    let message: String
    let teacher: String
    let showAdminUnlock: Bool
    let onAdminUnlock: (String) -> Bool

    @State private var askingForPIN = false
    @State private var pin = ""
    @State private var wrongPIN = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.10, green: 0.12, blue: 0.28), Color.black],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 22) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 72, weight: .semibold))
                Text(message.isEmpty ? "Eyes on your teacher, please" : message)
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)
                Text("Locked by \(teacher)")
                    .font(.title3)
                    .opacity(0.7)
            }
            .foregroundStyle(Color.white)
            .padding(60)

            if showAdminUnlock {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        adminUnlock
                    }
                }
                .padding(24)
            }
        }
    }

    @ViewBuilder
    private var adminUnlock: some View {
        if askingForPIN {
            HStack(spacing: 8) {
                if wrongPIN {
                    Text("Wrong PIN").foregroundStyle(Color.red)
                }
                SecureField("Admin PIN", text: $pin)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                    .onSubmit(submit)
                Button("Unlock", action: submit)
                Button("Cancel") {
                    askingForPIN = false
                    pin = ""
                    wrongPIN = false
                }
            }
        } else {
            Button("Admin") { askingForPIN = true }
                .buttonStyle(.plain)
                .foregroundStyle(Color.white.opacity(0.35))
        }
    }

    private func submit() {
        if !onAdminUnlock(pin) {
            wrongPIN = true
            pin = ""
        }
    }
}
