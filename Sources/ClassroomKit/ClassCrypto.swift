import Foundation
import CryptoKit
import CommonCrypto

/// Turns a class code into the shared key and the discovery tag (see PROTOCOL.md).
public enum ClassCrypto {
    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var keys: [String: SymmetricKey] = [:]
    }

    private static let cache = Cache()

    public static func normalize(_ code: String) -> String {
        code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    /// PBKDF2-HMAC-SHA256, 50 000 rounds. Cached, because it takes a moment.
    public static func key(for code: String) -> SymmetricKey {
        let normalized = normalize(code)
        cache.lock.lock()
        if let cached = cache.keys[normalized] {
            cache.lock.unlock()
            return cached
        }
        cache.lock.unlock()

        let salt = Array("TPClassroom/v1/class".utf8)
        let passwordLength = normalized.utf8.count
        var derived = [UInt8](repeating: 0, count: 32)
        let derivedLength = derived.count
        _ = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                 normalized, passwordLength,
                                 salt, salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                                 50_000,
                                 &derived, derivedLength)
        let key = SymmetricKey(data: Data(derived))

        cache.lock.lock()
        cache.keys[normalized] = key
        cache.lock.unlock()
        return key
    }

    /// Short public tag so classrooms on the same network ignore each other.
    public static func tag(for code: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data("TPClassroom/v1/beacon".utf8), using: key(for: code))
        return Data(mac).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    public static func randomBytes(_ count: Int) -> Data {
        var data = Data()
        while data.count < count {
            data.append(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
        }
        return data.prefix(count)
    }
}
