import Foundation
import AppKit
import CryptoKit
import ClassroomKit

enum LiveQuality: String, CaseIterable, Identifiable {
    case smooth
    case balanced
    case sharp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .smooth: return "Smooth (faster, softer picture)"
        case .balanced: return "Balanced"
        case .sharp: return "Best (sharpest, needs a fast network)"
        }
    }

    var settings: StreamSettings {
        switch self {
        case .smooth: return StreamSettings(fps: 15, maxWidth: 1280, quality: 0.5, live: true)
        case .balanced: return StreamSettings(fps: 12, maxWidth: 1680, quality: 0.6, live: true)
        case .sharp: return StreamSettings(fps: 15, maxWidth: 2880, quality: 0.85, live: true)
        }
    }
}

/// Things the teacher types into a small sheet before they're sent.
enum Prompt: Identifiable {
    case lockAll
    case messageAll
    case openURLAll
    case addHost
    case lock(String)
    case message(String)
    case openURL(String)

    var id: String {
        switch self {
        case .lockAll: return "lockAll"
        case .messageAll: return "messageAll"
        case .openURLAll: return "openURLAll"
        case .addHost: return "addHost"
        case .lock(let id): return "lock:" + id
        case .message(let id): return "message:" + id
        case .openURL(let id): return "openURL:" + id
        }
    }

    var title: String {
        switch self {
        case .lockAll: return "Lock every student screen"
        case .lock: return "Lock this student's screen"
        case .messageAll: return "Send a message to every student"
        case .message: return "Send a message"
        case .openURLAll: return "Open a website on every student computer"
        case .openURL: return "Open a website on this computer"
        case .addHost: return "Connect to a computer by its address (only if it doesn't appear by itself)"
        }
    }

    var placeholder: String {
        switch self {
        case .lockAll, .lock: return "Message on the lock screen"
        case .messageAll, .message: return "Type your message"
        case .openURLAll, .openURL: return "example.com"
        case .addHost: return "192.168.1.25"
        }
    }

    var defaultText: String {
        switch self {
        case .lockAll, .lock: return "Eyes on the teacher, please"
        default: return ""
        }
    }

    var actionTitle: String {
        switch self {
        case .lockAll, .lock: return "Lock"
        case .messageAll, .message: return "Send"
        case .openURLAll, .openURL: return "Open"
        case .addHost: return "Connect"
        }
    }

    var allowsEmpty: Bool {
        switch self {
        case .lockAll, .lock: return true
        default: return false
        }
    }
}

/// A student app built into this teacher app, ready to send to students over the local network.
struct StudentPackage {
    let info: PackageInfo
    let fileURL: URL

    /// Packages are put inside the teacher app by scripts/build.sh, always the same version as the teacher.
    static func bundled(for os: String) -> StudentPackage? {
        guard let folder = Bundle.main.resourceURL?.appendingPathComponent("Packages", isDirectory: true) else {
            return nil
        }
        let file = os == "windows" ? "TPClassroom.exe" : "student-mac.zip"
        let fileURL = folder.appendingPathComponent(file)
        let infoURL = folder.appendingPathComponent(file + ".json")
        guard let data = try? Data(contentsOf: infoURL),
              let info = try? JSONDecoder().decode(PackageInfo.self, from: data),
              info.version == AppInfo.version,
              FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return StudentPackage(info: info, fileURL: fileURL)
    }
}

/// Finds student computers by itself, remembers them, keeps a connection to each and runs class-wide actions.
@MainActor
final class ClassroomModel: ObservableObject {
    private enum Keys {
        static let classCode = "classCode"
        static let teacherName = "teacherName"
        static let liveQuality = "liveQuality"
        static let roster = "roster"
    }

    @Published private(set) var sessions: [StudentSession] = []
    @Published private(set) var classCode: String
    @Published private(set) var discoveryStatus = ""
    @Published var teacherName: String {
        didSet { UserDefaults.standard.set(teacherName, forKey: Keys.teacherName) }
    }
    @Published var liveQuality: LiveQuality {
        didSet {
            UserDefaults.standard.set(liveQuality.rawValue, forKey: Keys.liveQuality)
            for session in sessions { session.refreshStream() }
        }
    }

    let updater: Updater
    private(set) var classKey: SymmetricKey?
    private var classTag: String?
    private let discovery = UDPDiscovery()
    private var discoveryStarted = false
    private var probeTimer: Timer?
    private var reconnectTimer: Timer?
    private var started = false

    /// Set by the app delegate: opens a live window for a student.
    var onOpenLive: (@MainActor (StudentSession) -> Void)?
    /// Set by the app delegate: opens the TP AI window.
    var onOpenAI: (@MainActor () -> Void)?

    init(updater: Updater) {
        self.updater = updater
        let defaults = UserDefaults.standard
        classCode = ClassCrypto.normalize(defaults.string(forKey: Keys.classCode) ?? "")
        teacherName = defaults.string(forKey: Keys.teacherName) ?? NSFullUserName()
        liveQuality = LiveQuality(rawValue: defaults.string(forKey: Keys.liveQuality) ?? "") ?? .sharp

        // Remembered computers come back after quitting or restarting.
        if let data = defaults.data(forKey: Keys.roster),
           let roster = try? JSONDecoder().decode([KnownStudent].self, from: data) {
            sessions = roster.map { StudentSession(known: $0, model: self) }
            sortSessions()
        }
    }

    var onlineCount: Int {
        sessions.filter { $0.isOnline }.count
    }

    func session(id: String) -> StudentSession? {
        sessions.first { $0.id == id }
    }

    // MARK: - Starting

    func start() {
        guard !started else { return }
        guard !classCode.isEmpty else {
            discoveryStatus = "Choose a class code to begin."
            return
        }
        started = true
        classKey = ClassCrypto.key(for: classCode)
        classTag = ClassCrypto.tag(for: classCode)
        startDiscovery()

        // Try every remembered computer at its last address right away.
        for session in sessions { session.connectIfIdle() }

        probeTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.sendProbe() }
        }
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.reconnectIdleSessions() }
        }
        sendProbe()
    }

    func setClassCode(_ code: String) {
        let normalized = ClassCrypto.normalize(code)
        guard !normalized.isEmpty, normalized != classCode else { return }
        classCode = normalized
        UserDefaults.standard.set(normalized, forKey: Keys.classCode)
        // New class: reconnect everyone with the new key.
        for session in sessions { session.disconnect() }
        started = false
        probeTimer?.invalidate()
        reconnectTimer?.invalidate()
        start()
    }

    func reconnectAll() {
        for session in sessions {
            session.disconnect()
            session.connect()
        }
        sendProbe()
    }

    nonisolated static func randomCode() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<8).map { _ in alphabet.randomElement()! })
    }

    // MARK: - Discovery

    private func startDiscovery() {
        guard !discoveryStarted else { return }
        discovery.onPacket = { [weak self] packet, ip in
            guard packet.kind == "student" else { return }
            DispatchQueue.main.async { self?.handleBeacon(packet, from: ip) }
        }
        do {
            try discovery.start()
            discoveryStarted = true
            discoveryStatus = "Looking for student computers on this network…"
        } catch {
            discoveryStatus = "Can't listen for students (port 52801 busy): \(error.localizedDescription)"
        }
    }

    private func sendProbe() {
        guard discoveryStarted, let tag = classTag else { return }
        let probe = DiscoveryPacket(kind: "probe", classTag: tag)
        discovery.broadcast(probe)
        // Also ask remembered computers directly, in case broadcasts are blocked.
        for session in sessions where !session.isOnline && !session.host.isEmpty {
            discovery.send(probe, to: session.host)
        }
    }

    private func reconnectIdleSessions() {
        for session in sessions { session.connectIfIdle() }
    }

    private func handleBeacon(_ packet: DiscoveryPacket, from ip: String) {
        guard packet.classTag == classTag, let id = packet.id, !id.isEmpty else { return }
        if let existing = session(id: id) {
            existing.updateFromBeacon(packet, host: ip)
            existing.connectIfIdle()
        } else {
            let known = KnownStudent(id: id, name: packet.name ?? ip, user: packet.user ?? "", os: packet.os ?? "mac",
                                     version: packet.version ?? "", host: ip,
                                     port: UInt16(clamping: packet.port ?? Int(ClassroomPorts.tcp)), lastSeen: Date())
            let session = StudentSession(known: known, model: self)
            sessions.append(session)
            sortSessions()
            saveRoster()
            session.connect()
        }
    }

    /// Fallback when broadcasts are blocked on the network: connect to an address once,
    /// after that the computer is remembered like any other.
    func addManualHost(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        var host = text
        var port = ClassroomPorts.tcp
        let parts = text.split(separator: ":")
        if parts.count == 2, let customPort = UInt16(parts[1]) {
            host = String(parts[0])
            port = customPort
        }
        if let existing = sessions.first(where: { $0.host == host }) {
            existing.connect()
            return
        }
        let known = KnownStudent(id: "address:" + host, name: host, user: "", os: "mac", version: "",
                                 host: host, port: port, lastSeen: Date())
        let session = StudentSession(known: known, model: self)
        sessions.append(session)
        sortSessions()
        session.connect()
    }

    // MARK: - Remembering students

    func sessionChanged() {
        objectWillChange.send()
    }

    /// A computer added by address told us its real ID: merge with a remembered entry.
    func studentChangedID(_ session: StudentSession, to newID: String) {
        if let duplicate = sessions.first(where: { $0.id == newID && $0 !== session }) {
            duplicate.disconnect()
            sessions.removeAll { $0 === duplicate }
        }
    }

    func studentInfoChanged(_ session: StudentSession) {
        sortSessions()
        saveRoster()
        keepVersionsTheSame(session)
    }

    func forget(_ session: StudentSession) {
        session.disconnect()
        sessions.removeAll { $0 === session }
        saveRoster()
    }

    private func sortSessions() {
        sessions.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func saveRoster() {
        let roster = sessions.filter { !$0.id.hasPrefix("address:") }.map { $0.known }
        if let data = try? JSONEncoder().encode(roster) {
            UserDefaults.standard.set(data, forKey: Keys.roster)
        }
    }

    // MARK: - Same version everywhere

    /// Older students get the teacher's version over the local network.
    /// If a student is newer, the teacher app updates itself.
    private func keepVersionsTheSame(_ session: StudentSession) {
        guard session.isOnline, !session.version.isEmpty else { return }
        if Versions.isNewer(AppInfo.version, than: session.version) {
            if let package = StudentPackage.bundled(for: session.os) {
                session.notice = nil
                session.sendUpdate(package)
            } else {
                let platform = session.isWindows ? "Windows" : "Mac"
                session.notice = "This computer has an older version, but this build of the teacher app doesn't include the \(platform) student app."
            }
        } else if Versions.isNewer(session.version, than: AppInfo.version) {
            session.notice = "This computer has a newer version (\(session.version)). The teacher app will update itself when it's online."
            Task { await updater.check() }
        }
    }

    // MARK: - Class-wide actions

    func lockAll(message: String) {
        for session in sessions { session.lock(message: message) }
    }

    func unlockAll() {
        for session in sessions { session.unlock() }
    }

    func messageAll(_ text: String) {
        for session in sessions where session.isOnline { session.send(.message(text)) }
    }

    func openURLAll(_ raw: String) {
        guard let url = Self.normalizeURL(raw) else { return }
        for session in sessions where session.isOnline { session.send(.openURL(url)) }
    }

    func perform(_ prompt: Prompt, value: String) {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch prompt {
        case .lockAll: lockAll(message: text)
        case .messageAll: messageAll(text)
        case .openURLAll: openURLAll(text)
        case .addHost: addManualHost(text)
        case .lock(let id): session(id: id)?.lock(message: text)
        case .message(let id): session(id: id)?.send(.message(text))
        case .openURL(let id):
            if let url = Self.normalizeURL(text) { session(id: id)?.send(.openURL(url)) }
        }
    }

    /// "google.com" → "https://google.com". Only web links are allowed.
    nonisolated static func normalizeURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: withScheme),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else { return nil }
        return url.absoluteString
    }
}
