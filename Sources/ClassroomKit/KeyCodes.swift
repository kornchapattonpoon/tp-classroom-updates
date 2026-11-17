import Foundation

/// macOS virtual key codes ↔ W3C KeyboardEvent.code names (shared with Windows).
public enum KeyCodes {
    public static let macToCode: [UInt16: String] = [
        0x00: "KeyA", 0x0B: "KeyB", 0x08: "KeyC", 0x02: "KeyD", 0x0E: "KeyE", 0x03: "KeyF",
        0x05: "KeyG", 0x04: "KeyH", 0x22: "KeyI", 0x26: "KeyJ", 0x28: "KeyK", 0x25: "KeyL",
        0x2E: "KeyM", 0x2D: "KeyN", 0x1F: "KeyO", 0x23: "KeyP", 0x0C: "KeyQ", 0x0F: "KeyR",
        0x01: "KeyS", 0x11: "KeyT", 0x20: "KeyU", 0x09: "KeyV", 0x0D: "KeyW", 0x07: "KeyX",
        0x10: "KeyY", 0x06: "KeyZ",
        0x1D: "Digit0", 0x12: "Digit1", 0x13: "Digit2", 0x14: "Digit3", 0x15: "Digit4",
        0x17: "Digit5", 0x16: "Digit6", 0x1A: "Digit7", 0x1C: "Digit8", 0x19: "Digit9",
        0x24: "Enter", 0x35: "Escape", 0x33: "Backspace", 0x30: "Tab", 0x31: "Space",
        0x1B: "Minus", 0x18: "Equal", 0x21: "BracketLeft", 0x1E: "BracketRight",
        0x2A: "Backslash", 0x29: "Semicolon", 0x27: "Quote", 0x32: "Backquote",
        0x2B: "Comma", 0x2F: "Period", 0x2C: "Slash", 0x0A: "IntlBackslash",
        0x39: "CapsLock",
        0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5", 0x61: "F6",
        0x62: "F7", 0x64: "F8", 0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12",
        0x7B: "ArrowLeft", 0x7C: "ArrowRight", 0x7D: "ArrowDown", 0x7E: "ArrowUp",
        0x73: "Home", 0x77: "End", 0x74: "PageUp", 0x79: "PageDown",
        0x75: "Delete", 0x72: "Insert",
        0x38: "ShiftLeft", 0x3C: "ShiftRight",
        0x3B: "ControlLeft", 0x3E: "ControlRight",
        0x3A: "AltLeft", 0x3D: "AltRight",
        0x37: "MetaLeft", 0x36: "MetaRight",
        0x52: "Numpad0", 0x53: "Numpad1", 0x54: "Numpad2", 0x55: "Numpad3", 0x56: "Numpad4",
        0x57: "Numpad5", 0x58: "Numpad6", 0x59: "Numpad7", 0x5B: "Numpad8", 0x5C: "Numpad9",
        0x41: "NumpadDecimal", 0x43: "NumpadMultiply", 0x45: "NumpadAdd",
        0x4E: "NumpadSubtract", 0x4B: "NumpadDivide", 0x4C: "NumpadEnter",
    ]

    public static let codeToMac: [String: UInt16] = {
        var result: [String: UInt16] = [:]
        for (key, value) in macToCode { result[value] = key }
        return result
    }()

    /// When teacher and student use different systems, ⌘ and Ctrl trade places.
    public static func swapMetaAndControl(_ code: String) -> String {
        switch code {
        case "MetaLeft": return "ControlLeft"
        case "MetaRight": return "ControlRight"
        case "ControlLeft": return "MetaLeft"
        case "ControlRight": return "MetaRight"
        default: return code
        }
    }

    public static func swapMetaAndControl(mods: Int) -> Int {
        var result = mods & ~(Mods.meta | Mods.control)
        if mods & Mods.meta != 0 { result |= Mods.control }
        if mods & Mods.control != 0 { result |= Mods.meta }
        return result
    }
}
