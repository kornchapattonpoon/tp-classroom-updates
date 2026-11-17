import Foundation
import AppKit
import ClassroomKit

/// TP AI: a chat assistant in the teacher app that can run the classroom for the teacher —
/// lock screens, open websites, shut down computers, or look at a screen and click/type there.
/// It talks to an OpenAI-compatible API (Groq by default, set in config.env).
@MainActor
final class AIAssistant: ObservableObject {
    struct Line: Identifiable {
        enum Kind {
            case teacher
            case assistant
            case action
            case problem
        }

        let id = UUID()
        let kind: Kind
        let text: String
    }

    @Published private(set) var lines: [Line] = []
    @Published private(set) var isWorking = false

    private weak var model: ClassroomModel?
    private var history: [[String: Any]] = []
    private var screenshotSizes: [String: CGSize] = [:]
    private static let maxSteps = 20
    nonisolated static let keyOverrideDefaultsKey = "aiKeyOverride"

    init(model: ClassroomModel) {
        self.model = model
    }

    // MARK: - Settings (from config.env, baked into Info.plist by build.sh)

    nonisolated private static func info(_ key: String) -> String {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The key built into the app by build.sh (stored scrambled). Like TP Browser, it can't be changed in the app.
    nonisolated static var builtInKey: String {
        let text = info("TPCAIKeyX")
        guard !text.isEmpty, let data = Data(base64Encoded: text) else { return "" }
        let mask = Array("TPClassroom/v1/ai".utf8)
        let bytes = data.enumerated().map { $0.element ^ mask[$0.offset % mask.count] }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static var hasBuiltInKey: Bool { !builtInKey.isEmpty }

    var apiKey: String {
        let builtIn = Self.builtInKey
        if !builtIn.isEmpty { return builtIn }
        return (UserDefaults.standard.string(forKey: Self.keyOverrideDefaultsKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var modelName: String {
        let name = Self.info("TPCAIModel")
        return name.isEmpty ? "qwen/qwen3.8-27b" : name
    }

    private var endpoint: URL? {
        let base = Self.info("TPCAIBaseURL")
        let text = (base.isEmpty ? "https://api.groq.com/openai/v1" : base)
        return URL(string: text.hasSuffix("/") ? text + "chat/completions" : text + "/chat/completions")
    }

    var isConfigured: Bool { !apiKey.isEmpty }

    // MARK: - Chat

    func startOver() {
        guard !isWorking else { return }
        history.removeAll()
        lines.removeAll()
        screenshotSizes.removeAll()
    }

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isWorking else { return }
        guard isConfigured else {
            lines.append(Line(kind: .problem, text: "TP AI isn't set up yet. Add an API key in Settings → TP AI (or AI_API_KEY in config.env)."))
            return
        }
        lines.append(Line(kind: .teacher, text: trimmed))
        history.append(["role": "user", "content": trimmed])
        isWorking = true
        Task {
            await self.run()
            self.isWorking = false
        }
    }

    private func run() async {
        for _ in 0..<Self.maxSteps {
            let reply: [String: Any]
            do {
                reply = try await callModel()
            } catch {
                lines.append(Line(kind: .problem, text: error.localizedDescription))
                return
            }

            let content = reply["content"] as? String ?? ""
            let toolCalls = reply["tool_calls"] as? [[String: Any]] ?? []
            var assistant: [String: Any] = ["role": "assistant", "content": content]
            if !toolCalls.isEmpty { assistant["tool_calls"] = toolCalls }
            history.append(assistant)

            let visible = Self.clean(content)
            if !visible.isEmpty { lines.append(Line(kind: .assistant, text: visible)) }
            if toolCalls.isEmpty { return }

            var images: [String] = []
            for call in toolCalls {
                let id = call["id"] as? String ?? ""
                let function = call["function"] as? [String: Any] ?? [:]
                let name = function["name"] as? String ?? ""
                let argumentText = function["arguments"] as? String ?? "{}"
                let arguments = (try? JSONSerialization.jsonObject(with: Data(argumentText.utf8))) as? [String: Any] ?? [:]
                let result = await runTool(name, arguments)
                history.append(["role": "tool", "tool_call_id": id, "content": result.text])
                if let image = result.imageDataURL { images.append(image) }
            }
            if !images.isEmpty {
                var parts: [[String: Any]] = [["type": "text", "text": "Here is the screenshot you asked for."]]
                for image in images {
                    parts.append(["type": "image_url", "image_url": ["url": image]])
                }
                history.append(["role": "user", "content": parts])
                keepOnlyRecentScreenshots()
            }
        }
        lines.append(Line(kind: .assistant, text: "I stopped after \(Self.maxSteps) steps. Tell me if I should keep going."))
    }

    /// The API accepts only a few images per request: replace older screenshots with a note.
    private func keepOnlyRecentScreenshots(keep: Int = 1) {
        var seen = 0
        for index in history.indices.reversed() {
            guard var parts = history[index]["content"] as? [[String: Any]] else { continue }
            var changed = false
            for partIndex in parts.indices.reversed() where parts[partIndex]["type"] as? String == "image_url" {
                seen += 1
                if seen > keep {
                    parts[partIndex] = ["type": "text", "text": "[older screenshot removed]"]
                    changed = true
                }
            }
            if changed { history[index]["content"] = parts }
        }
    }

    private static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "<think>[\\s\\S]*?</think>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct APIError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Free AI plans only allow a little text per minute, so old conversation is dropped:
    /// only the last few things the teacher asked (and what happened) are sent.
    private func trimHistory(keepTurns: Int = 4) {
        let starts = history.indices.filter { history[$0]["role"] as? String == "user" && history[$0]["content"] is String }
        guard starts.count > keepTurns else { return }
        history.removeFirst(starts[starts.count - keepTurns])
    }

    private func callModel() async throws -> [String: Any] {
        guard let endpoint else { throw APIError(message: "The TP AI address in config.env isn't valid.") }
        trimHistory()
        let messages: [[String: Any]] = [["role": "system", "content": AIToolbox.systemPrompt]] + history
        let body: [String: Any] = [
            "model": modelName,
            "messages": messages,
            "tools": AIToolbox.tools,
            "tool_choice": "auto",
            "temperature": 0.2,
            // Short answers and no hidden "thinking": fits the free plan's per-minute limits and is faster.
            "max_completion_tokens": 500,
            "reasoning_effort": "none",
        ]
        var request = URLRequest(url: endpoint, timeoutInterval: 90)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        for attempt in 0..<5 {
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await URLSession.shared.data(for: request)
            } catch {
                throw APIError(message: "TP AI needs the internet. (\(error.localizedDescription))")
            }
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 429 && attempt < 4 {
                // Too many requests this minute: wait as long as the service asks, then try again.
                let header = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "retry-after") ?? ""
                let wait = min(60, max(2, Double(header) ?? 10))
                note("TP AI is busy for a moment. Trying again in \(Int(wait.rounded(.up))) seconds…")
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                continue
            }
            if status == 413 {
                history.removeAll()
                screenshotSizes.removeAll()
                throw APIError(message: "That was too much for TP AI at once, so I cleared our chat. Please ask again.")
            }
            if status != 200 {
                let detail = (json?["error"] as? [String: Any])?["message"] as? String ?? "HTTP \(status)"
                throw APIError(message: "TP AI couldn't answer: \(detail)")
            }
            guard let choices = json?["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any] else {
                throw APIError(message: "TP AI sent an answer it couldn't read.")
            }
            return message
        }
        throw APIError(message: "TP AI is busy right now. Please try again in a minute.")
    }

    // MARK: - Running tools

    private struct ToolResult {
        var text: String
        var imageDataURL: String? = nil
    }

    private func note(_ text: String) {
        lines.append(Line(kind: .action, text: text))
    }

    private func resolve(_ value: Any?) -> [StudentSession] {
        guard let model else { return [] }
        var names: [String] = []
        if let list = value as? [Any] {
            names = list.compactMap { $0 as? String }
        } else if let single = value as? String {
            names = [single]
        }
        if names.isEmpty || names.contains(where: { $0.lowercased() == "all" }) {
            return model.sessions
        }
        return model.sessions.filter { session in
            names.contains { $0.caseInsensitiveCompare(session.name) == .orderedSame || $0 == session.id }
        }
    }

    private func resolveOne(_ value: Any?) -> StudentSession? {
        guard let name = value as? String, let model else { return nil }
        return model.sessions.first { $0.name.caseInsensitiveCompare(name) == .orderedSame || $0.id == name }
    }

    private static func number(_ value: Any?) -> Double {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String, let parsed = Double(text) { return parsed }
        return 0
    }

    private static func names(_ sessions: [StudentSession]) -> String {
        sessions.map { $0.name }.joined(separator: ", ")
    }

    private func runTool(_ name: String, _ args: [String: Any]) async -> ToolResult {
        guard let model else { return ToolResult(text: "The classroom isn't available.") }

        switch name {
        case "list_computers":
            let list: [[String: Any]] = model.sessions.map { session in
                [
                    "name": session.name,
                    "system": session.isWindows ? "windows" : "mac",
                    "online": session.isOnline,
                    "locked": session.isLocked,
                    "user": session.user,
                ]
            }
            let data = (try? JSONSerialization.data(withJSONObject: ["computers": list])) ?? Data()
            return ToolResult(text: String(decoding: data, as: UTF8.self))

        case "lock_screens":
            let targets = resolve(args["computers"])
            let message = (args["message"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Eyes on the teacher, please"
            for session in targets { session.lock(message: message) }
            note("Locked \(targets.count) screen(s)")
            return ToolResult(text: "Locked: \(Self.names(targets)). Offline computers lock when they come back.")

        case "unlock_screens":
            let targets = resolve(args["computers"])
            for session in targets { session.unlock() }
            note("Unlocked \(targets.count) screen(s)")
            return ToolResult(text: "Unlocked: \(Self.names(targets)).")

        case "send_message":
            let targets = resolve(args["computers"]).filter { $0.isOnline }
            let text = args["text"] as? String ?? ""
            for session in targets { session.send(.message(text)) }
            note("Sent a message to \(targets.count) computer(s)")
            return ToolResult(text: "Message shown on: \(Self.names(targets)).")

        case "open_website":
            guard let url = ClassroomModel.normalizeURL(args["url"] as? String ?? "") else {
                return ToolResult(text: "That isn't a web address.")
            }
            let targets = resolve(args["computers"]).filter { $0.isOnline }
            for session in targets { session.send(.openURL(url)) }
            note("Opened \(url) on \(targets.count) computer(s)")
            return ToolResult(text: "Opened \(url) on: \(Self.names(targets)).")

        case "power":
            let restart = (args["action"] as? String) == "restart"
            let targets = resolve(args["computers"]).filter { $0.isOnline }
            guard !targets.isEmpty else { return ToolResult(text: "None of those computers are online.") }
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = restart ? "Restart \(targets.count) computer(s)?" : "Shut down \(targets.count) computer(s)?"
            alert.informativeText = "TP AI wants to \(restart ? "restart" : "shut down"): \(Self.names(targets)).\n\nStudents get a 15-second warning to save their work."
            alert.addButton(withTitle: restart ? "Restart" : "Shut Down")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else {
                note("You cancelled")
                return ToolResult(text: "The teacher cancelled. Nothing was changed.")
            }
            for session in targets { session.power(restart ? "restart" : "shutdown") }
            note("\(restart ? "Restarting" : "Shutting down") \(targets.count) computer(s)")
            return ToolResult(text: "\(restart ? "Restarting" : "Shutting down"): \(Self.names(targets)).")

        case "look_at_screen":
            guard let session = resolveOne(args["computer"]) else { return ToolResult(text: "I can't find that computer.") }
            guard session.isOnline else { return ToolResult(text: "\(session.name) is offline.") }
            note("Looking at \(session.name)")
            let before = session.frame
            session.openLiveView()   // a bigger, fresher picture
            for _ in 0..<30 {
                if let frame = session.frame, frame !== before, frame.width > 480 { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            session.closeLiveView()
            guard let frame = session.frame, let encoded = AIToolbox.jpegDataURL(frame) else {
                return ToolResult(text: "No picture from \(session.name) yet (is Screen Recording allowed there?).")
            }
            screenshotSizes[session.id] = encoded.size
            return ToolResult(text: "Screenshot of \(session.name) (\(session.isWindows ? "Windows" : "Mac")), \(Int(encoded.size.width))×\(Int(encoded.size.height)) pixels. Use these pixel coordinates for click.",
                              imageDataURL: encoded.url)

        case "click":
            guard let session = resolveOne(args["computer"]), session.isOnline else {
                return ToolResult(text: "That computer isn't online.")
            }
            guard let size = screenshotSizes[session.id], size.width > 0, size.height > 0 else {
                return ToolResult(text: "Call look_at_screen for \(session.name) first.")
            }
            let x = min(max(Self.number(args["x"]) / Double(size.width), 0), 1)
            let y = min(max(Self.number(args["y"]) / Double(size.height), 0), 1)
            let button = (args["button"] as? String) == "right" ? 1 : 0
            let double = (args["double"] as? Bool) ?? false
            var events: [InputEvent] = [.move(x: x, y: y),
                                        .press(button, down: true, x: x, y: y, clicks: 1),
                                        .press(button, down: false, x: x, y: y, clicks: 1)]
            if double {
                events += [.press(button, down: true, x: x, y: y, clicks: 2),
                           .press(button, down: false, x: x, y: y, clicks: 2)]
            }
            session.performAIInput(events)
            note("Clicked on \(session.name)")
            try? await Task.sleep(nanoseconds: 700_000_000)
            return ToolResult(text: "Clicked. Look at the screen again to check.")

        case "type_text":
            guard let session = resolveOne(args["computer"]), session.isOnline else {
                return ToolResult(text: "That computer isn't online.")
            }
            let text = args["text"] as? String ?? ""
            session.typeTextAsAI(text)
            note("Typed on \(session.name)")
            try? await Task.sleep(nanoseconds: UInt64(300_000_000 + text.count * 10_000_000))
            return ToolResult(text: "Typed \(text.count) characters.")

        case "press_keys":
            guard let session = resolveOne(args["computer"]), session.isOnline else {
                return ToolResult(text: "That computer isn't online.")
            }
            guard let codes = AIToolbox.parseKeys(args["keys"] as? String ?? "") else {
                return ToolResult(text: "I don't know those keys. Use names like enter, tab, esc, cmd+s, ctrl+c.")
            }
            session.performAIInput(AIToolbox.keyEvents(codes, studentIsMac: !session.isWindows))
            note("Pressed \(args["keys"] as? String ?? "") on \(session.name)")
            try? await Task.sleep(nanoseconds: 500_000_000)
            return ToolResult(text: "Pressed.")

        default:
            return ToolResult(text: "Unknown tool \(name).")
        }
    }
}

/// The instructions, tool list and helpers TP AI uses (plain values, usable from any thread).
enum AIToolbox {
    static let systemPrompt = """
    You are TP AI, the assistant built into TP Classroom. The teacher uses TP Classroom to watch and help \
    the student computers in a classroom (Macs and Windows PCs). Do what the teacher asks by using the tools.
    Rules:
    - Only act on student computers when the teacher asks you to in this conversation.
    - Use computer names from list_computers. Use ["all"] for every computer.
    - Prefer the direct tools (lock_screens, unlock_screens, send_message, open_website, power) over clicking.
    - To click or type on one computer: call look_at_screen first, click using pixel coordinates from that \
    screenshot, then look again to check that it worked.
    - Keyboard shortcuts depend on the student computer's system: cmd on a Mac, ctrl on Windows.
    - Reply briefly, in the same language the teacher writes in, and say what you did.
    """

    static func tool(_ name: String, _ description: String,
                             _ properties: [String: Any], required: [String]) -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": ["type": "object", "properties": properties, "required": required] as [String: Any],
            ] as [String: Any],
        ]
    }

    static let computers: [String: Any] = [
        "type": "array",
        "items": ["type": "string"],
        "description": "Computer names from list_computers, or [\"all\"] for every computer.",
    ]

    static let computer: [String: Any] = [
        "type": "string",
        "description": "One computer name from list_computers.",
    ]

    static let tools: [[String: Any]] = [
        tool("list_computers", "List the student computers with their system, whether they're online and locked.",
             [:], required: []),
        tool("lock_screens", "Lock student screens with a message.",
             ["computers": computers, "message": ["type": "string", "description": "Shown on the lock screen."]],
             required: ["computers"]),
        tool("unlock_screens", "Unlock student screens.", ["computers": computers], required: ["computers"]),
        tool("send_message", "Show a message on student screens.",
             ["computers": computers, "text": ["type": "string"]], required: ["computers", "text"]),
        tool("open_website", "Open a website on student computers.",
             ["computers": computers, "url": ["type": "string"]], required: ["computers", "url"]),
        tool("power", "Shut down or restart student computers. The teacher is asked to confirm first; students get a 15-second warning.",
             ["computers": computers, "action": ["type": "string", "enum": ["shutdown", "restart"]] as [String: Any]],
             required: ["computers", "action"]),
        tool("look_at_screen", "Get a current screenshot of one student computer.",
             ["computer": computer], required: ["computer"]),
        tool("click", "Click on one student computer at pixel coordinates from its latest screenshot.",
             ["computer": computer,
              "x": ["type": "number"], "y": ["type": "number"],
              "button": ["type": "string", "enum": ["left", "right"]] as [String: Any],
              "double": ["type": "boolean"]],
             required: ["computer", "x", "y"]),
        tool("type_text", "Type text on one student computer, into whatever is selected there.",
             ["computer": computer, "text": ["type": "string"]], required: ["computer", "text"]),
        tool("press_keys", "Press a key or shortcut on one student computer, e.g. \"enter\", \"cmd+s\", \"ctrl+alt+t\", \"tab\".",
             ["computer": computer, "keys": ["type": "string"]], required: ["computer", "keys"]),
    ]

    static let symbolCodes: [Character: String] = [
        "-": "Minus", "=": "Equal", ",": "Comma", ".": "Period", "/": "Slash", ";": "Semicolon",
        "'": "Quote", "[": "BracketLeft", "]": "BracketRight", "\\": "Backslash", "`": "Backquote",
    ]

    /// "cmd+shift+s" → ["MetaLeft", "ShiftLeft", "KeyS"]
    static func parseKeys(_ text: String) -> [String]? {
        var codes: [String] = []
        for raw in text.lowercased().split(separator: "+") {
            let part = raw.trimmingCharacters(in: .whitespaces)
            let code: String?
            switch part {
            case "cmd", "command", "meta", "win", "windows", "super": code = "MetaLeft"
            case "ctrl", "control": code = "ControlLeft"
            case "alt", "option", "opt": code = "AltLeft"
            case "shift": code = "ShiftLeft"
            case "enter", "return": code = "Enter"
            case "esc", "escape": code = "Escape"
            case "tab": code = "Tab"
            case "space": code = "Space"
            case "backspace": code = "Backspace"
            case "delete", "del": code = "Delete"
            case "up": code = "ArrowUp"
            case "down": code = "ArrowDown"
            case "left": code = "ArrowLeft"
            case "right": code = "ArrowRight"
            case "home": code = "Home"
            case "end": code = "End"
            case "pageup": code = "PageUp"
            case "pagedown": code = "PageDown"
            default:
                if part.count == 1, let character = part.first {
                    if character.isASCII && character.isLetter {
                        code = "Key" + part.uppercased()
                    } else if character.isASCII && character.isNumber {
                        code = "Digit" + part
                    } else {
                        code = symbolCodes[character]
                    }
                } else if part.hasPrefix("f"), let number = Int(part.dropFirst()), (1...12).contains(number) {
                    code = "F\(number)"
                } else {
                    code = nil
                }
            }
            guard let code else { return nil }
            codes.append(code)
        }
        return codes.isEmpty ? nil : codes
    }

    /// Presses the keys in order and releases them in reverse. This teacher app runs on a Mac, so for a
    /// Windows student the keys are pre-swapped (the student swaps ⌘/Ctrl back), keeping them literal.
    static func keyEvents(_ codes: [String], studentIsMac: Bool) -> [InputEvent] {
        let sent = studentIsMac ? codes : codes.map { KeyCodes.swapMetaAndControl($0) }
        var mods = 0
        var events: [InputEvent] = []
        for code in sent {
            switch code {
            case "ShiftLeft": mods |= Mods.shift
            case "ControlLeft": mods |= Mods.control
            case "AltLeft": mods |= Mods.alt
            case "MetaLeft": mods |= Mods.meta
            default: break
            }
            events.append(.key(code, down: true, mods: mods))
        }
        for code in sent.reversed() {
            events.append(.key(code, down: false, mods: mods))
        }
        return events
    }

    static func jpegDataURL(_ image: CGImage, maxWidth: Int = 1280) -> (url: String, size: CGSize)? {
        var source = image
        if image.width > maxWidth {
            let height = max(1, Int(Double(image.height) * Double(maxWidth) / Double(image.width)))
            if let context = CGContext(data: nil, width: maxWidth, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                       space: CGColorSpaceCreateDeviceRGB(),
                                       bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
                context.interpolationQuality = .high
                context.draw(image, in: CGRect(x: 0, y: 0, width: maxWidth, height: height))
                source = context.makeImage() ?? image
            }
        }
        let representation = NSBitmapImageRep(cgImage: source)
        guard let data = representation.representation(using: .jpeg, properties: [.compressionFactor: 0.6]) else {
            return nil
        }
        return ("data:image/jpeg;base64," + data.base64EncodedString(),
                CGSize(width: source.width, height: source.height))
    }
}
