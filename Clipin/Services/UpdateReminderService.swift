import AppKit
import Foundation

struct ReleaseInfo: Equatable {
    let version: String
    let publishedAt: Date?
    let notes: String
    let releasePageURL: URL
    let downloadURL: URL?

    var displayVersion: String {
        version.hasPrefix("v") ? version : "v\(version)"
    }

    var notesPreview: String {
        let maxCharacters = 1600
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxCharacters else { return trimmed }

        let cutoff = trimmed.index(trimmed.startIndex, offsetBy: maxCharacters)
        return String(trimmed[..<cutoff]).trimmingCharacters(in: .whitespacesAndNewlines) + "\n…"
    }
}

@MainActor
final class UpdateReminderService: ObservableObject {
    static let shared = UpdateReminderService()

    @Published private(set) var autoCheckEnabled: Bool
    @Published private(set) var latestRelease: ReleaseInfo?
    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var isChecking = false
    @Published private(set) var didLastCheckFail = false

    let currentVersion: String
    let currentBuild: String

    private let defaults = UserDefaults.standard
    private let decoder = JSONDecoder()
    private let session: URLSession
    private let latestReleaseAPIURL = URL(string: "https://api.github.com/repos/ccfco/Clipin/releases/latest")!
    private let releasesPageURL = URL(string: "https://github.com/ccfco/Clipin/releases/latest")!
    private var periodicCheckTimer: Timer?
    private var didStart = false

    private enum Keys {
        static let autoCheckEnabled = "updates.autoCheckEnabled"
        static let lastCheckedAt = "updates.lastCheckedAt"
    }

    private init() {
        currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        currentBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        autoCheckEnabled = defaults.object(forKey: Keys.autoCheckEnabled) as? Bool ?? true
        lastCheckedAt = defaults.object(forKey: Keys.lastCheckedAt) as? Date

        decoder.dateDecodingStrategy = .iso8601

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        schedulePeriodicChecks()

        guard autoCheckEnabled else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            await self?.checkForUpdatesIfNeeded()
        }
    }

    func setAutoCheckEnabled(_ enabled: Bool) {
        autoCheckEnabled = enabled
        defaults.set(enabled, forKey: Keys.autoCheckEnabled)

        if enabled {
            Task { [weak self] in
                await self?.checkForUpdatesIfNeeded()
            }
        }
    }

    func checkNow() {
        Task { [weak self] in
            await self?.performCheck(force: true, userInitiated: true)
        }
    }

    func openReleasePage() {
        NSWorkspace.shared.open(latestRelease?.releasePageURL ?? releasesPageURL)
    }

    func downloadLatestRelease() {
        let targetURL = latestRelease?.downloadURL ?? latestRelease?.releasePageURL ?? releasesPageURL
        NSWorkspace.shared.open(targetURL)
    }

    private func schedulePeriodicChecks() {
        periodicCheckTimer?.invalidate()
        periodicCheckTimer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.checkForUpdatesIfNeeded()
            }
        }
    }

    private func checkForUpdatesIfNeeded() async {
        guard autoCheckEnabled else { return }
        await performCheck(force: false, userInitiated: false)
    }

    private func performCheck(force: Bool, userInitiated: Bool) async {
        guard !isChecking else { return }

        if !force,
           let lastCheckedAt,
           Date().timeIntervalSince(lastCheckedAt) < 12 * 60 * 60 {
            return
        }

        isChecking = true
        defer { isChecking = false }

        do {
            var request = URLRequest(url: latestReleaseAPIURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("Clipin/\(currentVersion)", forHTTPHeaderField: "User-Agent")

            let (data, _) = try await session.data(for: request)
            let response = try decoder.decode(GitHubReleaseResponse.self, from: data)
            let fetchedAt = Date()

            let remoteVersion = Self.normalizedVersion(response.tagName)
            if Self.compareVersions(remoteVersion, currentVersion) == .orderedDescending {
                latestRelease = ReleaseInfo(
                    version: remoteVersion,
                    publishedAt: response.publishedAt,
                    notes: Self.normalizedNotes(response.body),
                    releasePageURL: response.htmlURL,
                    downloadURL: Self.preferredDownloadURL(from: response.assets)
                )
            } else {
                latestRelease = nil
            }

            lastCheckedAt = fetchedAt
            defaults.set(fetchedAt, forKey: Keys.lastCheckedAt)
            didLastCheckFail = false
        } catch {
            print("⚠️ Update check failed: \(error)")
            didLastCheckFail = true
            if userInitiated {
                lastCheckedAt = Date()
            }
        }
    }

    private static func preferredDownloadURL(from assets: [GitHubReleaseAsset]) -> URL? {
        let lowercased = assets.map { ($0, $0.name.lowercased()) }

        if let dmg = lowercased.first(where: { $0.1.hasSuffix(".dmg") })?.0.browserDownloadURL {
            return dmg
        }
        if let zip = lowercased.first(where: { $0.1.hasSuffix(".zip") })?.0.browserDownloadURL {
            return zip
        }
        return nil
    }

    private static func normalizedVersion(_ version: String) -> String {
        version.hasPrefix("v") ? String(version.dropFirst()) : version
    }

    private static func normalizedNotes(_ notes: String) -> String {
        notes
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let right = rhs.split(separator: ".").map { Int($0) ?? 0 }
        let count = max(left.count, right.count)

        for index in 0..<count {
            let leftPart = index < left.count ? left[index] : 0
            let rightPart = index < right.count ? right[index] : 0

            if leftPart != rightPart {
                return leftPart < rightPart ? .orderedAscending : .orderedDescending
            }
        }

        return .orderedSame
    }
}

private struct GitHubReleaseResponse: Decodable {
    let tagName: String
    let htmlURL: URL
    let publishedAt: Date?
    let body: String
    let assets: [GitHubReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case publishedAt = "published_at"
        case body
        case assets
    }
}

private struct GitHubReleaseAsset: Decodable {
    let name: String
    let browserDownloadURL: URL

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}
