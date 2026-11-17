import Foundation
import Darwin

/// UDP broadcast discovery on port 52801 (see PROTOCOL.md).
/// Students announce themselves; teachers listen. No IP addresses to type, no internet needed.
public final class UDPDiscovery: @unchecked Sendable {
    private let port: UInt16
    private let queue = DispatchQueue(label: "tpclassroom.discovery", qos: .utility)
    private var socketFD: Int32 = -1
    private var readSource: DispatchSourceRead?

    /// Called on a background queue with the decoded packet and the sender's IPv4 address.
    public var onPacket: (@Sendable (DiscoveryPacket, String) -> Void)?

    public init(port: UInt16 = ClassroomPorts.udp) {
        self.port = port
    }

    deinit {
        readSource?.cancel()
    }

    public func start() throws {
        try queue.sync {
            guard socketFD < 0 else { return }
            let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard fd >= 0 else { throw POSIXError(.EIO) }

            var yes: Int32 = 1
            let size = socklen_t(MemoryLayout<Int32>.size)
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, size)
            setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, size)
            setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, size)

            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(port).bigEndian
            address.sin_addr = in_addr(s_addr: in_addr_t(0))
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0 else {
                let code = POSIXErrorCode(rawValue: errno) ?? .EADDRINUSE
                Darwin.close(fd)
                throw POSIXError(code)
            }
            let flags = fcntl(fd, F_GETFL)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in
                self?.readAvailable()
            }
            source.setCancelHandler {
                Darwin.close(fd)
            }
            source.resume()
            socketFD = fd
            readSource = source
        }
    }

    public func stop() {
        queue.sync {
            readSource?.cancel()
            readSource = nil
            socketFD = -1
        }
    }

    /// Sends a packet to every local network (directed broadcasts + 255.255.255.255).
    public func broadcast(_ packet: DiscoveryPacket) {
        guard let data = try? JSONEncoder().encode(packet) else { return }
        queue.async { [weak self] in
            guard let self, self.socketFD >= 0 else { return }
            var targets = Self.broadcastAddresses()
            targets.append("255.255.255.255")
            for target in Set(targets) {
                self.sendDatagram(data, to: target)
            }
        }
    }

    /// Sends a packet straight to one address (used to reach remembered computers).
    public func send(_ packet: DiscoveryPacket, to host: String) {
        guard let data = try? JSONEncoder().encode(packet) else { return }
        queue.async { [weak self] in
            guard let self, self.socketFD >= 0 else { return }
            self.sendDatagram(data, to: host)
        }
    }

    // MARK: - Private (on `queue`)

    private func sendDatagram(_ data: Data, to host: String) {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return }
        let fd = socketFD
        let addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    _ = sendto(fd, raw.baseAddress, raw.count, 0, socketAddress, addressLength)
                }
            }
        }
    }

    private func readAvailable() {
        let capacity = 4096
        var buffer = [UInt8](repeating: 0, count: capacity)
        while socketFD >= 0 {
            var sender = sockaddr_in()
            var senderLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let fd = socketFD
            let count = buffer.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Int in
                withUnsafeMutablePointer(to: &sender) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                        recvfrom(fd, raw.baseAddress, capacity, 0, socketAddress, &senderLength)
                    }
                }
            }
            guard count > 0 else { break }
            let ip = Self.string(from: sender.sin_addr)
            let data = Data(buffer[0..<count])
            if let packet = try? JSONDecoder().decode(DiscoveryPacket.self, from: data), packet.tpc == 1 {
                onPacket?(packet, ip)
            }
        }
    }

    private static func string(from address: in_addr) -> String {
        var copy = address
        var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        let length = socklen_t(INET_ADDRSTRLEN)
        _ = inet_ntop(AF_INET, &copy, &text, length)
        return String(cString: text)
    }

    /// Directed broadcast address of every active IPv4 network (e.g. 192.168.1.255).
    public static func broadcastAddresses() -> [String] {
        var result: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return result }
        defer { freeifaddrs(list) }

        var cursor = list
        while let entry = cursor {
            let flags = Int32(truncatingIfNeeded: entry.pointee.ifa_flags)
            if let address = entry.pointee.ifa_addr,
               address.pointee.sa_family == sa_family_t(AF_INET),
               flags & IFF_UP != 0,
               flags & IFF_BROADCAST != 0,
               flags & IFF_LOOPBACK == 0,
               let broadcast = entry.pointee.ifa_dstaddr {
                let inet = broadcast.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                let text = string(from: inet)
                if !text.isEmpty && text != "0.0.0.0" {
                    result.append(text)
                }
            }
            cursor = entry.pointee.ifa_next
        }
        return result
    }
}
