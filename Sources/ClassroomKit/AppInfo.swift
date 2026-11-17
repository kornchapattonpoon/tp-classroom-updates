import Foundation
import SystemConfiguration
import IOKit

public enum AppInfo {
    public static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// The Mac's name from System Settings → General → Sharing (e.g. "iMac-07").
    public static var computerName: String {
        if let name = SCDynamicStoreCopyComputerName(nil, nil) as String?, !name.isEmpty {
            return name
        }
        return "Mac"
    }

    /// Stable ID of this computer (the same for every user and every reinstall).
    public static let deviceID: String = {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { if service != 0 { IOObjectRelease(service) } }
        if service != 0,
           let value = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String, !value.isEmpty {
            return "mac-" + value.lowercased()
        }
        let key = "TPClassroomDeviceID"
        if let saved = UserDefaults.standard.string(forKey: key) { return saved }
        let made = "mac-" + UUID().uuidString.lowercased()
        UserDefaults.standard.set(made, forKey: key)
        return made
    }()
}

/// Lets the updater quit an app that normally refuses to quit (it hides instead).
@MainActor
public enum AppLifecycle {
    public static var allowQuit = false
}
