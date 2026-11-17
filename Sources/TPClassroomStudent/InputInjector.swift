import Foundation
import CoreGraphics
import ClassroomKit

/// Turns the teacher's mouse and keyboard events into real events on this Mac.
/// Needs Accessibility permission (System Settings → Privacy & Security → Accessibility).
final class InputInjector {
    private let source = CGEventSource(stateID: .hidSystemState)

    func post(_ event: InputEvent) {
        let x = event.x ?? 0.5
        let y = event.y ?? 0.5
        let button = event.button ?? 0

        switch event.kind {
        case "move":
            mouse(.mouseMoved, button: .left, at: point(x, y))

        case "down", "up":
            let down = event.kind == "down"
            let type: CGEventType
            switch button {
            case 0: type = down ? .leftMouseDown : .leftMouseUp
            case 1: type = down ? .rightMouseDown : .rightMouseUp
            default: type = down ? .otherMouseDown : .otherMouseUp
            }
            mouse(type, button: cgButton(button), at: point(x, y), clicks: event.clicks ?? 1)

        case "drag":
            let type: CGEventType
            switch button {
            case 0: type = .leftMouseDragged
            case 1: type = .rightMouseDragged
            default: type = .otherMouseDragged
            }
            mouse(type, button: cgButton(button), at: point(x, y))

        case "scroll":
            let dy = event.dy ?? 0
            let dx = event.dx ?? 0
            let scroll = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                 wheel1: Int32(clamping: Int(dy.rounded())),
                                 wheel2: Int32(clamping: Int(dx.rounded())),
                                 wheel3: 0)
            scroll?.post(tap: .cghidEventTap)

        case "key":
            guard let code = event.code, let keyCode = KeyCodes.codeToMac[code],
                  let key = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode),
                                    keyDown: event.down ?? true) else { return }
            key.flags = flags(from: event.mods ?? 0)
            key.post(tap: .cghidEventTap)

        default:
            break
        }
    }

    /// Types text exactly as written (letters, Thai, emoji…), whatever keyboard language is selected.
    func typeText(_ text: String) {
        let source = self.source
        // Type at a pace people can watch (about 25 letters a second), but never take more than 8 seconds.
        let delay = useconds_t(min(40_000, 8_000_000 / max(text.count, 1)))
        DispatchQueue.global(qos: .userInitiated).async {
            for character in text {
                if character == "\n" || character == "\r" || character == "\t" {
                    let key: CGKeyCode = character == "\t" ? 0x30 : 0x24
                    CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)?.post(tap: .cghidEventTap)
                    CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)?.post(tap: .cghidEventTap)
                } else {
                    var units = Array(String(character).utf16)
                    guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                          let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { continue }
                    down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
                    up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
                    down.post(tap: .cghidEventTap)
                    up.post(tap: .cghidEventTap)
                }
                usleep(delay)
            }
        }
    }

    private func flags(from mods: Int) -> CGEventFlags {
        var flags: CGEventFlags = []
        if mods & Mods.shift != 0 { flags.insert(.maskShift) }
        if mods & Mods.control != 0 { flags.insert(.maskControl) }
        if mods & Mods.alt != 0 { flags.insert(.maskAlternate) }
        if mods & Mods.meta != 0 { flags.insert(.maskCommand) }
        if mods & Mods.capsLock != 0 { flags.insert(.maskAlphaShift) }
        return flags
    }

    /// 0...1 coordinates → global screen points on the main display (top-left origin).
    private func point(_ x: Double, _ y: Double) -> CGPoint {
        let bounds = CGDisplayBounds(CGMainDisplayID())
        let clampedX = min(max(x, 0), 1)
        let clampedY = min(max(y, 0), 1)
        return CGPoint(x: bounds.minX + CGFloat(clampedX) * (bounds.width - 1),
                       y: bounds.minY + CGFloat(clampedY) * (bounds.height - 1))
    }

    private func cgButton(_ button: Int) -> CGMouseButton {
        switch button {
        case 0: return .left
        case 1: return .right
        default: return .center
        }
    }

    private func mouse(_ type: CGEventType, button: CGMouseButton, at point: CGPoint, clicks: Int = 1) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: button) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: Int64(max(1, clicks)))
        event.post(tap: .cghidEventTap)
    }
}
