import AppKit
import Network
import ApplicationServices
import CoreGraphics
import CryptoKit
import ServiceManagement
import ClassroomKit

/// One connected teacher app.
@MainActor
final class TeacherClient {
    let connection: SecureConnection
    var name = "Teacher"
    var os = "mac"
    var greeted = false
    var stream: StreamSettings?
    var controlEnabled = false
    var lockedScreen = false

    // Frame sending: drop frames instead of queueing them, so the view stays live.
    var isSending = false
    var sentFrameNumber = -1
    var lastSendTime = Date.distantPast
    var flushScheduled = false

    // An update arriving from this teacher.
    var incomingInfo: PackageInfo?
    var incomingData = Data()

    init(connection: SecureConnection) {
        self.connection = connection
    }
}

/// The brain of the student app: announces itself, accepts teachers, streams the screen,
/// performs remote input and classroom commands, and installs updates from the teacher.
@MainActor
final class StudentAgent: ObservableObject {
    static let shared = StudentAgent()

    @Published private(set) var teacherNames: [String] = []
    @Published private(set) var isBeingViewed = false
    @Published private(set) var isBeingControlled = false
    @Published private(set) var networkStatus = "Starting…"
    @Published private(set) var updateStatus: String? = nil
    @Published private(set) var hasScreenRecording = CGPreflightScreenCaptureAccess()
    @Published private(set) var hasAccessibility = AXIsProcessTrusted()

    let config: StudentConfigStore

    private var listener: NWListener?
    private var listeningPort: UInt16 = ClassroomPorts.tcp
    private var listenerRetry: Task<Void, Never>?
    private var classKey: SymmetricKey?
    private var classTag: String?
    private var clients: [ObjectIdentifier: TeacherClient] = [:]

    private let discovery = UDPDiscovery()
    private var discoveryStarted = false
    private var beaconTimer: Timer?
    private let capturer = ScreenCapturer()
    private let injector = InputInjector()
    private let lockScreen: LockScreenController
    private let banner: BannerController
    private let messages: MessageWindowController
    private let setupWindow: SetupWindowController

    private var activeCapture: StreamSettings?
    private var captureChain: Task<Void, Never>?
    private var lastFrame: Data?
    private var frameNumber = 0
    private var permissionTimer: Timer?
    private var autoUnlockTask: Task<Void, Never>?
    private var askedForScreenAccess = false
    private var isUpdating = false
    private var verifiedUpdate: (data: Data, info: PackageInfo)?

    private init() {
        config = StudentConfigStore()
        lockScreen = LockScreenController()
        banner = BannerController()
        messages = MessageWindowController()
        setupWindow = SetupWindowController()
    }

    var statusLine: String {
        if config.classCode == nil { return "Not set up yet" }
        if teacherNames.isEmpty { return networkStatus }
        return "Connected to " + teacherNames.joined(separator: ", ")
    }

    // MARK: - Launch

    func launch() {
        capturer.frameHandler = { [weak self] jpeg in
            DispatchQueue.main.async { self?.broadcast(jpeg) }
        }
        capturer.stopHandler = { [weak self] in
            DispatchQueue.main.async { self?.captureStoppedUnexpectedly() }
        }
        lockScreen.verifyPIN = { [weak self] pin in
            self?.adminUnlock(pin: pin) ?? false
        }
        if let done = UpdateMarker.take() {
            banner.flash("Update completed: TP Classroom Student \(done.version)")
        }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.refreshPermissions() }
        }
        beaconTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.sendBeacon() }
        }

        if config.classCode == nil {
            showSetup()
        } else {
            startListening()
        }
    }

    // MARK: - Discovery (so the teacher finds this Mac without typing an IP address)

    private func startDiscoveryIfNeeded() {
        guard !discoveryStarted else { return }
        discovery.onPacket = { [weak self] packet, _ in
            guard packet.kind == "probe" else { return }
            let tag = packet.classTag
            DispatchQueue.main.async { self?.handleProbe(classTag: tag) }
        }
        do {
            try discovery.start()
            discoveryStarted = true
        } catch {
            networkStatus = "Discovery port 52801 is busy: \(error.localizedDescription)"
        }
    }

    private func handleProbe(classTag tag: String) {
        guard tag == classTag else { return }
        sendBeacon()
    }

    private func sendBeacon() {
        guard discoveryStarted, let tag = classTag, listener != nil else { return }
        var packet = DiscoveryPacket(kind: "student", classTag: tag)
        packet.id = AppInfo.deviceID
        packet.name = config.displayName
        packet.user = NSFullUserName()
        packet.os = "mac"
        packet.version = AppInfo.version
        packet.port = Int(listeningPort)
        discovery.broadcast(packet)
    }

    // MARK: - Listening for teachers

    func startListening() {
        stopListening()
        guard let code = config.classCode else {
            networkStatus = "Not set up yet"
            return
        }
        classKey = ClassCrypto.key(for: code)
        classTag = ClassCrypto.tag(for: code)
        startDiscoveryIfNeeded()
        openListener(preferredPort: ClassroomPorts.tcp)
    }

    private func stopListening() {
        listenerRetry?.cancel()
        listenerRetry = nil
        if let listener {
            listener.stateUpdateHandler = nil
            listener.newConnectionHandler = nil
            listener.cancel()
        }
        listener = nil
        for key in Array(clients.keys) { drop(key) }
    }

    private func openListener(preferredPort: UInt16?) {
        let parameters = ClassroomNetwork.tcpParameters()
        parameters.allowLocalEndpointReuse = true
        let newListener: NWListener
        do {
            if let preferredPort, let port = NWEndpoint.Port(rawValue: preferredPort) {
                newListener = try NWListener(using: parameters, on: port)
            } else {
                newListener = try NWListener(using: parameters)
            }
        } catch {
            if preferredPort != nil {
                openListener(preferredPort: nil)
            } else {
                networkStatus = "Network problem: \(error.localizedDescription)"
                retryListeningLater()
            }
            return
        }

        newListener.stateUpdateHandler = { [weak self, weak newListener] state in
            DispatchQueue.main.async {
                guard let self, let newListener, self.listener === newListener else { return }
                switch state {
                case .ready:
                    self.listeningPort = newListener.port?.rawValue ?? ClassroomPorts.tcp
                    self.networkStatus = "Waiting for the teacher…"
                    self.sendBeacon()
                case .waiting(let error):
                    self.networkStatus = "Waiting for network: \(error.localizedDescription)"
                case .failed(let error):
                    newListener.cancel()
                    self.listener = nil
                    if preferredPort != nil {
                        // Port busy (e.g. two users logged in): use any free port; discovery tells the teacher.
                        self.openListener(preferredPort: nil)
                    } else {
                        self.networkStatus = "Network problem: \(error.localizedDescription)"
                        self.retryListeningLater()
                    }
                default:
                    break
                }
            }
        }
        newListener.newConnectionHandler = { [weak self] connection in
            DispatchQueue.main.async { self?.accept(connection) }
        }
        listener = newListener
        newListener.start(queue: .global(qos: .userInitiated))
    }

    private func retryListeningLater() {
        listenerRetry?.cancel()
        listenerRetry = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled else { return }
            self?.startListening()
        }
    }

    private func accept(_ networkConnection: NWConnection) {
        guard let key = classKey else {
            networkConnection.cancel()
            return
        }
        let connection = SecureConnection(connection: networkConnection, role: .student, classKey: key)
        let client = TeacherClient(connection: connection)
        let id = ObjectIdentifier(client)
        clients[id] = client

        connection.onMessage = { [weak self] message in
            self?.handle(message, from: client)
        }
        connection.onChunk = { [weak self] bytes in
            self?.receiveChunk(bytes, from: client)
        }
        connection.onClose = { [weak self] _ in
            self?.drop(id)
        }
        connection.start()
    }

    private func drop(_ id: ObjectIdentifier) {
        guard let client = clients.removeValue(forKey: id) else { return }
        client.connection.onMessage = nil
        client.connection.onChunk = nil
        client.connection.onClose = nil
        client.connection.cancel()
        if client.incomingInfo != nil {
            isUpdating = false
            updateStatus = nil
        }
        if client.lockedScreen && lockScreen.isLocked {
            scheduleAutoUnlock()
        }
        reconfigureCapture()
        refreshState()
    }

    // MARK: - Commands from the teacher

    private func handle(_ message: Message, from client: TeacherClient) {
        if message.type == "hello" {
            client.name = (message.name ?? "").isEmpty ? "Teacher" : (message.name ?? "Teacher")
            client.os = message.os ?? "mac"
            client.greeted = true
            client.connection.send(makeInfo())
            banner.flash("\(client.name) connected. Your teacher can see this screen during class.")
            refreshState()
            return
        }
        guard client.greeted else { return }

        switch message.type {
        case "stream":
            client.stream = message.streamSettings
            client.sentFrameNumber = -1
            client.lastSendTime = .distantPast
            reconfigureCapture()
            pump(client)
            refreshState()

        case "stopStream":
            client.stream = nil
            reconfigureCapture()
            refreshState()

        case "control":
            client.controlEnabled = message.enabled ?? false
            if client.controlEnabled && !AXIsProcessTrusted() {
                client.connection.send(.notice("Remote control isn't allowed on this Mac yet (Accessibility permission)."))
            }
            refreshState()
            installVerifiedUpdateIfPossible()

        case "input":
            guard client.controlEnabled, var event = message.input else { return }
            if client.os != "mac" {
                if let code = event.code { event.code = KeyCodes.swapMetaAndControl(code) }
                if let mods = event.mods { event.mods = KeyCodes.swapMetaAndControl(mods: mods) }
            }
            injector.post(event)

        case "typeText":
            guard client.controlEnabled, let text = message.text else { return }
            injector.typeText(text)

        case "power":
            powerOff(restart: message.action == "restart", by: client.name)

        case "lock":
            client.lockedScreen = true
            autoUnlockTask?.cancel()
            lockScreen.lock(message: message.text ?? "", teacher: client.name, allowAdminUnlock: config.hasPIN)
            sendInfoToAll()

        case "unlock":
            for other in clients.values { other.lockedScreen = false }
            autoUnlockTask?.cancel()
            lockScreen.unlock()
            sendInfoToAll()
            installVerifiedUpdateIfPossible()

        case "message":
            messages.show(text: message.text ?? "", from: client.name)

        case "openUrl":
            guard let text = message.url, let url = URL(string: text),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { return }
            NSWorkspace.shared.open(url)

        case "updateBegin":
            beginUpdate(message, from: client)

        case "updateEnd":
            finishUpdate(from: client)

        default:
            break
        }
    }

    /// If the teacher's app disappears while the screen is locked, unlock after a while
    /// so a student is never stuck. A reconnecting teacher re-locks right away.
    private func scheduleAutoUnlock() {
        autoUnlockTask?.cancel()
        autoUnlockTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 45_000_000_000)
            guard !Task.isCancelled, let self else { return }
            if !self.clients.values.contains(where: { $0.lockedScreen }) {
                self.lockScreen.unlock()
                self.sendInfoToAll()
                self.installVerifiedUpdateIfPossible()
            }
        }
    }

    private func adminUnlock(pin: String) -> Bool {
        guard config.hasPIN, config.verify(pin: pin) else { return false }
        for client in clients.values { client.lockedScreen = false }
        lockScreen.unlock()
        sendInfoToAll()
        installVerifiedUpdateIfPossible()
        return true
    }

    // MARK: - Shut down / restart (asked by the teacher)

    private var powerTask: Task<Void, Never>?

    /// Warns for 15 seconds, then shuts down or restarts. Uses the rule install-student.sh adds
    /// (`sudo -n /sbin/shutdown`), and falls back to asking macOS directly.
    private func powerOff(restart: Bool, by teacher: String) {
        guard powerTask == nil else { return }
        let verb = restart ? "restarting" : "shutting down"
        banner.flash("\(teacher) is \(verb) this Mac in 15 seconds. Save your work!", seconds: 15)
        powerTask = Task {
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            let flag = restart ? "-r" : "-h"
            let ok = await Task.detached { () -> Bool in
                let sudo = Process()
                sudo.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
                sudo.arguments = ["-n", "/sbin/shutdown", flag, "now"]
                if (try? sudo.run()) != nil {
                    sudo.waitUntilExit()
                    if sudo.terminationStatus == 0 { return true }
                }
                // Fallback: ask the login window (like choosing Shut Down from the Apple menu).
                let script = Process()
                script.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                script.arguments = ["-e", restart ? "tell application \"loginwindow\" to «event aevtrest»"
                                                  : "tell application \"loginwindow\" to «event aevtshut»"]
                if (try? script.run()) != nil {
                    script.waitUntilExit()
                    return script.terminationStatus == 0
                }
                return false
            }.value
            if !ok {
                self.notifyAll("This Mac couldn't \(restart ? "restart" : "shut down") by itself. Reinstall it with \"Install for All Users\".")
                self.powerTask = nil
            }
        }
    }

    // MARK: - Updates from the teacher (works offline, keeps versions the same)

    private func beginUpdate(_ message: Message, from client: TeacherClient) {
        guard message.platform == "mac",
              let version = message.version, let sha = message.sha256,
              let signature = message.signature, let size = message.size,
              Versions.isNewer(version, than: AppInfo.version),
              size > 0, size < 500_000_000,
              !isUpdating, verifiedUpdate == nil else { return }
        isUpdating = true
        client.incomingInfo = PackageInfo(platform: "mac", version: version, sha256: sha, signature: signature, size: size)
        client.incomingData = Data()
        client.incomingData.reserveCapacity(size)
        updateStatus = "Updating to version \(version)…"
    }

    private func receiveChunk(_ bytes: Data, from client: TeacherClient) {
        guard let info = client.incomingInfo else { return }
        client.incomingData.append(bytes)
        if client.incomingData.count > (info.size ?? 0) {
            client.incomingInfo = nil
            client.incomingData = Data()
            isUpdating = false
            updateStatus = nil
        }
    }

    private func finishUpdate(from client: TeacherClient) {
        guard let info = client.incomingInfo else { return }
        let data = client.incomingData
        client.incomingInfo = nil
        client.incomingData = Data()
        do {
            guard data.count == info.size else { throw PackageError.badChecksum }
            try PackageVerifier.verify(data, sha256: info.sha256, signature: info.signature)
        } catch {
            isUpdating = false
            updateStatus = nil
            client.connection.send(.notice("Update failed on this Mac: \(error.localizedDescription)"))
            return
        }
        verifiedUpdate = (data, info)
        installVerifiedUpdateIfPossible()
    }

    /// Installs right away, unless the screen is locked or being controlled (then it waits).
    private func installVerifiedUpdateIfPossible() {
        guard let update = verifiedUpdate, !lockScreen.isLocked, !isBeingControlled else { return }
        verifiedUpdate = nil
        let bundleURL = Bundle.main.bundleURL
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let zip = update.data
        let version = update.info.version
        updateStatus = "Installing version \(version)…"
        Task { [weak self] in
            do {
                try await Task.detached(priority: .userInitiated) {
                    try MacAppInstaller.install(zip: zip, bundleURL: bundleURL, expectedBundleID: bundleID)
                }.value
                UpdateMarker.set(version: version, notes: nil)
                MacAppInstaller.relaunch(bundleURL: bundleURL, launchAgentLabel: bundleID, inBackground: true)
            } catch {
                self?.isUpdating = false
                self?.updateStatus = nil
                self?.notifyAll("Update failed on this Mac: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Screen streaming

    private func reconfigureCapture() {
        let streams = clients.values.compactMap { $0.greeted ? $0.stream : nil }
        let desired: StreamSettings? = streams.isEmpty ? nil : StreamSettings(
            fps: streams.map(\.fps).max() ?? 1,
            maxWidth: streams.map(\.maxWidth).max() ?? 480,
            quality: streams.map(\.quality).max() ?? 0.5,
            live: streams.contains { $0.live }
        )
        guard desired != activeCapture else { return }
        activeCapture = desired

        if desired != nil && !CGPreflightScreenCaptureAccess() {
            if !askedForScreenAccess {
                askedForScreenAccess = true
                _ = CGRequestScreenCaptureAccess()
            }
            notifyAll("Screen Recording isn't allowed on this Mac yet, so its screen can't be shown.")
        }

        let previous = captureChain
        let capturer = self.capturer
        captureChain = Task { [weak self] in
            await previous?.value
            do {
                if let desired {
                    try await capturer.apply(desired)
                } else {
                    await capturer.stop()
                }
            } catch {
                self?.activeCapture = nil
                self?.notifyAll("Couldn't capture the screen: \(error.localizedDescription)")
            }
        }
    }

    private func captureStoppedUnexpectedly() {
        activeCapture = nil
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self?.reconfigureCapture()
        }
    }

    private func broadcast(_ jpeg: Data) {
        frameNumber += 1
        lastFrame = jpeg
        for client in clients.values { pump(client) }
    }

    /// Sends the newest frame to one teacher at their frame rate, never queueing old frames.
    private func pump(_ client: TeacherClient) {
        guard client.greeted, let settings = client.stream, !client.isSending,
              let frame = lastFrame, client.sentFrameNumber != frameNumber else { return }

        let interval = 1.0 / Double(max(settings.fps, 1))
        let wait = interval - Date().timeIntervalSince(client.lastSendTime)
        if wait > 0.005 {
            guard !client.flushScheduled else { return }
            client.flushScheduled = true
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                client.flushScheduled = false
                self?.pump(client)
            }
            return
        }

        client.isSending = true
        client.sentFrameNumber = frameNumber
        client.lastSendTime = Date()
        client.connection.sendFrame(frame) { [weak self] _ in
            DispatchQueue.main.async {
                client.isSending = false
                self?.pump(client)
            }
        }
    }

    // MARK: - State shown to the student and the teacher

    private func refreshState() {
        let ready = clients.values.filter { $0.greeted }
        teacherNames = Array(Set(ready.map { $0.name })).sorted()
        isBeingViewed = ready.contains { $0.stream != nil }
        isBeingControlled = ready.contains { $0.controlEnabled }
        let watchingLive = ready.contains { $0.stream?.live == true }

        if isBeingControlled {
            banner.setPersistent("Your teacher is controlling this Mac", style: .controlling)
        } else if watchingLive {
            banner.setPersistent("Your teacher is viewing your screen", style: .viewing)
        } else {
            banner.setPersistent(nil)
        }
    }

    private func makeInfo() -> Message {
        var info = Message(type: "info")
        info.id = AppInfo.deviceID
        info.name = config.displayName
        info.user = NSFullUserName()
        info.computer = AppInfo.computerName
        info.os = "mac"
        info.version = AppInfo.version
        info.screenOk = CGPreflightScreenCaptureAccess()
        info.controlOk = AXIsProcessTrusted()
        info.locked = lockScreen.isLocked
        return info
    }

    private func sendInfoToAll() {
        let info = makeInfo()
        for client in clients.values where client.greeted {
            client.connection.send(info)
        }
    }

    private func notifyAll(_ text: String) {
        for client in clients.values where client.greeted {
            client.connection.send(.notice(text))
        }
    }

    private func refreshPermissions() {
        let screen = CGPreflightScreenCaptureAccess()
        let accessibility = AXIsProcessTrusted()
        guard screen != hasScreenRecording || accessibility != hasAccessibility else { return }
        hasScreenRecording = screen
        hasAccessibility = accessibility
        sendInfoToAll()
        if screen {
            activeCapture = nil
            reconfigureCapture()
        }
    }

    // MARK: - Menu actions

    func openScreenRecordingSettings() {
        _ = CGRequestScreenCaptureAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func openAccessibilitySettings() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func showSetup() {
        setupWindow.show(store: config, agent: self) { [weak self] in
            self?.registerLoginItemIfNeeded()
            self?.startListening()
        }
    }

    func openSettingsAskingPIN() {
        if askForPIN("Enter the admin PIN to change TP Classroom settings.") {
            showSetup()
        }
    }

    /// Admin only: stops the app until the next login.
    func stopAskingPIN() {
        guard askForPIN("Enter the admin PIN to stop TP Classroom Student until the next login.") else { return }
        AppLifecycle.allowQuit = true
        if let label = Bundle.main.bundleIdentifier {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["bootout", "gui/\(getuid())/\(label)"]
            try? process.run()
            process.waitUntilExit()
        }
        NSApp.terminate(nil)
    }

    private func askForPIN(_ reason: String) -> Bool {
        guard config.hasPIN else { return true }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Admin PIN required"
        alert.informativeText = reason
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        if config.verify(pin: field.stringValue) { return true }
        let wrong = NSAlert()
        wrong.messageText = "Wrong PIN"
        wrong.runModal()
        return false
    }

    /// True when opened straight from the DMG (it must be installed before it can be used).
    var isRunningFromDiskImage: Bool {
        Bundle.main.bundlePath.hasPrefix("/Volumes/")
    }

    /// Installs for every account on this Mac (asks for an administrator password):
    /// copies the app to /Applications, starts it at every login, keeps it running and lets the
    /// teacher update it. Runs install-student.sh, which is inside the app.
    func installForAllUsers(code: String, pin: String, completion: @escaping @MainActor (String?) -> Void) {
        guard let script = Bundle.main.url(forResource: "install-student", withExtension: "sh") else {
            completion("The installer is missing from this copy of the app.")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e", "on run argv",
            "-e", "do shell script (\"APP_SOURCE=\" & quoted form of item 4 of argv & \" /bin/bash \" & quoted form of item 1 of argv & \" \" & quoted form of item 2 of argv & \" \" & quoted form of item 3 of argv) with administrator privileges",
            "-e", "end run",
            script.path, code, pin, Bundle.main.bundlePath,
        ]
        Task {
            let status: Int32 = await Task.detached(priority: .userInitiated) {
                do {
                    try process.run()
                    process.waitUntilExit()
                    return process.terminationStatus
                } catch {
                    return -1
                }
            }.value
            // On success the installed copy starts by itself (this copy is usually stopped by then).
            completion(status == 0 ? nil : "The installation was cancelled or didn't finish.")
        }
    }

    /// Start automatically at login (when not already set up by install-student.sh).
    private func registerLoginItemIfNeeded() {
        guard !config.isManaged else { return }
        if SMAppService.mainApp.status != .enabled {
            try? SMAppService.mainApp.register()
        }
    }
}
