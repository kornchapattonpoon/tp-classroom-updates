import SwiftUI
import ClassroomKit

/// One student's screen in real time, with remote control.
struct LiveSessionView: View {
    @ObservedObject var session: StudentSession
    @EnvironmentObject var model: ClassroomModel
    @State private var prompt: Prompt? = nil

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ZStack {
                Color.black
                if let frame = session.frame {
                    RemoteScreenView(image: frame, controlEnabled: session.controlEnabled) { event in
                        session.sendInput(event)
                    }
                    if let pointer = session.aiPointer {
                        AIPointerOverlay(pointer: pointer, imageSize: CGSize(width: frame.width, height: frame.height))
                            .allowsHitTesting(false)
                    }
                } else {
                    ProgressView("Waiting for the screen…")
                        .foregroundStyle(Color.white)
                }
                if !session.isOnline {
                    VStack(spacing: 8) {
                        Image(systemName: "wifi.exclamationmark")
                            .font(.system(size: 34))
                        Text(session.warning ?? "Disconnected. Reconnecting…")
                            .multilineTextAlignment(.center)
                    }
                    .foregroundStyle(Color.white)
                    .padding(24)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color.black.opacity(0.75)))
                }
            }
            .overlay(alignment: .top) {
                if session.aiControlling {
                    Label("TP AI is controlling this computer", systemImage: "sparkles")
                        .font(.caption.bold())
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(AIPointerOverlay.gradient))
                        .padding(8)
                        .allowsHitTesting(false)
                } else if session.controlEnabled {
                    Text("You're controlling this computer. Turn off Control or close this window to stop.")
                        .font(.caption.bold())
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.red.opacity(0.85)))
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
        }
        .sheet(item: $prompt) { item in
            PromptSheet(prompt: item) { value in model.perform(item, value: value) }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: session.isWindows ? "pc" : "desktopcomputer")
            VStack(alignment: .leading, spacing: 2) {
                Text(session.name).font(.headline)
                Text(session.aiControlling ? "TP AI is controlling" :
                        session.controlEnabled ? "Controlling" : (session.isOnline ? "Viewing" : "Offline"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(isOn: Binding(get: { session.controlEnabled }, set: { session.setControl($0) })) {
                Label("Control", systemImage: "cursorarrow.click.2")
            }
            .toggleStyle(.button)
            .disabled(!session.isOnline)
            .help("Use this computer's mouse and keyboard")

            Button {
                if session.isLocked { session.unlock() } else { prompt = .lock(session.id) }
            } label: {
                Label(session.isLocked ? "Unlock" : "Lock",
                      systemImage: session.isLocked ? "lock.open.fill" : "lock.fill")
            }
            Button { prompt = .message(session.id) } label: {
                Label("Message", systemImage: "text.bubble")
            }
            Button { prompt = .openURL(session.id) } label: {
                Label("Website", systemImage: "safari")
            }
        }
        .buttonStyle(.bordered)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}
