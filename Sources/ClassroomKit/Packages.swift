import Foundation
import AppKit
import CryptoKit

/// Signed update package description (the `.json` next to each package, see PROTOCOL.md).
public struct PackageInfo: Codable, Sendable {
    public var platform: String
    public var version: String
    public var sha256: String
    public var signature: String
    public var size: Int?

    public init(platform: String, version: String, sha256: String, signature: String, size: Int?) {
        self.platform = platform
        self.version = version
        self.sha256 = sha256
        self.signature = signature
        self.size = size
    }
}

public enum PackageError: LocalizedError {
    case notConfigured
    case badChecksum
    case badSignature
    case noApp
    case wrongApp
    case notWritable(String)
    case toolFailed(String, Int32)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "Updates aren't set up in this build (no public key)."
        case .badChecksum: return "The update was damaged on the way."
        case .badSignature: return "The update isn't signed with your key, so it was not installed."
        case .noApp: return "The update didn't contain the app."
        case .wrongApp: return "The update contained a different app."
        case .notWritable(let path): return "No permission to replace \(path). Reinstall with the install script."
        case .toolFailed(let tool, let status): return "\(tool) failed (exit code \(status))."
        }
    }
}

/// Checks SHA-256 + ECDSA P-256 signatures made by your private key.
public enum PackageVerifier {
    public static var publicKey: P256.Signing.PublicKey? {
        guard let text = Bundle.main.object(forInfoDictionaryKey: "TPCUpdatePublicKey") as? String,
              let der = Data(base64Encoded: text) else { return nil }
        return try? P256.Signing.PublicKey(derRepresentation: der)
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func verify(_ data: Data, sha256: String, signature: String) throws {
        guard let key = publicKey else { throw PackageError.notConfigured }
        guard sha256Hex(data) == sha256.lowercased() else { throw PackageError.badChecksum }
        guard let raw = Data(base64Encoded: signature),
              let parsed = try? P256.Signing.ECDSASignature(rawRepresentation: raw),
              key.isValidSignature(parsed, for: data) else { throw PackageError.badSignature }
    }
}

/// Installs a new version of a Mac app by swapping the `Contents` folder of the running bundle,
/// then relaunches it. Settings are untouched.
public enum MacAppInstaller {
    public static func install(zip: Data, bundleURL: URL, expectedBundleID: String) throws {
        let fileManager = FileManager.default
        let work = fileManager.temporaryDirectory
            .appendingPathComponent("TPClassroomUpdate-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: work) }

        let zipURL = work.appendingPathComponent("update.zip")
        try zip.write(to: zipURL)
        let extracted = work.appendingPathComponent("extracted", isDirectory: true)
        try run("/usr/bin/ditto", ["-x", "-k", zipURL.path, extracted.path])

        guard let newApp = try fileManager.contentsOfDirectory(at: extracted, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else { throw PackageError.noApp }
        guard Bundle(url: newApp)?.bundleIdentifier == expectedBundleID else { throw PackageError.wrongApp }
        try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])

        guard fileManager.isWritableFile(atPath: bundleURL.path) else {
            throw PackageError.notWritable(bundleURL.path)
        }
        let contents = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let backup = work.appendingPathComponent("PreviousContents", isDirectory: true)
        try fileManager.moveItem(at: contents, to: backup)
        do {
            try fileManager.moveItem(at: newApp.appendingPathComponent("Contents", isDirectory: true), to: contents)
        } catch {
            try? fileManager.moveItem(at: backup, to: contents)
            throw error
        }
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: bundleURL.path)
    }

    static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw PackageError.toolFailed((tool as NSString).lastPathComponent, process.terminationStatus)
        }
    }

    /// Waits for this process to quit, then starts the new version.
    /// Uses launchd if the app runs as a LaunchAgent (student Macs), otherwise `open`.
    @MainActor
    public static func relaunch(bundleURL: URL, launchAgentLabel: String, inBackground: Bool) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.3; done
        /bin/sleep 0.5
        DOMAIN="gui/$(/usr/bin/id -u)"
        if [ -n "$1" ] && /bin/launchctl print "$DOMAIN/$1" >/dev/null 2>&1; then
          /bin/launchctl kickstart "$DOMAIN/$1"
        elif [ "$2" = "background" ]; then
          /usr/bin/open -g "$0" --args --background
        else
          /usr/bin/open "$0"
        fi
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, bundleURL.path, launchAgentLabel, inBackground ? "background" : "front"]
        try? process.run()
        AppLifecycle.allowQuit = true
        NSApp.terminate(nil)
    }
}

/// Remembers "you just updated" so the app can show "Update completed" with what's new.
public enum UpdateMarker {
    private static let key = "TPClassroomJustUpdated"

    public static func set(version: String, notes: String?) {
        UserDefaults.standard.set(["version": version, "notes": notes ?? ""], forKey: key)
    }

    /// Returns (version, notes) once, right after an update.
    public static func take() -> (version: String, notes: String?)? {
        let defaults = UserDefaults.standard
        guard let info = defaults.dictionary(forKey: key) else { return nil }
        defaults.removeObject(forKey: key)
        guard let version = info["version"] as? String, version == AppInfo.version else { return nil }
        let notes = (info["notes"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return (version, notes)
    }
}
