import Foundation
import CryptoKit
import ClassroomKit

struct StudentConfig: Codable, Equatable {
    var classCode: String
    var adminPINHash: String? = nil
    var displayName: String? = nil
}

/// Settings for the student app.
///
/// If `/Library/Application Support/TPClassroom/student.json` exists (written by
/// install-student.sh), it wins: the Mac is "managed" and the same class code applies
/// to every account. Otherwise settings come from the setup window.
@MainActor
final class StudentConfigStore: ObservableObject {
    static let systemFile = URL(fileURLWithPath: "/Library/Application Support/TPClassroom/student.json")
    private static let defaultsKey = "studentConfig"

    @Published private(set) var config: StudentConfig? = nil
    @Published private(set) var isManaged = false

    init() {
        reload()
    }

    func reload() {
        if let data = try? Data(contentsOf: Self.systemFile),
           var managed = try? JSONDecoder().decode(StudentConfig.self, from: data) {
            // A display name chosen on this Mac still applies on managed Macs.
            if let localName = localConfig()?.displayName, !localName.isEmpty {
                managed.displayName = localName
            }
            config = managed
            isManaged = true
        } else {
            config = localConfig()
            isManaged = false
        }
    }

    var classCode: String? {
        guard let code = config?.classCode else { return nil }
        let normalized = ClassCrypto.normalize(code)
        return normalized.isEmpty ? nil : normalized
    }

    var displayName: String {
        if let name = config?.displayName?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            return name
        }
        return AppInfo.computerName
    }

    var hasPIN: Bool {
        !(config?.adminPINHash ?? "").isEmpty
    }

    func verify(pin: String) -> Bool {
        guard hasPIN, let stored = config?.adminPINHash else { return true }
        return Self.hash(pin) == stored.lowercased()
    }

    func saveLocal(_ newConfig: StudentConfig) {
        if let data = try? JSONEncoder().encode(newConfig) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
        reload()
    }

    nonisolated static func hash(_ pin: String) -> String {
        SHA256.hash(data: Data(pin.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func localConfig() -> StudentConfig? {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey) else { return nil }
        return try? JSONDecoder().decode(StudentConfig.self, from: data)
    }
}
