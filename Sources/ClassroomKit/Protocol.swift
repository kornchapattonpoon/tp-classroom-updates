import Foundation

/// Network ports (see PROTOCOL.md).
public enum ClassroomPorts {
    public static let tcp: UInt16 = 52800
    public static let udp: UInt16 = 52801
}

/// Modifier bits used in `InputEvent.mods`.
public enum Mods {
    public static let shift = 1
    public static let control = 2
    public static let alt = 4
    public static let meta = 8
    public static let capsLock = 16
}

/// Mouse and keyboard input sent from the teacher's live view.
public struct InputEvent: Codable, Equatable, Sendable {
    public var kind: String            // move, down, up, drag, scroll, key
    public var x: Double? = nil
    public var y: Double? = nil
    public var button: Int? = nil
    public var clicks: Int? = nil
    public var dx: Double? = nil
    public var dy: Double? = nil
    public var code: String? = nil     // W3C KeyboardEvent.code, e.g. "KeyA"
    public var down: Bool? = nil
    public var mods: Int? = nil

    public init(kind: String) {
        self.kind = kind
    }

    public static func move(x: Double, y: Double) -> InputEvent {
        var event = InputEvent(kind: "move")
        event.x = x
        event.y = y
        return event
    }

    public static func press(_ button: Int, down: Bool, x: Double, y: Double, clicks: Int) -> InputEvent {
        var event = InputEvent(kind: down ? "down" : "up")
        event.button = button
        event.x = x
        event.y = y
        event.clicks = clicks
        return event
    }

    public static func drag(_ button: Int, x: Double, y: Double) -> InputEvent {
        var event = InputEvent(kind: "drag")
        event.button = button
        event.x = x
        event.y = y
        return event
    }

    public static func scroll(dx: Double, dy: Double) -> InputEvent {
        var event = InputEvent(kind: "scroll")
        event.dx = dx
        event.dy = dy
        return event
    }

    public static func key(_ code: String, down: Bool, mods: Int) -> InputEvent {
        var event = InputEvent(kind: "key")
        event.code = code
        event.down = down
        event.mods = mods
        return event
    }
}

/// What kind of screen stream the teacher wants.
public struct StreamSettings: Equatable, Sendable {
    public var fps: Int
    public var maxWidth: Int
    public var quality: Double
    public var live: Bool

    public init(fps: Int, maxWidth: Int, quality: Double, live: Bool) {
        self.fps = fps
        self.maxWidth = maxWidth
        self.quality = quality
        self.live = live
    }

    public static let thumbnail = StreamSettings(fps: 1, maxWidth: 480, quality: 0.45, live: false)
}

/// Every control message. One flat JSON object with a "type" (see PROTOCOL.md).
public struct Message: Codable, Sendable {
    public var type: String
    public var role: String? = nil
    public var id: String? = nil
    public var name: String? = nil
    public var user: String? = nil
    public var computer: String? = nil
    public var os: String? = nil
    public var version: String? = nil
    public var text: String? = nil
    public var url: String? = nil
    public var enabled: Bool? = nil
    public var fps: Int? = nil
    public var maxWidth: Int? = nil
    public var quality: Double? = nil
    public var live: Bool? = nil
    public var input: InputEvent? = nil
    public var screenOk: Bool? = nil
    public var controlOk: Bool? = nil
    public var locked: Bool? = nil
    public var platform: String? = nil
    public var size: Int? = nil
    public var sha256: String? = nil
    public var signature: String? = nil
    public var action: String? = nil

    public init(type: String) {
        self.type = type
    }

    // MARK: Teacher → student

    public static func hello(name: String) -> Message {
        var message = Message(type: "hello")
        message.role = "teacher"
        message.name = name
        message.version = AppInfo.version
        message.os = "mac"
        return message
    }

    public static func stream(_ settings: StreamSettings) -> Message {
        var message = Message(type: "stream")
        message.fps = settings.fps
        message.maxWidth = settings.maxWidth
        message.quality = settings.quality
        message.live = settings.live
        return message
    }

    public static func control(_ enabled: Bool) -> Message {
        var message = Message(type: "control")
        message.enabled = enabled
        return message
    }

    public static func remoteInput(_ event: InputEvent) -> Message {
        var message = Message(type: "input")
        message.input = event
        return message
    }

    public static func lock(_ text: String) -> Message {
        var message = Message(type: "lock")
        message.text = text
        return message
    }

    public static func message(_ text: String) -> Message {
        var message = Message(type: "message")
        message.text = text
        return message
    }

    public static func openURL(_ url: String) -> Message {
        var message = Message(type: "openUrl")
        message.url = url
        return message
    }

    public static func updateBegin(_ package: PackageInfo) -> Message {
        var message = Message(type: "updateBegin")
        message.platform = package.platform
        message.version = package.version
        message.size = package.size
        message.sha256 = package.sha256
        message.signature = package.signature
        return message
    }

    /// Types the text exactly as written, whatever keyboard language the student uses.
    public static func typeText(_ text: String) -> Message {
        var message = Message(type: "typeText")
        message.text = text
        return message
    }

    /// "shutdown" or "restart". Students get a 15-second warning first.
    public static func power(_ action: String) -> Message {
        var message = Message(type: "power")
        message.action = action
        return message
    }

    // MARK: Student → teacher

    public static func notice(_ text: String) -> Message {
        var message = Message(type: "notice")
        message.text = text
        return message
    }

    public var streamSettings: StreamSettings {
        StreamSettings(fps: fps ?? 1, maxWidth: maxWidth ?? 480, quality: quality ?? 0.5, live: live ?? false)
    }
}

/// One UDP discovery datagram.
public struct DiscoveryPacket: Codable, Sendable {
    public var tpc: Int = 1
    public var kind: String
    public var classTag: String
    public var id: String? = nil
    public var name: String? = nil
    public var user: String? = nil
    public var os: String? = nil
    public var version: String? = nil
    public var port: Int? = nil

    enum CodingKeys: String, CodingKey {
        case tpc, kind, classTag = "class", id, name, user, os, version, port
    }

    public init(kind: String, classTag: String) {
        self.kind = kind
        self.classTag = classTag
    }
}

public enum Versions {
    /// true if `a` is a newer version than `b` ("1.0.10" > "1.0.9").
    public static func isNewer(_ a: String, than b: String) -> Bool {
        a.compare(b, options: .numeric) == .orderedDescending
    }
}
