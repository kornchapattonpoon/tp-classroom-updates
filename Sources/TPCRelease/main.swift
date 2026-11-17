// TPCRelease — signs TP Classroom packages so every app can trust its updates.
//
//   TPCRelease keygen        [--out PATH]                       new signing key (prints the public key)
//   TPCRelease pubkey        [--key PATH]                       public key (base64 DER) for a private key
//   TPCRelease obfuscate     --text TEXT                        scrambles the built-in TP AI key (not encryption)
//   TPCRelease sign-package  --file FILE --platform mac|windows --version X.Y.Z --out FILE.json [--key PATH]
//   TPCRelease sign-windows  --file TPClassroom.exe --version X.Y.Z --out Setup.exe --json FILE.json [--key PATH]
//                            (Setup.exe = the exe with its signature stored at the end, see PROTOCOL.md)
//   TPCRelease feed          --version X.Y.Z --asset-base-url URL --asset NAME=FILE [--asset NAME=FILE…]
//                            [--notes TEXT] [--min-macos 13.0] [--expect-public-key KEY] [--key PATH] --out appcast.json
//
// Keys are ECDSA P-256. Signatures are raw r||s (64 bytes), base64. See PROTOCOL.md.

import Foundation
import CryptoKit

let defaultKeyPath = "~/.tpclassroom/update_private_key"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func usage() -> Never {
    print("""
    Usage:
      TPCRelease keygen        [--out PATH]
      TPCRelease pubkey        [--key PATH]
      TPCRelease sign-package  --file FILE --platform mac|windows --version X.Y.Z --out FILE.json [--key PATH]
      TPCRelease sign-windows  --file TPClassroom.exe --version X.Y.Z --out Setup.exe --json FILE.json [--key PATH]
      TPCRelease feed          --version X.Y.Z --asset-base-url URL --asset NAME=FILE [--asset NAME=FILE ...]
                               [--notes TEXT] [--min-macos 13.0] [--expect-public-key KEY] [--key PATH] --out FILE
    """)
    exit(1)
}

/// Options may repeat (e.g. several --asset).
func parseOptions(_ arguments: [String]) -> [String: [String]] {
    var result: [String: [String]] = [:]
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        guard argument.hasPrefix("--") else { fail("unexpected argument '\(argument)'") }
        guard index + 1 < arguments.count else { fail("missing value for \(argument)") }
        result[String(argument.dropFirst(2)), default: []].append(arguments[index + 1])
        index += 2
    }
    return result
}

func expand(_ path: String) -> String {
    NSString(string: path).expandingTildeInPath
}

func loadPrivateKey(_ path: String) -> P256.Signing.PrivateKey {
    let fullPath = expand(path)
    guard let text = try? String(contentsOfFile: fullPath, encoding: .utf8),
          let data = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? P256.Signing.PrivateKey(rawRepresentation: data) else {
        fail("couldn't read a private key at \(fullPath). Run ./scripts/setup-keys.sh first.")
    }
    return key
}

func publicKeyText(_ key: P256.Signing.PrivateKey) -> String {
    key.publicKey.derRepresentation.base64EncodedString()
}

func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func sign(_ data: Data, with key: P256.Signing.PrivateKey) -> String {
    guard let signature = try? key.signature(for: data) else { fail("signing failed") }
    return signature.rawRepresentation.base64EncodedString()
}

func readFile(_ path: String) -> Data {
    guard let data = FileManager.default.contents(atPath: expand(path)) else { fail("can't read \(path)") }
    return data
}

func writeJSON(_ object: Any, to path: String) {
    guard let json = try? JSONSerialization.data(withJSONObject: object,
                                                 options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
          FileManager.default.createFile(atPath: expand(path), contents: json) else {
        fail("couldn't write \(path)")
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { usage() }
let options = parseOptions(Array(arguments.dropFirst()))

func option(_ name: String) -> String? { options[name]?.last }

switch command {
case "keygen":
    let path = expand(option("out") ?? defaultKeyPath)
    if FileManager.default.fileExists(atPath: path) {
        fail("\(path) already exists. Keep using it: installed apps only trust updates signed with that key.")
    }
    let directory = (path as NSString).deletingLastPathComponent
    do {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    } catch {
        fail("couldn't create \(directory): \(error.localizedDescription)")
    }
    let key = P256.Signing.PrivateKey()
    guard FileManager.default.createFile(atPath: path,
                                         contents: Data(key.rawRepresentation.base64EncodedString().utf8),
                                         attributes: [.posixPermissions: 0o600]) else {
        fail("couldn't write \(path)")
    }
    print(publicKeyText(key))

case "obfuscate":
    // Keeps the TP AI key from showing up as plain text inside the apps. Same mask as the apps use.
    guard let text = option("text") else { usage() }
    let mask = Array("TPClassroom/v1/ai".utf8)
    let bytes = Array(text.utf8).enumerated().map { $0.element ^ mask[$0.offset % mask.count] }
    print(Data(bytes).base64EncodedString())

case "pubkey":
    print(publicKeyText(loadPrivateKey(option("key") ?? defaultKeyPath)))

case "sign-package":
    guard let file = option("file"), let platform = option("platform"),
          let version = option("version"), let out = option("out") else { usage() }
    let key = loadPrivateKey(option("key") ?? defaultKeyPath)
    let data = readFile(file)
    writeJSON([
        "platform": platform,
        "version": version,
        "sha256": sha256Hex(data),
        "signature": sign(data, with: key),
        "size": data.count,
    ], to: out)
    print("Signed \((file as NSString).lastPathComponent)")

case "sign-windows":
    guard let file = option("file"), let version = option("version"),
          let out = option("out"), let jsonOut = option("json") else { usage() }
    let key = loadPrivateKey(option("key") ?? defaultKeyPath)
    let exe = readFile(file)
    let info: [String: Any] = [
        "platform": "windows",
        "version": version,
        "sha256": sha256Hex(exe),
        "signature": sign(exe, with: key),
        "size": exe.count,
    ]
    writeJSON(info, to: jsonOut)
    guard let trailerJSON = try? JSONSerialization.data(withJSONObject: info, options: [.sortedKeys, .withoutEscapingSlashes]) else {
        fail("couldn't encode the signature")
    }
    // [exe][signature JSON][8-byte little-endian JSON length]["TPCSIG01"]
    var output = exe
    output.append(trailerJSON)
    let length = UInt64(trailerJSON.count)
    for shift in stride(from: 0, through: 56, by: 8) {
        output.append(UInt8(truncatingIfNeeded: length >> UInt64(shift)))
    }
    output.append(Data("TPCSIG01".utf8))
    guard FileManager.default.createFile(atPath: expand(out), contents: output) else { fail("couldn't write \(out)") }
    print("Signed \((out as NSString).lastPathComponent)")

case "feed":
    guard let version = option("version"), let base = option("asset-base-url"),
          let out = option("out"), let assetSpecs = options["asset"], !assetSpecs.isEmpty else { usage() }
    let key = loadPrivateKey(option("key") ?? defaultKeyPath)
    if let expected = option("expect-public-key"), !expected.isEmpty, expected != publicKeyText(key) {
        fail("this private key doesn't match UPDATE_PUBLIC_KEY in config.env. Apps would reject the update.")
    }
    var assets: [String: Any] = [:]
    for spec in assetSpecs {
        let parts = spec.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { fail("--asset must look like name=path") }
        let data = readFile(parts[1])
        let name = (parts[1] as NSString).lastPathComponent
        let prefix = base.hasSuffix("/") ? base : base + "/"
        assets[parts[0]] = [
            "url": prefix + name,
            "sha256": sha256Hex(data),
            "signature": sign(data, with: key),
            "size": data.count,
        ]
    }
    var feed: [String: Any] = [
        "version": version,
        "minimumMacOS": option("min-macos") ?? "13.0",
        "publishedAt": ISO8601DateFormatter().string(from: Date()),
        "assets": assets,
    ]
    if let notes = option("notes"), !notes.isEmpty { feed["notes"] = notes }
    writeJSON(feed, to: out)
    print("Wrote \(out)")

default:
    usage()
}
