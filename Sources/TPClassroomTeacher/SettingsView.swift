import SwiftUI
import AppKit
import ClassroomKit

struct SettingsView: View {
    @EnvironmentObject var model: ClassroomModel
    @EnvironmentObject var updater: Updater
    @State private var code = ""
    @State private var name = ""
    @State private var saved = false
    @AppStorage(AIAssistant.keyOverrideDefaultsKey) private var aiKey = ""

    var body: some View {
        Form {
            Section("Class") {
                TextField("Class code", text: $code)
                TextField("Your name", text: $name)
                Text("Students see your name when you connect. Every student computer must use the same class code; changing it reconnects everyone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Make Random Code") { code = ClassroomModel.randomCode() }
                    Spacer()
                    if saved {
                        Text("Saved").foregroundStyle(.secondary)
                    }
                    Button("Save") { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(code.trimmed.isEmpty)
                }
            }
            Section("Live view") {
                Picker("Quality", selection: $model.liveQuality) {
                    ForEach(LiveQuality.allCases) { quality in
                        Text(quality.title).tag(quality)
                    }
                }
            }
            Section("TP AI") {
                if AIAssistant.hasBuiltInKey {
                    Label("TP AI is built in and ready", systemImage: "sparkles")
                    Text("TP AI needs the internet. Everything else works offline.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    SecureField("API key", text: $aiKey)
                    Text("Paste your key from console.groq.com. It's saved only on this Mac. TP AI needs the internet; everything else works offline.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Section("Updates") {
                LabeledContent("Version", value: AppInfo.version)
                LabeledContent("Status", value: updater.statusText)
                if let date = updater.lastChecked {
                    LabeledContent("Last checked", value: date.formatted(date: .abbreviated, time: .shortened))
                }
                HStack {
                    Button("Check Now") { Task { await updater.check(userInitiated: true) } }
                    if updater.hasPendingUpdate {
                        Button("Install Now") { Task { await updater.installNow() } }
                    }
                }
                Text("The teacher app updates itself when it's online. Every student computer then gets the same version from this Mac over the local network, even without internet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 640)
        .onAppear {
            code = model.classCode
            name = model.teacherName
        }
        .onChange(of: code) { _ in saved = false }
        .onChange(of: name) { _ in saved = false }
    }

    private func save() {
        model.teacherName = name.trimmed.isEmpty ? NSFullUserName() : name.trimmed
        model.setClassCode(code)
        code = model.classCode
        saved = true
    }
}
