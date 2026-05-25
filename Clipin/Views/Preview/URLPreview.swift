import AppKit
import SwiftUI

// MARK: - URL Preview

/// URL → 页面 title 的 in-memory 缓存。
///
/// 为什么 title 不像 favicon 一样磁盘缓存：
/// - title 易变（文档改名、CMS 后台编辑），磁盘缓存会让用户长期看到旧标题，比"重启失效"更误导
/// - title 是 per-URL 级（同一 host 不同 path 不同 title），缓存粒度比 favicon 细一个量级
/// - 用户对预览 title 的容忍度高于 favicon：标题缺失可以接受，标题错了反而 confusing
///
/// 拉的是用户那条具体 URL 的 HTML head，提取 `<title>` 和 `<meta property="og:title">`、
/// `<meta name="twitter:title">`，优先级 og:title > twitter:title > <title>（og 是社交分享专门
/// 优化过的版本，通常更精炼）。
actor URLMetadataCache {
    struct Snapshot: Sendable, Equatable {
        let title: String?
    }
    static let empty = Snapshot(title: nil)
    static let shared = URLMetadataCache()

    private var cache: [String: Snapshot] = [:]
    private var pending: [String: Task<Snapshot, Never>] = [:]
    /// in-memory 上限：launcher 列表分页 50 条，预留 4× 给最近浏览路径
    private let maxEntries = 200
    private var lru: [String] = []

    func metadata(for urlString: String) async -> Snapshot {
        if let cached = cache[urlString] {
            touch(urlString)
            return cached
        }
        if let task = pending[urlString] { return await task.value }

        let task = Task<Snapshot, Never> {
            await Self.fetch(urlString: urlString)
        }
        pending[urlString] = task
        let result = await task.value
        pending[urlString] = nil
        store(urlString, snapshot: result)
        return result
    }

    private func store(_ key: String, snapshot: Snapshot) {
        if cache[key] == nil, cache.count >= maxEntries, let evict = lru.first {
            cache.removeValue(forKey: evict)
            lru.removeFirst()
        }
        cache[key] = snapshot
        touch(key)
    }

    private func touch(_ key: String) {
        lru.removeAll { $0 == key }
        lru.append(key)
    }

    /// HTML head 下载大小上限 256KB：与 FaviconCache 同款防护（防服务器忽略 Range 返回超大页面）。
    private static let maxHTMLBytes = 256 * 1024

    /// query 里出现这些关键字时，跳过 title 抓取——避免"选中即 GET"消费一次性 token。
    ///
    /// 背景：用户从邮件/聊天里复制的链接常带一次性 token（magic link / 邮箱验证 /
    /// 退订链接）。RESTful 规范说 GET 应幂等无副作用，但真实 Web 里这类链接经常
    /// "GET 即消费"。Clipin 在用户"只是选中条目预览"时就自动 GET，比浏览器（要主动点击）
    /// 更激进——所以含敏感 token 的 URL 一律不抓 title，预览面板退化成只显示 URL 本身。
    ///
    /// 这是黑名单，不可能穷尽（攻击者可用任意 key 名），但能挡住绝大多数常见命名。
    private static let sensitiveQueryKeys: Set<String> = [
        "token", "access_token", "id_token", "auth", "authorization",
        "verify", "verification", "confirm", "confirmation",
        "unsubscribe", "session", "sessionid", "sid",
        "code", "otp", "magic", "secret", "apikey", "api_key", "key",
        "reset", "password", "passwd", "signature", "sig",
    ]

    /// URL 是否带敏感 token query —— 命中则不应自动 GET。
    private nonisolated static func hasSensitiveToken(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems else { return false }
        return items.contains { sensitiveQueryKeys.contains($0.name.lowercased()) }
    }

    private nonisolated static func fetch(urlString: String) async -> Snapshot {
        guard let url = URL(string: urlString) else { return Snapshot(title: nil) }
        // 含一次性 token 的链接：不自动 GET，避免在用户仅"选中预览"时消费掉 token
        if hasSensitiveToken(url) { return Snapshot(title: nil) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        // 限制下载量：HTML head 在前 64KB 内的概率 >95%，部分 CDN 忽略 Range 也有 4s 兜底
        request.setValue("bytes=0-65535", forHTTPHeaderField: "Range")
        // 部分站点按 UA 切版本（移动版 vs PC 版），用通用 Safari UA 保证拿到完整 meta
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        // 经 FaviconCache.downloadWithLimit 限制响应大小，防服务器忽略 Range 返回超大页面
        guard let data = await FaviconCache.downloadWithLimit(request, maxBytes: maxHTMLBytes) else {
            return Snapshot(title: nil)
        }
        guard let html = String(data: data, encoding: .utf8)
              ?? String(data: data, encoding: .isoLatin1) else {
            return Snapshot(title: nil)
        }
        return Snapshot(title: extractTitle(from: html))
    }

    /// 提取 title 优先级：og:title > twitter:title > <title>。
    /// og:title 是开源协议（OpenGraph），所有现代 CMS / SaaS 都在服务端注入 —— 这是
    /// 飞书/Notion/GitHub 等 SPA 的 title 能被其他应用拿到的真正信源（HTML 实际 <title>
    /// 在 SPA 里通常是 client-side 渲染后才填，单次拉 HTML 拿不到）。
    private nonisolated static func extractTitle(from html: String) -> String? {
        // 截 head 范围（如果有），避免扫到 body 里的 og 标签碎片
        let scope: String
        if let openTag = html.range(of: "<head", options: .caseInsensitive),
           let closeTag = html.range(of: "</head>", options: .caseInsensitive, range: openTag.upperBound..<html.endIndex) {
            scope = String(html[openTag.lowerBound..<closeTag.upperBound])
        } else {
            scope = html
        }

        // 1. og:title
        if let og = extractMetaContent(in: scope, property: "og:title"), !og.isEmpty {
            return decodeHTMLEntities(og)
        }
        // 2. twitter:title
        if let tw = extractMetaContent(in: scope, name: "twitter:title"), !tw.isEmpty {
            return decodeHTMLEntities(tw)
        }
        // 3. <title>
        if let titleRegex = try? NSRegularExpression(
            pattern: "<title[^>]*>([\\s\\S]*?)</title>",
            options: .caseInsensitive
        ) {
            let nsScope = scope as NSString
            if let match = titleRegex.firstMatch(in: scope, range: NSRange(location: 0, length: nsScope.length)),
               match.numberOfRanges >= 2 {
                let raw = nsScope.substring(with: match.range(at: 1))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !raw.isEmpty { return decodeHTMLEntities(raw) }
            }
        }
        return nil
    }

    /// 匹配 `<meta property="og:title" content="...">` 或 `<meta name="..." content="...">`，
    /// 也允许 property/content 颠倒顺序。
    private nonisolated static func extractMetaContent(in html: String, property: String? = nil, name: String? = nil) -> String? {
        let attrName: String
        let attrValue: String
        if let property {
            attrName = "property"
            attrValue = property
        } else if let name {
            attrName = "name"
            attrValue = name
        } else { return nil }

        // 两种 attr 顺序都要匹配：property 在前 content 在后，或反之
        let patterns = [
            "<meta\\s[^>]*\\b\(attrName)\\s*=\\s*[\"']\(attrValue)[\"'][^>]*\\bcontent\\s*=\\s*[\"']([^\"']*)[\"'][^>]*>",
            "<meta\\s[^>]*\\bcontent\\s*=\\s*[\"']([^\"']*)[\"'][^>]*\\b\(attrName)\\s*=\\s*[\"']\(attrValue)[\"'][^>]*>",
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            let nsHTML = html as NSString
            if let match = regex.firstMatch(in: html, range: NSRange(location: 0, length: nsHTML.length)),
               match.numberOfRanges >= 2 {
                return nsHTML.substring(with: match.range(at: 1))
            }
        }
        return nil
    }

    /// 把常见 HTML 实体（&amp; &lt; &gt; &quot; &#39; &nbsp;）还原。
    /// 用 NSAttributedString 解码完整 HTML 太重（会启动 WebKit），实体替换轻量足够。
    private nonisolated static func decodeHTMLEntities(_ s: String) -> String {
        var out = s
        let map: [(String, String)] = [
            ("&amp;", "&"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&quot;", "\""),
            ("&#39;", "'"),
            ("&apos;", "'"),
            ("&nbsp;", " "),
            ("&#x27;", "'"),
        ]
        for (entity, char) in map {
            out = out.replacingOccurrences(of: entity, with: char)
        }
        return out
    }
}

struct FaviconView: View {
    let url: URL?
    @State private var image: NSImage?
    @State private var loadFinished = false

    var body: some View {
        ZStack {
            // 三态：① 还在拉取 → globe 占位（不知道结果，不画字母圈）
            //       ② 拉到 favicon → 显示图标
            //       ③ 拉取失败 / 没 host → 字母圈兜底（host 首字母 + hash 色）
            if let image {
                RoundedRectangle(cornerRadius: ClipinChrome.cornerControl, style: .continuous)
                    .fill(Color(nsColor: .controlColor))
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(ClipinChrome.groupGap)
            } else if loadFinished, let host = url?.host, !host.isEmpty {
                FaviconLetterMark(host: host)
            } else {
                RoundedRectangle(cornerRadius: ClipinChrome.cornerControl, style: .continuous)
                    .fill(Color(nsColor: .controlColor))
                Image(systemName: "globe")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(ClipinInk.secondary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: ClipinChrome.cornerControl, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ClipinChrome.cornerControl, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.6)
        )
        .task(id: url?.absoluteString ?? "") {
            image = nil
            loadFinished = false
            guard let url, let host = url.host, !host.isEmpty else {
                loadFinished = true
                return
            }
            let fetched = await FaviconCache.shared.icon(for: url)
            // 快速切 URL 时旧请求的网络响应可能晚到：`.task(id:)` 在 id 变化时自动取消
            // 旧 task，await 返回后 `Task.isCancelled` 即为 true，丢弃陈旧结果。
            guard !Task.isCancelled else { return }
            image = fetched
            loadFinished = true
        }
    }
}

/// favicon 拿不到时的兜底视觉：host 首字母 + 基于 host hash 的稳定背景色。
/// 同一 host 永远是同一种颜色（hash 决定），让用户在剪贴板历史里还能凭"颜色块"
/// 二次识别站点（即使叫不出名字也能看出"那一抹紫色的就是我之前看的那条"）。
///
/// 颜色生成不用 SwiftUI 默认 `.background(Color.red)` 这种饱和色——
/// 用 HSL 固定 saturation/brightness、只变 hue，保证所有字母圈视觉权重一致，
/// 不会让某个字母圈意外抢夺注意力。
struct FaviconLetterMark: View {
    let host: String

    private var letter: String {
        // 用 host 第一段（去掉 www）的首字母。
        // "docs.feishu.cn" → "D"（不是 "d"，preview 视觉一致要大写）
        // "www.github.com" → "G"
        // "localhost" → "L"
        let lower = host.lowercased()
        let parts = lower.split(separator: ".")
        let firstMeaningful = parts.first(where: { $0 != "www" }) ?? parts.first ?? Substring(host)
        return String(firstMeaningful.first ?? Character("?")).uppercased()
    }

    private var backgroundColor: Color {
        // host → 稳定 hash → HSL hue。
        // 不用 Hasher（Hasher 每次进程启动种子不同 → 同一 host 颜色会变），
        // 改用 FNV-1a 的简化版本，保证跨启动一致。
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in host.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        let hue = Double(hash % 360) / 360.0
        // saturation 0.55 / brightness 0.62 是经验值：饱和度足以区分相邻 hue，
        // 又不至于刺眼；白字在上面对比度也够。
        return Color(hue: hue, saturation: 0.55, brightness: 0.62)
    }

    var body: some View {
        backgroundColor
            .overlay(
                Text(letter)
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
            )
    }
}

struct URLPreviewView: View {
    let urlString: String
    let searchQuery: String
    @EnvironmentObject var vm: ClipboardViewModel
    /// 从 URLMetadataCache 异步拉取的页面标题；nil 表示尚未加载或拉不到。
    /// 加载完成后会显示在 header 顶部，host 退到次行——同其他应用对齐。
    @State private var pageTitle: String?

    private var url: URL? { URL(string: urlString) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ClipinChrome.groupGap) {
                header
                fullURLBlock
                if let url, !queryItems(for: url).isEmpty {
                    queryBlock(items: queryItems(for: url))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: 560, maxHeight: .infinity, alignment: .topLeading)
        .task(id: urlString) {
            pageTitle = nil
            let requested = urlString
            let snapshot = await URLMetadataCache.shared.metadata(for: requested)
            // 快速切条目时旧 URL 的响应可能晚到 → guard 当前仍在显示同一 URL
            guard !Task.isCancelled, requested == urlString else { return }
            pageTitle = snapshot.title
        }
    }

    private var header: some View {
        HStack(spacing: ClipinChrome.groupGap) {
            FaviconView(url: url)
                .frame(width: 64, height: 64)

            // title 取到 → 大字 title + 次行 host[+path]；
            // 没取到 → 退化成原来的"host 在顶、path 在副"——首屏加载完成前的稳态。
            VStack(alignment: .leading, spacing: ClipinChrome.gap) {
                if let pageTitle, !pageTitle.isEmpty {
                    Text(pageTitle)
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .textSelection(.enabled)

                    Text(hostWithPath)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(ClipinInk.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text(url?.host ?? urlString)
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)

                    if let subtitle = pathSubtitle {
                        Text(subtitle)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(ClipinInk.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let url {
                Link(destination: url) {
                    HStack(spacing: ClipinChrome.gap) {
                        Image(systemName: "safari")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Open")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .padding(.horizontal, ClipinChrome.groupGap)
                    .padding(.vertical, ClipinChrome.gap)
                    .foregroundStyle(Color.accentColor)
                    .clipinChromeGlass(in: Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .help("Open in default browser")
            }
        }
    }

    /// 有 title 时副行用 `host + path` 显示完整位置感
    private var hostWithPath: String {
        guard let url else { return urlString }
        let host = url.host ?? ""
        if !url.path.isEmpty, url.path != "/" {
            return host + url.path
        }
        return host
    }

    private var pathSubtitle: String? {
        guard let url else { return nil }
        if !url.path.isEmpty, url.path != "/" { return url.path }
        return nil
    }

    private var fullURLBlock: some View {
        urlInfoBlock(title: "Full URL", systemImage: "link", trailing: {
            // 仅当存在已知 tracking 参数时显示"Copy clean URL"，避免在干净 URL 上误导。
            if let cleaned = cleanedURLString, cleaned != urlString {
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(cleaned, forType: .string)
                    vm.showNotice(NSLocalizedString("Clean URL copied", comment: ""))
                } label: {
                    HStack(spacing: ClipinChrome.gap) {
                        Image(systemName: "scissors")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Clean copy")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, ClipinChrome.gap)
                    .padding(.vertical, ClipinChrome.gap)
                    .foregroundStyle(ClipinInk.secondary)
                    .clipinChromeGlass(in: Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .help("Copy URL without tracking parameters (utm_*, fbclid, gclid, mc_*)")
            }
        }) {
            SelectableTextPreview(
                text: urlString,
                font: .monospacedSystemFont(ofSize: 12.5, weight: .regular),
                searchQuery: searchQuery,
                vm: vm
            )
            .frame(minHeight: 44, maxHeight: 92)
        }
    }

    /// 借用 ClearURLs 社区维护的 200+ provider 规则做 tracking 清理。
    /// 引擎自写（零 Swift 依赖），数据嵌入在 Clipin/Resources/clearurls-rules.json。
    /// 返回 nil 表示无需清理（原 URL 已干净，不应显示 "Clean copy" 按钮）。
    private var cleanedURLString: String? {
        let result = URLTrackingCleaner.shared.clean(urlString)
        return result.didModify ? result.cleaned : nil
    }

    private func queryItems(for url: URL) -> [(String, String)] {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems else { return [] }
        return items.map { ($0.name, $0.value ?? "") }
    }

    private func queryBlock(items: [(String, String)]) -> some View {
        urlInfoBlock(title: "Query parameters", systemImage: "questionmark.app") {
            VStack(spacing: ClipinChrome.gap) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, pair in
                    HStack(alignment: .top, spacing: ClipinChrome.groupGap) {
                        Text(pair.0)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(ClipinInk.secondary)
                            .frame(width: 96, alignment: .leading)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .textSelection(.enabled)
                        Text(pair.1)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(ClipinInk.primary)
                            .lineLimit(3)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private func urlInfoBlock<Content: View, Trailing: View>(
        title: LocalizedStringKey,
        systemImage: String,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() },
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: ClipinChrome.gap) {
            HStack(spacing: ClipinChrome.gap) {
                Label(title, systemImage: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ClipinInk.secondary)
                Spacer(minLength: 6)
                trailing()
            }
            content()
        }
        .padding(ClipinChrome.groupGap)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
