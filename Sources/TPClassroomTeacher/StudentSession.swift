import Foundation
import Network
import CoreGraphics
import ImageIO
import CryptoKit
import ClassroomKit

/// A computer the teacher has seen before. Saved, so the class list survives quitting and restarting.
struct KnownStudent: Codable {
    var id: String
    var name: String
    var user: String
    var os: String
    var version: String
    var host: String
    var port: UInt16
    var lastSeen: Date
}

/// The teacher's connection to one student computer (Mac or Windows).
@MainActor
final class StudentSession: ObservableObject, Identifiable {
    enum Status: Equatable {
        case offline
        case connecting
        case online
        case error(String)
    }

    private(set) var id: String
    weak var model: ClassroomModel?

    @Published var name: String
    @Published private(set) var user: String
    @Published private(set) var os: String
    @Published private(set) var version: String
    @Published private(set) var status: Status = .offline {
        didSet { if status != oldValue { model?.sessionChanged() } }
    }
    @Published private(set) var screenOK = true
    @Published private(set) var controlOK = true
    @Published private(set) var lockedOnStudent = false
    @Published private(set) var frame: CGImage? = nil
    @Published private(set) var controlEnabled = false
    @Published var notice: String? = nil
    @Published private(set) var updateProgress: Double? = nil

    private(set) var host: String
    private(set) var port: UInt16
    private(set) var lastSeen: Date

    private var connection: SecureConnection?
    private var lockRequested = false
    private var lockMessage = ""
    private var liveViewers = 0
    private var sentStream: StreamSettings?
    private var nextAttempt = Date.distantPast
    private var retryDelay: TimeInterval = 2
    private var updateSentForVersion: String?

    init(known: KnownStudent, model: ClassroomModel) {
        id = known.id
        name = known.name
        user = known.user
        os = known.os
        version = known.version
        host = known.host
        port = known.port
        lastSeen = known.lastSeen
        self.model = model
    }

    var known: KnownStudent {
        KnownStudent(id: id, name: name, user: user, os: os, version: version, host: host, port: port, lastSeen: lastSeen)
    }

    // MARK: - Display helpers

    var isOnline: Bool { status == .online }
    var isLocked: Bool { isOnline ? lockedOnStudent : lockRequested }
    var isWindows: Bool { os == "windows" }

    var subtitle: String {
        var parts: [String] = []
        if !user.isEmpty { parts.append(user) }
        if !version.isEmpty { parts.append("v" + version) }
        switch status {
        case .online: break
        case .connecting: parts.append("Connecting…")
        case .offline: parts.append("Offline")
        case .error: parts.append("Can't connect")
        }
        return parts.joined(separator: " · ")
    }

    var warning: String? {
        if case .error(let message) = status { return message }
        if isOnline {
            if !screenOK {
                return isWindows ? "Can't capture this screen right now." : "Screen Recording isn't allowed on this Mac yet."
            }
            if !controlOK { return "Remote control isn't allowed on this Mac yet (Accessibility)." }
        }
        return notice
    }

    // MARK: - Connecting

    /// Remembers where the student was last seen (from its discovery announcement).
    func updateFromBeacon(_ packet: DiscoveryPacket, host newHost: String) {
        if let newName = packet.name, !newName.isEmpty { name = newName }
        if let newUser = packet.user { user = newUser }
        if let newOS = packet.os { os = newOS }
        if let newVersion = packet.version { version = newVersion }
        let newPort = UInt16(clamping: packet.port ?? Int(ClassroomPorts.tcp))
        if newHost != host || newPort != port {
            host = newHost
            port = newPort
            nextAttempt = .distantPast
            if status != .online { disconnect(keepStatus: true) }
        }
        lastSeen = Date()
    }

    /// Connects unless already connected or a recent attempt failed.
    func connectIfIdle() {
        guard status != .online, status != .connecting, Date() >= nextAttempt, !host.isEmpty else { return }
        connect()
    }

    func connect() {
        guard let model, let key = model.classKey, !host.isEmpty,
              let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        disconnect(keepStatus: true)
        status = .connecting
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)
        let networkConnection = NWConnection(to: endpoint, using: ClassroomNetwork.tcpParameters())
        let newConnection = SecureConnection(connection: networkConnection, role: .teacher, classKey: key)

        newConnection.onReady = { [weak self, weak newConnection] in
            guard let self, let newConnection, self.connection === newConnection else { return }
            newConnection.send(.hello(name: self.model?.teacherName ?? "Teacher"))
        }
        newConnection.onMessage = { [weak self, weak newConnection] message in
            guard let self, let newConnection, self.connection === newConnection else { return }
            self.handle(message)
        }
        newConnection.onFrame = { [weak self, weak newConnection] data in
            guard let self, let newConnection, self.connection === newConnection else { return }
            self.handleFrame(data)
        }
        newConnection.onClose = { [weak self, weak newConnection] reason in
            guard let self, let newConnection, self.connection === newConnection else { return }
            self.connectionClosed(reason)
        }
        connection = newConnection
        newConnection.start()
    }

    func disconnect(keepStatus: Bool = false) {
        if let current = connection {
            connection = nil
            current.onReady = nil
            current.onMessage = nil
            current.onFrame = nil
            current.onClose = nil
            current.cancel()
        }
        controlEnabled = false
        sentStream = nil
        updateProgress = nil
        if !keepStatus { status = .offline }
    }

    private func connectionClosed(_ reason: String?) {
        let wasOnline = status == .online
        disconnect(keepStatus: true)
        if let reason, !wasOnline {
            status = .error(reason)
        } else {
            status = .offline
        }
        nextAttempt = Date().addingTimeInterval(retryDelay)
        retryDelay = min(retryDelay * 2, 30)
    }

    // MARK: - Incoming

    private func handle(_ message: Message) {
        switch message.type {
        case "info":
            let wasOnline = status == .online
            if let newID = message.id, !newID.isEmpty, newID != id {
                model?.studentChangedID(self, to: newID)
                id = newID
            }
            if let value = message.name, !value.isEmpty { name = value }
            if let value = message.user { user = value }
            if let value = message.os { os = value }
            if let value = message.version { version = value }
            screenOK = message.screenOk ?? true
            controlOK = message.controlOk ?? true
            lockedOnStudent = message.locked ?? false
            lastSeen = Date()
            status = .online
            retryDelay = 2
            if !wasOnline {
                notice = nil
                sentStream = nil
                refreshStream()
                if lockRequested { connection?.send(.lock(lockMessage)) }
            }
            model?.studentInfoChanged(self)
        case "notice":
            notice = message.text
        default:
            break
        }
    }

    private func handleFrame(_ data: Data) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
        frame = image
    }

    // MARK: - Commands

    func send(_ message: Message) {
        guard isOnline else { return }
        connection?.send(message)
    }

    func openLiveView() {
        liveViewers += 1
        refreshStream()
    }

    func closeLiveView() {
        liveViewers = max(0, liveViewers - 1)
        if liveViewers == 0 && controlEnabled { setControl(false) }
        refreshStream()
    }

    /// Thumbnail stream normally; full live stream while a live window is open.
    func refreshStream() {
        guard isOnline else { return }
        let desired = liveViewers > 0 ? (model?.liveQuality.settings ?? StreamSettings.thumbnail) : StreamSettings.thumbnail
        guard desired != sentStream else { return }
        sentStream = desired
        connection?.send(.stream(desired))
    }

    func setControl(_ enabled: Bool) {
        controlEnabled = enabled && isOnline
        connection?.send(.control(controlEnabled))
    }

    func sendInput(_ event: InputEvent) {
        guard controlEnabled else { return }
        connection?.send(.remoteInput(event))
    }

    func lock(message: String) {
        lockRequested = true
        lockMessage = message
        connection?.send(.lock(message))
    }

    func unlock() {
        lockRequested = false
        connection?.send(Message(type: "unlock"))
    }

    // MARK: - Actions for TP AI

    /// Sends mouse/keyboard events even if Control is off: Control is switched on just for
    /// these events (the student sees the "controlling" banner), then back off.
    func performAIInput(_ events: [InputEvent]) {
        guard isOnline, let current = connection else { return }
        let wasOn = controlEnabled
        if !wasOn { current.send(.control(true)) }
        for event in events { current.send(.remoteInput(event)) }
        if !wasOn { current.send(.control(false)) }
    }

    func typeTextAsAI(_ text: String) {
        guard isOnline, let current = connection else { return }
        let wasOn = controlEnabled
        if !wasOn { current.send(.control(true)) }
        current.send(.typeText(text))
        if !wasOn { current.send(.control(false)) }
    }

    func power(_ action: String) {
        guard isOnline else { return }
        connection?.send(.power(action))
    }

    // MARK: - Pushing updates (same version as the teacher, works offline)

    func sendUpdate(_ package: StudentPackage) {
        guard isOnline, updateProgress == nil, updateSentForVersion != package.info.version,
              let current = connection else { return }
        updateSentForVersion = package.info.version
        updateProgress = 0
        let url = package.fileURL
        let info = package.info
        Task { [weak self] in
            let data = try? await Task.detached(priority: .utility) { try Data(contentsOf: url) }.value
            guard let self else { return }
            guard let data, self.connection === current else {
                self.updateProgress = nil
                return
            }
            current.send(.updateBegin(info))
            self.sendChunks(data, from: 0, over: current)
        }
    }

    private func sendChunks(_ data: Data, from offset: Int, over current: SecureConnection) {
        guard connection === current else {
            updateProgress = nil
            return
        }
        if offset >= data.count {
            current.send(Message(type: "updateEnd"))
            updateProgress = nil
            return
        }
        let end = min(offset + 512 * 1024, data.count)
        let chunk = data.subdata(in: offset..<end)
        updateProgress = Double(end) / Double(max(data.count, 1))
        current.sendChunk(chunk) { [weak self] ok in
            DispatchQueue.main.async {
                if ok {
                    self?.sendChunks(data, from: end, over: current)
                } else {
                    self?.updateProgress = nil
                }
            }
        }
    }
}
