import Foundation
import AppKit

/// The online update feed (appcast.json, made by scripts/release.sh).
public struct UpdateFeed: Codable, Sendable {
    public struct Asset: Codable, Sendable {
        public let url: URL
        public let sha256: String
        public let signature: String
        public let size: Int?
    }

    public let version: String
    public let notes: String?
    public let minimumMacOS: String?
    public let publishedAt: String?
    public let assets: [String: Asset]
}

/// Keeps the teacher app up to date from the internet. (Students get the same version
/// from the teacher over the local network, so everyone always matches.)
@MainActor
public final class Updater: ObservableObject {
    public enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(String)
        case downloading
        case installing
        case failed(String)
    }

    @Published public private(set) var status: Status = .idle
    @Published public private(set) var lastChecked: Date? = nil
    @Published public private(set) var availableNotes: String? = nil

    /// Feed asset to install, e.g. "mac-teacher".
    public let assetName: String
    /// Return true to wait (e.g. while the teacher is controlling a student).
    public var shouldDeferInstall: (@MainActor () -> Bool)?
    /// Should the app come back hidden in the menu bar after relaunching?
    public var relaunchInBackground: (@MainActor () -> Bool)?

    private var pending: UpdateFeed?
    private var timer: Timer?

    public init(assetName: String) {
        self.assetName = assetName
    }

    public var isConfigured: Bool { feedURL != nil && PackageVerifier.publicKey != nil }

    public var hasPendingUpdate: Bool {
        if case .available = status { return true }
        return false
    }

    public var statusText: String {
        switch status {
        case .idle: return isConfigured ? "Automatic updates on" : "Updates not set up in this build"
        case .checking: return "Checking for updates…"
        case .upToDate: return "Up to date"
        case .available(let version): return "Version \(version) will install soon"
        case .downloading: return "Downloading update…"
        case .installing: return "Installing update…"
        case .failed(let message): return "Update problem: \(message)"
        }
    }

    /// Checks now and every 2 hours. Offline is fine: it just tries again later.
    public func startAutomaticChecks(every interval: TimeInterval = 2 * 3600) {
        guard timer == nil else { return }
        Task { await self.check() }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check() }
        }
        // Retry a deferred install every 10 minutes.
        Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.hasPendingUpdate else { return }
                await self.installIfAllowed()
            }
        }
    }

    public func check(userInitiated: Bool = false) async {
        switch status {
        case .checking, .downloading, .installing: return
        default: break
        }
        guard let feedURL else {
            if userInitiated { status = .failed(PackageError.notConfigured.localizedDescription) }
            return
        }
        status = .checking
        do {
            let request = URLRequest(url: feedURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 30)
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw URLError(.badServerResponse)
            }
            let feed = try JSONDecoder().decode(UpdateFeed.self, from: data)
            lastChecked = Date()
            guard Versions.isNewer(feed.version, than: AppInfo.version),
                  feed.assets[assetName] != nil,
                  Self.systemSupports(feed.minimumMacOS) else {
                pending = nil
                status = .upToDate
                return
            }
            pending = feed
            availableNotes = feed.notes
            status = .available(feed.version)
            await installIfAllowed()
        } catch {
            // Offline or server problem: not an error the teacher needs to fix.
            status = userInitiated ? .failed("Couldn't reach the update server (no internet?)") : .idle
        }
    }

    public func installIfAllowed() async {
        if shouldDeferInstall?() ?? false { return }
        await installNow()
    }

    public func installNow() async {
        guard let feed = pending, let asset = feed.assets[assetName] else { return }
        let bundleURL = Bundle.main.bundleURL
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        status = .downloading
        do {
            let (fileURL, response) = try await URLSession.shared.download(from: asset.url)
            defer { try? FileManager.default.removeItem(at: fileURL) }
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw URLError(.badServerResponse)
            }
            let zip = try Data(contentsOf: fileURL)
            try PackageVerifier.verify(zip, sha256: asset.sha256, signature: asset.signature)

            status = .installing
            try await Task.detached(priority: .userInitiated) {
                try MacAppInstaller.install(zip: zip, bundleURL: bundleURL, expectedBundleID: bundleID)
            }.value

            UpdateMarker.set(version: feed.version, notes: feed.notes)
            MacAppInstaller.relaunch(bundleURL: bundleURL, launchAgentLabel: bundleID,
                                     inBackground: relaunchInBackground?() ?? false)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private var feedURL: URL? {
        guard let text = Bundle.main.object(forInfoDictionaryKey: "TPCUpdateFeedURL") as? String,
              !text.isEmpty, !text.contains("YOUR_") else { return nil }
        return URL(string: text)
    }

    nonisolated static func systemSupports(_ minimum: String?) -> Bool {
        guard let minimum else { return true }
        let parts = minimum.split(separator: ".").compactMap { Int($0) }
        let version = OperatingSystemVersion(majorVersion: parts.count > 0 ? parts[0] : 0,
                                             minorVersion: parts.count > 1 ? parts[1] : 0,
                                             patchVersion: parts.count > 2 ? parts[2] : 0)
        return ProcessInfo.processInfo.isOperatingSystemAtLeast(version)
    }
}
