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
    @Published private(set) var activeReminder: ReleaseInfo?
    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var isChecking = false
    @Published private(set) var didLastCheckFail = false

    let currentVersion: String
    let currentBuild: String
    /// CFBundleVersion 的整数形式。Sparkle 自己判断"是否有更新"用它,不是 marketing 版本号
    /// ——检测层必须跟它对齐,否则"同 marketing version、不同 build"的重发会出现 Sparkle
    /// 判定有更新、这里却判定没有的分裂(Niche 同款集成实测踩过)。
    private let currentBuildNumber: Int

    private let defaults = UserDefaults.standard
    private let session: URLSession
    /// 检测源是 appcast.xml(raw.githubusercontent.com 静态 CDN),不是 api.github.com——
    /// 后者未认证限额 60 次/小时且按 IP 算,共享出口 IP 极易被其它流量打满,一旦打满检测层
    /// (菜单栏红点/设置页/Sparkle 安装入口)全部瘫痪(Niche 同款集成实测踩过)。
    private let appcastURL = URL(string: "https://raw.githubusercontent.com/ccfco/Clipin/main/appcast.xml")!
    /// release notes 正文的补数据源:appcast.xml 不带这段文本,这里另开一个同样不受
    /// api.github.com 限流影响的静态 feed(GitHub 网站侧的 Atom feed,不是 REST API)。
    private let releasesAtomURL = URL(string: "https://github.com/ccfco/Clipin/releases.atom")!
    private let releasesPageURL = URL(string: "https://github.com/ccfco/Clipin/releases/latest")!
    private let releasesListURL = URL(string: "https://github.com/ccfco/Clipin/releases")!
    private var periodicCheckTimer: Timer?
    private var didStart = false

    private enum Keys {
        static let autoCheckEnabled = "updates.autoCheckEnabled"
        static let lastCheckedAt = "updates.lastCheckedAt"
        static let dismissedReminderVersion = "updates.dismissedReminderVersion"
    }

    private var dismissedReminderVersion: String? {
        didSet { defaults.set(dismissedReminderVersion, forKey: Keys.dismissedReminderVersion) }
    }

    private init() {
        currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        currentBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        currentBuildNumber = Int(currentBuild) ?? 0
        autoCheckEnabled = defaults.object(forKey: Keys.autoCheckEnabled) as? Bool ?? true
        lastCheckedAt = defaults.object(forKey: Keys.lastCheckedAt) as? Date
        dismissedReminderVersion = defaults.string(forKey: Keys.dismissedReminderVersion)

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
            // 关再开：原 timer 若已被 invalidate 需重新调度。schedulePeriodicChecks 是幂等的
            schedulePeriodicChecks()
            Task { [weak self] in
                await self?.checkForUpdatesIfNeeded()
            }
        } else {
            // 用户关闭自动检查时主动停掉 timer，避免「timer 仍每 6 小时跑 + 函数体里 guard
            // autoCheckEnabled else { return }」这种"空转兜底"残留。timer 不耗显著 CPU，
            // 但生命周期不可见的对象越少越好
            periodicCheckTimer?.invalidate()
            periodicCheckTimer = nil
        }
    }

    func checkNow() {
        Task { [weak self] in
            await self?.performCheck(force: true, userInitiated: true)
        }
    }

    /// 明确「忽略此版本」：持久化 dismissedReminderVersion，之后同版本不再弹 banner。
    /// 仅供用户主动打发的入口（Later / 看过 Release 页）使用。
    func dismissActiveReminder() {
        guard let version = activeReminder?.version ?? latestRelease?.version else { return }
        dismissedReminderVersion = version
        activeReminder = nil
    }

    /// 只收起 banner，不持久化忽略。供「开始安装 / Esc / 关窗」使用：
    /// 安装可能失败（找不到 appcast item、下载/验签失败），此时必须保留提醒能力，
    /// 不能把「点了安装」误当成「永久忽略」——否则失败后用户再也收不到提醒。
    func closeActiveReminder() {
        activeReminder = nil
    }

    func openReleasePage() {
        dismissActiveReminder()
        NSWorkspace.shared.open(latestRelease?.releasePageURL ?? releasesPageURL)
    }

    /// 打开 releases 列表页（全部历史版本），与 openReleasePage 区别在于不打开 /latest
    func openReleasesListPage() {
        NSWorkspace.shared.open(releasesListURL)
    }

    /// Sparkle 安装闭包，由 AppDelegate.setupSparkle() 注入。
    /// nil 时回退打开下载 URL（兜底路径，不应发生）。
    var installHandler: (() -> Void)?

    func installUpdate() {
        guard let installHandler else {
            // installHandler 由 setupSparkle() 在启动时无条件注入；nil 只意味着集成断裂
            // （setupSparkle 没跑 / Sparkle 初始化失败）。这是 bug 不是正常路径：
            // assertionFailure 在 debug 当场暴露，os_log error 让 release 也能浮出问题。
            // 不静默——记了日志 + 断言就不是「兜底吞异常」；仍打开下载页只是别让用户彻底卡死。
            ClipinLog.update.error("installUpdate called but installHandler is nil — Sparkle setup missing")
            assertionFailure("installHandler not injected; setupSparkle() must run at launch")
            let targetURL = latestRelease?.downloadURL ?? latestRelease?.releasePageURL ?? releasesPageURL
            NSWorkspace.shared.open(targetURL)
            return
        }
        installHandler()
    }

    func downloadLatestRelease() {
        installUpdate()
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
            var request = URLRequest(url: appcastURL)
            request.setValue("Clipin/\(currentVersion)", forHTTPHeaderField: "User-Agent")

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            let fetchedAt = Date()

            let parser = AppcastParser()
            let xmlParser = XMLParser(data: data)
            xmlParser.delegate = parser
            guard xmlParser.parse() else { throw URLError(.cannotParseResponse) }

            // appcast 可能累积多条历史 item(generate_appcast 不裁剪旧条目);挑 build number
            // 最大的一条——必须按 build number(Sparkle 的真实判断依据)排序,不能按 marketing
            // 版本号,否则"同 marketing version、不同 build"的条目会被错误地并列/丢弃。
            let candidate = parser.items
                .compactMap { item -> (version: String, buildNumber: Int, downloadURL: URL, pubDate: Date?)? in
                    guard let version = item.version, Self.isNumericVersion(version),
                          let buildNumber = item.buildNumber,
                          let downloadURL = item.downloadURL else { return nil }
                    return (version, buildNumber, downloadURL, item.pubDate)
                }
                .max { $0.buildNumber < $1.buildNumber }

            if let candidate, candidate.buildNumber > currentBuildNumber {
                let notes = await Self.fetchReleaseNotes(version: candidate.version, atomURL: releasesAtomURL, session: session)
                let release = ReleaseInfo(
                    version: candidate.version,
                    publishedAt: candidate.pubDate,
                    notes: notes,
                    releasePageURL: URL(string: "https://github.com/ccfco/Clipin/releases/tag/v\(candidate.version)")!,
                    downloadURL: candidate.downloadURL
                )
                latestRelease = release
                if !userInitiated, dismissedReminderVersion != release.version {
                    activeReminder = release
                }
            } else {
                latestRelease = nil
                activeReminder = nil
            }

            lastCheckedAt = fetchedAt
            defaults.set(fetchedAt, forKey: Keys.lastCheckedAt)
            didLastCheckFail = false
        } catch {
            ClipinLog.update.error("Update check failed: \(error.localizedDescription, privacy: .public)")
            didLastCheckFail = true
            if userInitiated {
                lastCheckedAt = Date()
            }
        }
    }

    /// 是否为纯数字点分版本（1 / 1.2 / 1.2.0）。拒绝 beta/rc/hotfix 等非数字段，仅用于显示
    /// 前的脏数据兜底(判定"是否有更新"已改用 build number,不再靠这个字符串比较)。
    private static func isNumericVersion(_ version: String) -> Bool {
        !version.isEmpty && version.split(separator: ".").allSatisfy { segment in
            !segment.isEmpty && segment.allSatisfy(\.isNumber)
        }
    }

    private static func normalizedNotes(_ notes: String) -> String {
        notes
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// releases.atom 是 GitHub 网站侧的静态 Atom feed,不走 api.github.com,不受那个限流
    /// 影响。只用来补 release notes 正文——appcast.xml 不带这段文本。best-effort:失败/
    /// 找不到匹配条目都只是 notes 留空,不影响版本检测本身(检测已由 appcast.xml 独立完成)。
    private static func fetchReleaseNotes(version: String, atomURL: URL, session: URLSession) async -> String {
        do {
            var request = URLRequest(url: atomURL)
            request.setValue("Clipin/\(version)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return "" }

            let parser = ReleaseNotesAtomParser()
            let xmlParser = XMLParser(data: data)
            xmlParser.delegate = parser
            guard xmlParser.parse() else { return "" }

            guard let entry = parser.entries.first(where: { $0.tagVersion == version }),
                  let html = entry.contentHTML else { return "" }
            return normalizedNotes(plainText(fromHTML: html))
        } catch {
            ClipinLog.update.error("Fetching release notes failed: \(error.localizedDescription, privacy: .public)")
            return ""
        }
    }

    /// release notes 在 atom feed 里是渲染后的 HTML(XMLParser 已经把 XML 实体解码成字面
    /// 标签),块级标签折成换行、其余标签直接去掉——只是给 banner/设置页的预览用,不需要
    /// 保留富文本结构。
    private static func plainText(fromHTML html: String) -> String {
        var text = html
        text = text.replacingOccurrences(
            of: "(?i)</?(h[1-6]|p|li|br|ul|ol)[^>]*>", with: "\n", options: .regularExpression
        )
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let lines = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.joined(separator: "\n")
    }
}

/// Sparkle appcast(标准 RSS + sparkle 命名空间)的最小化解析器,只取 UpdateReminderService
/// 需要的四个字段。不用 shouldProcessNamespaces,elementName 直接拿到
/// "sparkle:shortVersionString" 这种限定名。
private final class AppcastParser: NSObject, XMLParserDelegate {
    struct Item {
        var version: String?
        var buildNumber: Int?
        var pubDate: Date?
        var downloadURL: URL?
    }

    private(set) var items: [Item] = []
    private var current: Item?
    private var currentElement = ""
    private var pubDateText = ""
    private var buildNumberText = ""

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName
        switch elementName {
        case "item":
            current = Item()
        case "enclosure":
            if let urlString = attributeDict["url"] {
                current?.downloadURL = URL(string: urlString)
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        switch currentElement {
        case "sparkle:shortVersionString":
            let appended = (current?.version ?? "") + string
            current?.version = appended
        case "sparkle:version":
            buildNumberText += string
        case "pubDate":
            pubDateText += string
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "pubDate" {
            pubDateText = pubDateText.trimmingCharacters(in: .whitespacesAndNewlines)
            current?.pubDate = Self.rfc822Formatter.date(from: pubDateText)
            pubDateText = ""
        }
        if elementName == "sparkle:shortVersionString" {
            let trimmed = current?.version?.trimmingCharacters(in: .whitespacesAndNewlines)
            current?.version = trimmed
        }
        if elementName == "sparkle:version" {
            current?.buildNumber = Int(buildNumberText.trimmingCharacters(in: .whitespacesAndNewlines))
            buildNumberText = ""
        }
        if elementName == "item", let item = current {
            items.append(item)
            current = nil
        }
        // 结束标签后立刻清空,否则标签间的换行/缩进空白会被 foundCharacters 当作
        // 仍在当前标签内、误追加进 version/pubDate/buildNumber。
        currentElement = ""
    }

    private static let rfc822Formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter
    }()
}

/// GitHub releases.atom 的最小化解析器,只取匹配 release notes 正文需要的两个字段:
/// tag 版本号(从 <link rel="alternate" href=".../tag/vX.Y.Z"> 取)、<content type="html"> 正文。
private final class ReleaseNotesAtomParser: NSObject, XMLParserDelegate {
    struct Entry {
        var tagVersion: String?
        var contentHTML: String?
    }

    private(set) var entries: [Entry] = []
    private var current: Entry?
    private var capturingContent = false
    private var contentText = ""

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
    ) {
        switch elementName {
        case "entry":
            current = Entry()
        case "link":
            if attributeDict["rel"] == "alternate", let href = attributeDict["href"],
               let range = href.range(of: "/tag/v", options: .backwards) {
                current?.tagVersion = String(href[range.upperBound...])
            }
        case "content":
            capturingContent = true
            contentText = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturingContent {
            contentText += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "content" {
            current?.contentHTML = contentText
            capturingContent = false
            contentText = ""
        }
        if elementName == "entry", let entry = current {
            entries.append(entry)
            current = nil
        }
    }
}
