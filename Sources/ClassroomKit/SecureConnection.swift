import Foundation
import Network
import CryptoKit

/// Plain TCP parameters (encryption is done by `SecureConnection` itself, so it matches Windows).
public enum ClassroomNetwork {
    public static func tcpParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 3
        tcp.connectionTimeout = 8
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.includePeerToPeer = false
        return parameters
    }
}

/// One encrypted teacher ↔ student connection (handshake + AES-GCM records, see PROTOCOL.md).
/// All callbacks arrive on the main thread.
public final class SecureConnection: @unchecked Sendable {
    public enum Role: Sendable {
        case teacher
        case student
    }

    public let connection: NWConnection
    private let role: Role
    private let classKey: SymmetricKey
    private let queue = DispatchQueue(label: "tpclassroom.secure", qos: .userInitiated)
    private let localNonce = ClassCrypto.randomBytes(32)

    // Only touched on `queue`.
    private var sendKey: SymmetricKey?
    private var receiveKey: SymmetricKey?
    private var sendCounter: UInt64 = 0
    private var receiveCounter: UInt64 = 0
    private var waiting: [(Data, (@Sendable (Bool) -> Void)?)] = []
    private var isEstablished = false
    private var isClosed = false
    private var gotFirstRecord = false

    private static let magic = Data("TPC1".utf8)
    private static let maxRecord = 16 * 1024 * 1024 + 64

    public var onReady: (@MainActor () -> Void)?
    public var onMessage: (@MainActor (Message) -> Void)?
    public var onFrame: (@MainActor (Data) -> Void)?
    public var onChunk: (@MainActor (Data) -> Void)?
    /// `nil` reason = closed normally.
    public var onClose: (@MainActor (String?) -> Void)?

    public init(connection: NWConnection, role: Role, classKey: SymmetricKey) {
        self.connection = connection
        self.role = role
        self.classKey = classKey
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.beginHandshake()
            case .waiting(let error), .failed(let error):
                self.finish(Self.describe(error))
            case .cancelled:
                self.finish(nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    /// Closes without calling `onClose`.
    public func cancel() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isClosed = true
            self.connection.stateUpdateHandler = nil
            self.connection.cancel()
        }
    }

    public func send(_ message: Message) {
        guard let json = try? JSONEncoder().encode(message) else { return }
        enqueue(type: 1, payload: json, completion: nil)
    }

    public func sendFrame(_ jpeg: Data, completion: @escaping @Sendable (Bool) -> Void) {
        enqueue(type: 2, payload: jpeg, completion: completion)
    }

    public func sendChunk(_ bytes: Data, completion: @escaping @Sendable (Bool) -> Void) {
        enqueue(type: 3, payload: bytes, completion: completion)
    }

    // MARK: - Handshake

    private func beginHandshake() {
        connection.send(content: Self.magic + localNonce, completion: .contentProcessed { _ in })
        connection.receive(minimumIncompleteLength: 36, maximumLength: 36) { [weak self] data, _, _, error in
            guard let self, !self.isClosed else { return }
            guard error == nil, let data, data.count == 36, Data(data.prefix(4)) == Self.magic else {
                self.finish("That device isn't running a compatible TP Classroom.")
                return
            }
            let remoteNonce = Data(data.suffix(32))
            let salt = self.role == .teacher ? self.localNonce + remoteNonce : remoteNonce + self.localNonce
            let teacherToStudent = Self.derive(self.classKey, salt: salt, label: "TPClassroom/v1/t2s")
            let studentToTeacher = Self.derive(self.classKey, salt: salt, label: "TPClassroom/v1/s2t")
            self.sendKey = self.role == .teacher ? teacherToStudent : studentToTeacher
            self.receiveKey = self.role == .teacher ? studentToTeacher : teacherToStudent
            self.isEstablished = true

            let queued = self.waiting
            self.waiting.removeAll()
            for (plaintext, completion) in queued {
                self.sendSealed(plaintext, completion: completion)
            }
            DispatchQueue.main.async { [weak self] in
                self?.onReady?()
            }
            self.receiveLength()
        }
    }

    private static func derive(_ key: SymmetricKey, salt: Data, label: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: key, salt: salt, info: Data(label.utf8), outputByteCount: 32)
    }

    private static func nonce(_ counter: UInt64) -> Data {
        var data = Data(repeating: 0, count: 4)
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8(truncatingIfNeeded: counter >> UInt64(shift)))
        }
        return data
    }

    // MARK: - Sending

    private func enqueue(type: UInt8, payload: Data, completion: (@Sendable (Bool) -> Void)?) {
        var plaintext = Data(capacity: payload.count + 1)
        plaintext.append(type)
        plaintext.append(payload)
        queue.async { [weak self] in
            guard let self, !self.isClosed else {
                completion?(false)
                return
            }
            if self.isEstablished {
                self.sendSealed(plaintext, completion: completion)
            } else {
                self.waiting.append((plaintext, completion))
            }
        }
    }

    private func sendSealed(_ plaintext: Data, completion: (@Sendable (Bool) -> Void)?) {
        guard let key = sendKey,
              let nonce = try? AES.GCM.Nonce(data: Self.nonce(sendCounter)),
              let box = try? AES.GCM.seal(plaintext, using: key, nonce: nonce) else {
            completion?(false)
            return
        }
        sendCounter += 1
        let record = box.ciphertext + box.tag
        let length = UInt32(record.count)
        var packet = Data(capacity: record.count + 4)
        packet.append(contentsOf: [UInt8(truncatingIfNeeded: length >> 24),
                                   UInt8(truncatingIfNeeded: length >> 16),
                                   UInt8(truncatingIfNeeded: length >> 8),
                                   UInt8(truncatingIfNeeded: length)])
        packet.append(record)
        connection.send(content: packet, completion: .contentProcessed { error in
            completion?(error == nil)
        })
    }

    // MARK: - Receiving

    private func receiveLength() {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            guard let self, !self.isClosed else { return }
            guard error == nil, let data, data.count == 4 else {
                self.finish(isComplete ? nil : "The connection was lost.")
                return
            }
            let bytes = [UInt8](data)
            let length = (Int(bytes[0]) << 24) | (Int(bytes[1]) << 16) | (Int(bytes[2]) << 8) | Int(bytes[3])
            guard length >= 17, length <= Self.maxRecord else {
                self.finish("Received damaged data.")
                return
            }
            self.receiveRecord(length)
        }
    }

    private func receiveRecord(_ length: Int) {
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, _, error in
            guard let self, !self.isClosed else { return }
            guard error == nil, let data, data.count == length else {
                self.finish("The connection was lost.")
                return
            }
            let record = Data(data)
            guard let key = self.receiveKey,
                  let nonce = try? AES.GCM.Nonce(data: Self.nonce(self.receiveCounter)),
                  let box = try? AES.GCM.SealedBox(nonce: nonce,
                                                   ciphertext: record.prefix(length - 16),
                                                   tag: record.suffix(16)),
                  let plaintext = try? AES.GCM.open(box, using: key),
                  !plaintext.isEmpty else {
                self.finish(self.gotFirstRecord ? "Received damaged data." : "The class code doesn't match.")
                return
            }
            self.receiveCounter += 1
            self.gotFirstRecord = true
            self.deliver(Data(plaintext))
            self.receiveLength()
        }
    }

    private func deliver(_ plaintext: Data) {
        let type = plaintext[plaintext.startIndex]
        let payload = Data(plaintext.dropFirst())
        switch type {
        case 1:
            guard let message = try? JSONDecoder().decode(Message.self, from: payload) else { return }
            DispatchQueue.main.async { [weak self] in self?.onMessage?(message) }
        case 2:
            DispatchQueue.main.async { [weak self] in self?.onFrame?(payload) }
        case 3:
            DispatchQueue.main.async { [weak self] in self?.onChunk?(payload) }
        default:
            break
        }
    }

    private func finish(_ reason: String?) {
        guard !isClosed else { return }
        isClosed = true
        connection.stateUpdateHandler = nil
        connection.cancel()
        let finalReason: String?
        if reason == nil && isEstablished && !gotFirstRecord {
            finalReason = "The class code doesn't match."
        } else {
            finalReason = reason
        }
        let pending = waiting
        waiting.removeAll()
        for (_, completion) in pending { completion?(false) }
        DispatchQueue.main.async { [weak self] in
            self?.onClose?(finalReason)
        }
    }

    static func describe(_ error: NWError) -> String {
        switch error {
        case .posix(let code):
            switch code {
            case .ECONNREFUSED: return "TP Classroom isn't running on that computer."
            case .ETIMEDOUT: return "The connection timed out."
            case .EHOSTUNREACH, .ENETUNREACH, .EHOSTDOWN: return "That computer can't be reached right now."
            default: return error.localizedDescription
            }
        default:
            return error.localizedDescription
        }
    }
}
