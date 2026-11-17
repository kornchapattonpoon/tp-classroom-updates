import AppKit
import SwiftUI
import ClassroomKit

/// Shows the student's screen and, while Control is on, sends the teacher's
/// mouse and keyboard to the student computer.
struct RemoteScreenView: NSViewRepresentable {
    let image: CGImage
    let controlEnabled: Bool
    let onInput: (InputEvent) -> Void

    func makeNSView(context: Context) -> RemoteScreenNSView {
        RemoteScreenNSView(frame: .zero)
    }

    func updateNSView(_ view: RemoteScreenNSView, context: Context) {
        view.onInput = onInput
        view.image = image
        view.controlEnabled = controlEnabled
    }
}

final class RemoteScreenNSView: NSView {
    var onInput: ((InputEvent) -> Void)?

    var image: CGImage? {
        didSet { layer?.contents = image }
    }

    var controlEnabled = false {
        didSet {
            guard controlEnabled != oldValue else { return }
            if controlEnabled { window?.makeFirstResponder(self) }
        }
    }

    private var trackingArea: NSTrackingArea?

    /// Modifier keys arrive as flagsChanged; this says which flag each key controls.
    private static let modifierForKey: [UInt16: NSEvent.ModifierFlags] = [
        56: .shift, 60: .shift,
        59: .control, 62: .control,
        58: .option, 61: .option,
        55: .command, 54: .command,
        57: .capsLock,
    ]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: - Coordinates

    /// Where the picture is drawn inside the view (it keeps its aspect ratio).
    private var imageRect: CGRect {
        guard let image, image.width > 0, image.height > 0 else { return bounds }
        let imageWidth = CGFloat(image.width)
        let imageHeight = CGFloat(image.height)
        let scale = min(bounds.width / imageWidth, bounds.height / imageHeight)
        let size = CGSize(width: imageWidth * scale, height: imageHeight * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    /// Mouse position as 0...1 across the student's screen, origin top-left.
    private func position(of event: NSEvent) -> (x: Double, y: Double) {
        let point = convert(event.locationInWindow, from: nil)
        let rect = imageRect
        let x = (point.x - rect.minX) / max(rect.width, 1)
        let y = 1 - (point.y - rect.minY) / max(rect.height, 1)
        return (Double(min(max(x, 0), 1)), Double(min(max(y, 0), 1)))
    }

    private func send(_ event: InputEvent) {
        guard controlEnabled else { return }
        onInput?(event)
    }

    // MARK: - Mouse

    override func mouseMoved(with event: NSEvent) {
        let p = position(of: event)
        send(.move(x: p.x, y: p.y))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendButton(0, down: true, event)
    }

    override func mouseUp(with event: NSEvent) { sendButton(0, down: false, event) }
    override func rightMouseDown(with event: NSEvent) { sendButton(1, down: true, event) }
    override func rightMouseUp(with event: NSEvent) { sendButton(1, down: false, event) }
    override func otherMouseDown(with event: NSEvent) { sendButton(2, down: true, event) }
    override func otherMouseUp(with event: NSEvent) { sendButton(2, down: false, event) }

    override func mouseDragged(with event: NSEvent) { sendDrag(0, event) }
    override func rightMouseDragged(with event: NSEvent) { sendDrag(1, event) }
    override func otherMouseDragged(with event: NSEvent) { sendDrag(2, event) }

    override func scrollWheel(with event: NSEvent) {
        var dx = Double(event.scrollingDeltaX)
        var dy = Double(event.scrollingDeltaY)
        if !event.hasPreciseScrollingDeltas {
            dx *= 40
            dy *= 40
        }
        send(.scroll(dx: dx, dy: dy))
    }

    private func sendButton(_ number: Int, down: Bool, _ event: NSEvent) {
        let p = position(of: event)
        send(.press(number, down: down, x: p.x, y: p.y, clicks: event.clickCount))
    }

    private func sendDrag(_ number: Int, _ event: NSEvent) {
        let p = position(of: event)
        send(.drag(number, x: p.x, y: p.y))
    }

    // MARK: - Keyboard

    private func mods(_ event: NSEvent) -> Int {
        let flags = event.modifierFlags
        var result = 0
        if flags.contains(.shift) { result |= Mods.shift }
        if flags.contains(.control) { result |= Mods.control }
        if flags.contains(.option) { result |= Mods.alt }
        if flags.contains(.command) { result |= Mods.meta }
        if flags.contains(.capsLock) { result |= Mods.capsLock }
        return result
    }

    private func sendKey(_ event: NSEvent, down: Bool) {
        guard let code = KeyCodes.macToCode[event.keyCode] else { return }
        send(.key(code, down: down, mods: mods(event)))
    }

    override func keyDown(with event: NSEvent) {
        guard controlEnabled else { return super.keyDown(with: event) }
        sendKey(event, down: true)
    }

    override func keyUp(with event: NSEvent) {
        guard controlEnabled else { return super.keyUp(with: event) }
        sendKey(event, down: false)
    }

    override func flagsChanged(with event: NSEvent) {
        guard controlEnabled else { return super.flagsChanged(with: event) }
        let isDown = Self.modifierForKey[event.keyCode].map { event.modifierFlags.contains($0) } ?? false
        sendKey(event, down: isDown)
    }

    /// ⌘-shortcuts normally go to the teacher's own menus; while controlling,
    /// send them to the student computer instead (⌘C, ⌘V, ⌘Z…).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard controlEnabled,
              window?.firstResponder === self,
              event.type == .keyDown,
              event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        sendKey(event, down: true)
        sendKey(event, down: false)
        return true
    }
}
