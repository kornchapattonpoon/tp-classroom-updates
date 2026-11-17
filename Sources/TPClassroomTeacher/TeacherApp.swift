import SwiftUI
import AppKit
import ServiceManagement
import ClassroomKit

/// The teacher app. Windows are managed by `TeacherAppDelegate` so the app can keep
/// running in the menu bar when you quit it (students stay connected and remembered).
@main
struct TeacherApp: App {
    @NSApplicationDelegateAdaptor(TeacherAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { appDelegate.showSettings() }
                    .keyboardShortcut(",")
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { appDelegate.checkForUpdates() }
            }
            CommandGroup(after: .appTermination) {
                Button("Quit TP Classroom Completely") { appDelegate.quitCompletelyFromMenu() }
                    .keyboardShortcut("q", modifiers: [.command, .option])
            }
        }
    }
}

@MainActor
final class TeacherAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private(set) var model: ClassroomModel!
    private(set) var updater: Updater!
    private(set) var assistant: AIAssistant!
    private var aiWindow: NSWindow?

    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var liveWindows: [(session: StudentSession, window: NSWindow)] = []
    private var statusItem: NSStatusItem?
    private var launchedAtLogin = false
    private var pendingCompletedUpdate: (version: String, notes: String?)?

    // MARK: - Launch

    func applicationWillFinishLaunching(_ notification: Notification) {
        // 'oapp' event with 'lgit' = started automatically at login.
        if let event = NSAppleEventManager.shared().currentAppleEvent,
           event.eventID == 0x6F617070,
           event.paramDescriptor(forKeyword: 0x70726474)?.enumCodeValue == 0x6C676974 {
            launchedAtLogin = true
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Only one teacher app at a time.
        let myPID = ProcessInfo.processInfo.processIdentifier
        if let bundleID = Bundle.main.bundleIdentifier,
           let other = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first(where: { $0.processIdentifier != myPID && !$0.isTerminated }) {
            if other.bundleURL?.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL {
                other.activate(options: [])
                AppLifecycle.allowQuit = true
                NSApp.terminate(nil)
                return
            }
            // A copy from somewhere else is running (e.g. an old one opened from the build folder):
            // the copy just opened takes over, so installing a new version needs no quitting first.
            other.forceTerminate()
        }

        if offerMoveToApplications() { return }

        let updater = Updater(assetName: "mac-teacher")
        let model = ClassroomModel(updater: updater)
        self.updater = updater
        self.model = model
        assistant = AIAssistant(model: model)
        model.onOpenLive = { [weak self] session in self?.openLiveWindow(for: session) }
        model.onOpenAI = { [weak self] in self?.showAIWindow() }
        // Don't restart in the middle of helping a student.
        updater.shouldDeferInstall = { [weak self] in
            !(self?.liveWindows.isEmpty ?? true)
        }
        updater.relaunchInBackground = { [weak self] in
            !(self?.mainWindow?.isVisible ?? false)
        }

        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willPowerOffNotification,
                                                          object: nil, queue: .main) { _ in
            DispatchQueue.main.async { AppLifecycle.allowQuit = true }
        }

        setUpStatusItem()
        registerLoginItemTheFirstTime()
        model.start()
        updater.startAutomaticChecks()

        if let done = UpdateMarker.take() {
            pendingCompletedUpdate = done
        }

        let startHidden = launchedAtLogin || CommandLine.arguments.contains("--background")
        if startHidden {
            NSApp.setActivationPolicy(.accessory)
        } else {
            showMainWindow()
        }
        // macOS can bring back SwiftUI's own (empty) Settings window, even a while after launch: keep closing it.
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.closeStrayWindows() }
        }
    }

    private func closeStrayWindows() {
        let ours: [NSWindow?] = [mainWindow, settingsWindow, aiWindow] + liveWindows.map { $0.window }
        for window in NSApp.windows where window.isVisible && window.styleMask.contains(.titled) && !(window is NSPanel) {
            if !ours.contains(where: { $0 === window }) { window.close() }
        }
    }

    /// Opened straight from the DMG: offer to copy itself to Applications (needed for background running and updates).
    private func offerMoveToApplications() -> Bool {
        let source = Bundle.main.bundleURL
        guard source.path.hasPrefix("/Volumes/") else { return false }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Move TP Classroom to Applications?"
        alert.informativeText = "TP Classroom needs to be in the Applications folder to keep running in the background and to update itself."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        // Without an admin account /Applications is read-only, so use the Applications folder in your home folder.
        let fm = FileManager.default
        var folder = URL(fileURLWithPath: "/Applications")
        if !fm.isWritableFile(atPath: folder.path) {
            folder = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        }
        let destination = folder.appendingPathComponent(source.lastPathComponent)
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            let failed = NSAlert()
            failed.messageText = "Couldn't move TP Classroom"
            failed.informativeText = "Drag TP Classroom into the Applications folder yourself, then open it from there.\n\n\(error.localizedDescription)"
            failed.runModal()
            return false
        }
        MacAppInstaller.relaunch(bundleURL: destination, launchAgentLabel: "", inBackground: false)
        return true
    }

    /// ⌘Q and "Quit" keep TP Classroom running in the menu bar. Only "Quit Completely",
    /// logging out, shutting down or an update really quit it.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if AppLifecycle.allowQuit { return .terminateNow }
        moveToBackground()
        return .terminateCancel
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    // MARK: - Windows

    func showMainWindow() {
        guard let model, let updater else { return }
        // Opening the window is a good moment to look for a new version (at most every 5 minutes).
        if updater.lastChecked.map({ Date().timeIntervalSince($0) > 300 }) ?? true {
            Task { await updater.check() }
        }
        NSApp.setActivationPolicy(.regular)
        if mainWindow == nil {
            let root = ContentView()
                .environmentObject(model)
                .environmentObject(updater)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "TP Classroom"
            window.contentView = NSHostingView(rootView: root)
            window.contentMinSize = NSSize(width: 820, height: 520)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            window.setFrameAutosaveName("TPClassroomMainWindow")
            mainWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)

        if let done = pendingCompletedUpdate {
            pendingCompletedUpdate = nil
            let alert = NSAlert()
            alert.messageText = "Update completed"
            if let notes = done.notes {
                alert.informativeText = "TP Classroom is now version \(done.version).\n\nWhat's new:\n\(notes)"
            } else {
                alert.informativeText = "TP Classroom is now version \(done.version). Your students get the same version automatically."
            }
            alert.runModal()
        }
    }

    func openLiveWindow(for session: StudentSession) {
        guard let model else { return }
        if let existing = liveWindows.first(where: { $0.session === session }) {
            existing.window.makeKeyAndOrderFront(nil)
            return
        }
        let root = LiveSessionView(session: session).environmentObject(model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 740),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = session.name
        window.contentView = NSHostingView(rootView: root)
        window.contentMinSize = NSSize(width: 640, height: 440)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        liveWindows.append((session, window))
        session.openLiveView()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func showSettings() {
        guard let model, let updater else { return }
        if settingsWindow == nil {
            let root = SettingsView()
                .environmentObject(model)
                .environmentObject(updater)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 380),
                                  styleMask: [.titled, .closable],
                                  backing: .buffered, defer: false)
            window.title = "TP Classroom Settings"
            window.contentView = NSHostingView(rootView: root)
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func showAIWindow() {
        guard let assistant else { return }
        if aiWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 640),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "TP AI"
            window.contentView = NSHostingView(rootView: AIView(assistant: assistant))
            window.isReleasedWhenClosed = false
            window.center()
            window.setFrameAutosaveName("TPClassroomAIWindow")
            aiWindow = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        aiWindow?.makeKeyAndOrderFront(nil)
    }

    func checkForUpdates() {
        guard let updater else { return }
        Task { await updater.check(userInitiated: true) }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if let index = liveWindows.firstIndex(where: { $0.window === window }) {
            let entry = liveWindows.remove(at: index)
            entry.session.closeLiveView()
            window.contentView = nil
            // A postponed update may install now.
            if liveWindows.isEmpty, let updater, updater.hasPendingUpdate {
                Task { await updater.installIfAllowed() }
            }
        }
        if window === mainWindow && liveWindows.isEmpty {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private func moveToBackground() {
        let tipKey = "TPClassroomBackgroundTipShown"
        if !UserDefaults.standard.bool(forKey: tipKey) {
            UserDefaults.standard.set(true, forKey: tipKey)
            let alert = NSAlert()
            alert.messageText = "TP Classroom keeps running"
            alert.informativeText = "It stays in the menu bar (the eye icon) so your students stay connected and remembered. To quit completely, click the eye icon → Quit TP Classroom Completely."
            alert.runModal()
        }
        for entry in liveWindows { entry.window.close() }
        settingsWindow?.orderOut(nil)
        aiWindow?.orderOut(nil)
        mainWindow?.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: - Menu bar icon

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "eye.circle", accessibilityDescription: "TP Classroom")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let model else { return }

        let summary = NSMenuItem(title: "TP Classroom \(AppInfo.version) — \(model.onlineCount) of \(model.sessions.count) online",
                                 action: nil, keyEquivalent: "")
        summary.isEnabled = false
        menu.addItem(summary)
        menu.addItem(.separator())
        menu.addItem(item("Open TP Classroom", #selector(openMainFromMenu)))
        menu.addItem(item("Ask TP AI…", #selector(openAIFromMenu)))
        menu.addItem(item("Lock All Screens", #selector(lockAllFromMenu)))
        menu.addItem(item("Unlock All Screens", #selector(unlockAllFromMenu)))
        menu.addItem(.separator())
        let login = item("Start at Login", #selector(toggleLoginItem))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(item("Check for Updates", #selector(checkUpdatesFromMenu)))
        menu.addItem(.separator())
        menu.addItem(item("Quit TP Classroom Completely", #selector(quitCompletely)))
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
        menuItem.target = self
        return menuItem
    }

    @objc private func openMainFromMenu() { showMainWindow() }
    @objc private func openAIFromMenu() { showAIWindow() }
    @objc private func lockAllFromMenu() { model?.lockAll(message: "Eyes on the teacher, please") }
    @objc private func unlockAllFromMenu() { model?.unlockAll() }
    @objc private func checkUpdatesFromMenu() { checkForUpdates() }

    @objc private func toggleLoginItem() {
        if SMAppService.mainApp.status == .enabled {
            try? SMAppService.mainApp.unregister()
        } else {
            try? SMAppService.mainApp.register()
        }
    }

    func quitCompletelyFromMenu() { quitCompletely() }

    @objc private func quitCompletely() {
        AppLifecycle.allowQuit = true
        NSApp.terminate(nil)
    }

    private func registerLoginItemTheFirstTime() {
        let key = "TPClassroomLoginItemRegistered"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        try? SMAppService.mainApp.register()
    }
}
