import SwiftUI
import ClassroomKit

/// One student in the grid: a live thumbnail of their screen, name and status.
struct StudentTile: View {
    @ObservedObject var session: StudentSession
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            screen
            HStack(spacing: 6) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 8, height: 8)
                Image(systemName: session.isWindows ? "pc" : "desktopcomputer")
                    .foregroundStyle(.secondary)
                Text(session.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let warning = session.warning {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.orange)
                        .help(warning)
                }
            }
            if let progress = session.updateProgress {
                ProgressView(value: progress) {
                    Text("Updating to v\(AppInfo.version)…").font(.caption)
                }
            } else {
                Text(session.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(hovering ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: hovering ? 2 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onHover { hovering = $0 }
        .help("Click to watch and help \(session.name)")
    }

    private var screen: some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                Color.black
                if session.isOnline, let frame = session.frame {
                    Image(decorative: frame, scale: 1)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fit)
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: placeholderIcon)
                            .font(.system(size: 26))
                        Text(placeholderText)
                            .font(.caption)
                            .multilineTextAlignment(.center)
                    }
                    .foregroundStyle(Color.white.opacity(0.65))
                    .padding(10)
                }
            }

            if session.isLocked {
                Label("Locked", systemImage: "lock.fill")
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.red))
                    .foregroundStyle(Color.white)
                    .padding(8)
            }
        }
        .aspectRatio(16.0 / 10.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var dotColor: Color {
        switch session.status {
        case .online: return .green
        case .connecting: return .yellow
        case .offline: return .gray
        case .error: return .red
        }
    }

    private var placeholderIcon: String {
        switch session.status {
        case .online: return "display"
        case .connecting: return "antenna.radiowaves.left.and.right"
        case .offline: return "moon.zzz.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private var placeholderText: String {
        switch session.status {
        case .online: return session.screenOK ? "Waiting for screen…" : "Screen can't be shown yet"
        case .connecting: return "Connecting…"
        case .offline: return "Offline (remembered)"
        case .error(let message): return message
        }
    }
}
