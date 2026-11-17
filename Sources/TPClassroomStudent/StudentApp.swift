import SwiftUI
import AppKit
import ClassroomKit

/// TP Classroom Student lives in the menu bar (no Dock icon) and keeps running in the background.
/// The eye icon is always visible and fills in while the teacher is watching.
@main
struct StudentApp: App {
    @NSApplicationDelegateAdaptor(StudentAppDelegate.self) private var appDelegate
    @StateObject private var agent = StudentAgent.shared

    var body: some Scene {
        MenuBarExtra {
            StudentMenu(agent: agent)
        } label: {
            Image(systemName: menuIcon)
        }
    }

    private var menuIcon: String {
        if agent.isBeingControlled { return "hand.point.up.left.fill" }
        if agent.isBeingViewed { return "eye.fill" }
        return "eye"
    }
}

@MainActor
final class StudentAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Only one copy may run.
        let myPID = ProcessInfo.processInfo.processIdentifier
        if let bundleID = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .contains(where: { $0.processIdentifier != myPID && !$0.isTerminated }) {
            AppLifecycle.allowQuit = true
            NSApp.terminate(nil)
            return
        }
        // Logging out or shutting down must never be blocked.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willPowerOffNotification,
                                                          object: nil, queue: .main) { _ in
            DispatchQueue.main.async { AppLifecycle.allowQuit = true }
        }
        StudentAgent.shared.launch()
    }

    /// Students can't quit it; it keeps running in the background.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppLifecycle.allowQuit ? .terminateNow : .terminateCancel
    }
}

struct StudentMenu: View {
    @ObservedObject var agent: StudentAgent

    var body: some View {
        Text("TP Classroom Student \(AppInfo.version)")
        Text(agent.statusLine)
        if agent.isBeingControlled {
            Text("Your teacher is controlling this Mac")
        } else if agent.isBeingViewed {
            Text("Your teacher can see this screen")
        }
        if let update = agent.updateStatus {
            Text(update)
        }

        Divider()

        if !agent.hasScreenRecording {
            Button("Allow Screen Recording…") { agent.openScreenRecordingSettings() }
        }
        if !agent.hasAccessibility {
            Button("Allow Remote Control (Accessibility)…") { agent.openAccessibilitySettings() }
        }
        Button("Settings…") { agent.openSettingsAskingPIN() }

        Divider()

        Button("Stop Until Next Login…") { agent.stopAskingPIN() }
    }
}
