import SwiftUI
import ClassroomKit

/// The TP AI chat window.
struct AIView: View {
    @ObservedObject var assistant: AIAssistant
    @State private var input = ""

    private let examples = [
        "Lock every screen",
        "Open youtube.com on all computers",
        "Shut down all computers",
        "What is on iMac-07's screen?",
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("TP AI", systemImage: "sparkles")
                    .font(.headline)
                Spacer()
                Button("Start Over") { assistant.startOver() }
                    .disabled(assistant.isWorking || assistant.lines.isEmpty)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if assistant.lines.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Ask TP AI to run the class for you. It can lock screens, send messages, open websites, shut down or restart computers, and look at a screen to click and type there.")
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                ForEach(examples, id: \.self) { example in
                                    Button(example) { input = example }
                                        .buttonStyle(.link)
                                }
                            }
                        }
                        ForEach(assistant.lines) { line in
                            AILineView(line: line).id(line.id)
                        }
                        if assistant.isWorking {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Working…").foregroundStyle(.secondary)
                            }
                            .id("working")
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: assistant.lines.count) { _ in
                    if let last = assistant.lines.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            Divider()
            if !assistant.isConfigured {
                Text("TP AI isn't set up yet: add an API key in Settings → TP AI.")
                    .font(.caption)
                    .foregroundStyle(Color.orange)
                    .padding(.top, 8)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask TP AI… (e.g. “Shut down all computers”)", text: $input, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onSubmit(send)
                Button("Send", action: send)
                    .keyboardShortcut(.defaultAction)
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || assistant.isWorking)
            }
            .padding(12)
        }
        .frame(minWidth: 380, minHeight: 460)
    }

    private func send() {
        let text = input
        input = ""
        assistant.send(text)
    }
}

struct AILineView: View {
    let line: AIAssistant.Line

    /// Shows **bold** and *italic* from TP AI as real formatting instead of stars.
    static func formatted(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    var body: some View {
        switch line.kind {
        case .teacher:
            HStack {
                Spacer(minLength: 40)
                Text(line.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.18)))
                    .textSelection(.enabled)
            }
        case .assistant:
            Text(Self.formatted(line.text))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.12)))
                .textSelection(.enabled)
        case .action:
            Label(line.text, systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .problem:
            Label(line.text, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(Color.orange)
        }
    }
}
