import AppKit
import SwiftUI
import ClassroomKit

/// First-run setup (and Settings, behind the admin PIN).
@MainActor
final class SetupWindowController {
    private var window: NSWindow?

    func show(store: StudentConfigStore, agent: StudentAgent, onSave: @escaping @MainActor () -> Void) {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let view = SetupView(store: store, agent: agent) { [weak self] in
            onSave()
            self?.close()
        }
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "TP Classroom Student"
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.center()
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
        window = nil
    }
}

struct SetupView: View {
    @ObservedObject var store: StudentConfigStore
    @ObservedObject var agent: StudentAgent
    let onSave: @MainActor () -> Void

    @State private var classCode = ""
    @State private var displayName = ""
    @State private var pin = ""
    @State private var pinAgain = ""
    @State private var problem: String? = nil
    @State private var installing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "eye.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Set up TP Classroom")
                        .font(.title2.bold())
                    Text("During class your teacher can see this screen and help with this Mac.")
                        .foregroundStyle(.secondary)
                }
            }

            if store.isManaged {
                Label("This Mac was set up by your school, so only the name can be changed here.",
                      systemImage: "building.columns")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Form {
                if !store.isManaged {
                    TextField("Class code", text: $classCode)
                }
                TextField("Name shown to teacher", text: $displayName, prompt: Text(AppInfo.computerName))
                if !store.isManaged {
                    SecureField(store.hasPIN ? "New admin PIN (optional)" : "Admin PIN (protects Stop & Settings)",
                                text: $pin)
                    SecureField("Type the PIN again", text: $pinAgain)
                }
            }

            GroupBox("Permissions") {
                VStack(alignment: .leading, spacing: 10) {
                    PermissionRow(title: "Screen Recording",
                                  detail: "Lets your teacher see this screen",
                                  granted: agent.hasScreenRecording) {
                        agent.openScreenRecordingSettings()
                    }
                    PermissionRow(title: "Accessibility",
                                  detail: "Lets your teacher use the mouse and keyboard when helping",
                                  granted: agent.hasAccessibility) {
                        agent.openAccessibilitySettings()
                    }
                    Text("After turning on Screen Recording, log out and back in.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(6)
            }

            if !store.isManaged {
                GroupBox("Install on this Mac") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Recommended for school Macs: works for every student account, starts at login, keeps running in the background and lets the teacher update it. Asks for an administrator password.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(installing ? "Installing…" : "Install for All Users on This Mac…") { installForAllUsers() }
                            .disabled(installing)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }
            }

            if let problem {
                Text(problem).foregroundStyle(Color.red)
            }

            HStack {
                if agent.isRunningFromDiskImage {
                    Text("Opened from the disk image: use Install above.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(agent.isRunningFromDiskImage && !store.isManaged)
            }
        }
        .padding(22)
        .frame(width: 480)
        .onAppear {
            classCode = store.config?.classCode ?? ""
            displayName = store.config?.displayName ?? ""
        }
    }

    private func installForAllUsers() {
        let code = ClassCrypto.normalize(classCode)
        let allowedCode = code.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        guard !code.isEmpty, allowedCode else {
            problem = "Type the class code (letters, numbers, - or _)."
            return
        }
        guard pin == pinAgain else {
            problem = "The two PINs don't match."
            return
        }
        guard pin.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            problem = "The admin PIN may only use letters and numbers."
            return
        }
        problem = nil
        installing = true
        agent.installForAllUsers(code: code, pin: pin) { error in
            installing = false
            if let error {
                problem = error
            } else {
                store.reload()
                onSave()
            }
        }
    }

    private func save() {
        let code = ClassCrypto.normalize(classCode)
        if !store.isManaged && code.isEmpty {
            problem = "Type the class code your teacher gave you."
            return
        }
        if pin != pinAgain {
            problem = "The two PINs don't match."
            return
        }
        var newConfig = store.config ?? StudentConfig(classCode: code)
        if !store.isManaged {
            newConfig.classCode = code
            if !pin.isEmpty { newConfig.adminPINHash = StudentConfigStore.hash(pin) }
        }
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        newConfig.displayName = name.isEmpty ? nil : name
        store.saveLocal(newConfig)
        problem = nil
        pin = ""
        pinAgain = ""
        onSave()
    }
}

struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).bold()
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button("Open Settings") { action() }
            }
        }
    }
}
