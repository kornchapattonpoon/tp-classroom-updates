import SwiftUI
import ClassroomKit

struct ContentView: View {
    @EnvironmentObject var model: ClassroomModel
    @EnvironmentObject var updater: Updater
    @State private var prompt: Prompt? = nil

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(prompt: $prompt)
            Divider()
            Group {
                if model.classCode.isEmpty {
                    ClassCodeSetupView()
                } else if model.sessions.isEmpty {
                    WaitingView()
                } else {
                    studentGrid
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            StatusBar()
        }
        .sheet(item: $prompt) { item in
            PromptSheet(prompt: item) { value in model.perform(item, value: value) }
        }
    }

    private var studentGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250, maximum: 420), spacing: 18)], spacing: 18) {
                ForEach(model.sessions) { session in
                    StudentTile(session: session)
                        .onTapGesture { model.onOpenLive?(session) }
                        .contextMenu { menu(for: session) }
                }
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private func menu(for session: StudentSession) -> some View {
        Button("Watch & Help") { model.onOpenLive?(session) }
        Divider()
        if session.isLocked {
            Button("Unlock Screen") { session.unlock() }
        } else {
            Button("Lock Screen…") { prompt = .lock(session.id) }
        }
        Button("Send Message…") { prompt = .message(session.id) }
        Button("Open Website…") { prompt = .openURL(session.id) }
        Divider()
        Button("Reconnect") { session.connect() }
        Button("Forget This Computer") { model.forget(session) }
    }
}

/// Buttons along the top of the main window.
struct HeaderBar: View {
    @EnvironmentObject var model: ClassroomModel
    @EnvironmentObject var updater: Updater
    @Binding var prompt: Prompt?

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("TP Classroom")
                    .font(.title2.bold())
                Text("\(model.onlineCount) of \(model.sessions.count) online")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.onOpenAI?() } label: { Label("TP AI", systemImage: "sparkles") }
                .help("Ask TP AI to do things for you, like shutting down every computer")
            Button { prompt = .lockAll } label: { Label("Lock All", systemImage: "lock.fill") }
                .help("Lock every student screen")
            Button { model.unlockAll() } label: { Label("Unlock All", systemImage: "lock.open.fill") }
                .help("Unlock every student screen")
            Button { prompt = .messageAll } label: { Label("Message", systemImage: "text.bubble.fill") }
                .help("Show a message on every student screen")
            Button { prompt = .openURLAll } label: { Label("Website", systemImage: "safari.fill") }
                .help("Open a website on every student computer")
            Menu {
                Button("Reconnect Everyone") { model.reconnectAll() }
                Button("Connect by Address… (only if a computer doesn't appear)") { prompt = .addHost }
                Divider()
                Button("Check for Updates") { Task { await updater.check(userInitiated: true) } }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .fixedSize()
        }
        .buttonStyle(.bordered)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .disabled(model.classCode.isEmpty)
    }
}

// MARK: - First run

struct ClassCodeSetupView: View {
    @EnvironmentObject var model: ClassroomModel
    @State private var code = ""

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "person.3.sequence.fill")
                .font(.system(size: 52))
                .foregroundStyle(Color.accentColor)
            Text("Welcome to TP Classroom")
                .font(.largeTitle.bold())
            Text("Choose a class code. Every student computer (Mac or Windows) uses the same code. It also protects the connection, so a random code is best.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 460)
            HStack {
                TextField("Class code", text: $code)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .onSubmit(save)
                Button("Start", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(code.trimmed.isEmpty)
            }
            Button("Make a random code for me") { code = ClassroomModel.randomCode() }
                .buttonStyle(.link)
        }
        .padding(40)
    }

    private func save() {
        guard !code.trimmed.isEmpty else { return }
        model.setClassCode(code)
    }
}

struct WaitingView: View {
    @EnvironmentObject var model: ClassroomModel

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("Waiting for students…")
                .font(.title2.bold())
            Text("Student computers on this network with class code \(model.classCode) appear here by themselves. No internet or IP addresses needed. Once they've appeared, they're remembered.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 480)
            Text(model.discoveryStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(40)
    }
}

struct StatusBar: View {
    @EnvironmentObject var model: ClassroomModel
    @EnvironmentObject var updater: Updater

    var body: some View {
        HStack(spacing: 16) {
            Text(model.discoveryStatus)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            Text("v\(AppInfo.version) · \(updater.statusText)")
                .lineLimit(1)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
