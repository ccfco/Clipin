import Foundation
import AppKit

/// 远程 favicon 缓存：actor 串行化 + pending dedup + 磁盘持久化 + 多源回退。
///
/// 旧实现单上游写死 `google.com/s2/favicons`，重启即丢、且在中国大陆/离线场景容易长期 nil。
/// 当前实现：
/// 1. 启动即从磁盘 `~/Library/Application Support/Clipin/favicons/<origin>.png` 异步读回
///    in-memory cache；
/// 2. 取 favicon 时按"origin 直连 `/favicon.ico` → 根域 → HTML head 解析 → Google s2 兜底"顺序；
/// 3. 命中后异步写磁盘，TTL 7 天（避免站点换 favicon 后永久不更新）。
///
/// **关键设计：cache 持有 immutable `Data`（PNG），每次 `icon(for:)` 调用即时构造
/// 新的 `NSImage` 给 caller**。NSImage 内部 representations 可变非线程安全，如果让
/// UI 和后台磁盘写同一个 instance，会触发 race（AppKit 历史包袱：第一次 draw 时
/// lazy lock 到主线程，后台读 tiffRepresentation 同时绘制会并发 mutation）。
/// 把 cache 内层做成"序列化产物"，调用方每次都拿独立"渲染产物"，是唯一干净的解。
///
/// 拿不到就返回 nil，由调用方自己画占位，不在这里造假数据。
///
/// **抽象层级：以 origin (scheme://host:port) 为 key，而不是 host**。原因：
/// - host 只够定位"公网站点"（github.com 永远 :443/https），但用户剪贴板里也常出现
///   IP+port（vite dev `http://localhost:5173`、内网管理面板 `http://10.0.0.5:8080`、
///   Docker 容器 `http://112.44.253.74:9210` 等），这些不同端口可能跑完全不同的服务、
///   有完全不同的 favicon
/// - 浏览器的实现就是按 origin 抓 favicon（同 origin 同 favicon），与之对齐
/// - origin 经 normalize（去掉默认端口）保证 `https://github.com:443` 和
///   `https://github.com` 不重复缓存
actor FaviconCache {
    static let shared = FaviconCache()

    /// PNG-encoded immutable data。每次 caller 调用都构造新的 NSImage，避免共享可变实例。
    /// key 是 normalize 后的 origin 字符串。
    private var cache: [String: Data] = [:]
    private var pending: [String: Task<Data?, Never>] = [:]

    /// 7 天 TTL：favicon 改动频率远低于此，但也不至于让旧文件永远滞留。
    private static let diskTTL: TimeInterval = 7 * 24 * 3600

    private static let diskDir: URL = {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("Clipin/favicons", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    func icon(for url: URL) async -> NSImage? {
        guard let origin = Self.origin(of: url) else { return nil }

        if let data = cache[origin] { return NSImage(data: data) }
        if let task = pending[origin] {
            if let data = await task.value { return NSImage(data: data) }
            return nil
        }

        // 磁盘命中：填充 in-memory 后返回
        if let data = readDisk(origin: origin) {
            cache[origin] = data
            return NSImage(data: data)
        }

        let task = Task<Data?, Never> {
            await Self.fetchRemote(url: url, origin: origin)
        }
        pending[origin] = task
        let result = await task.value
        pending[origin] = nil
        if let data = result {
            cache[origin] = data
            // 写磁盘只需 Data，不再共享 NSImage 实例
            writeDisk(origin: origin, data: data)
            return NSImage(data: data)
        }
        return nil
    }

    /// 把 URL normalize 成 origin 字符串：scheme + host + 非默认 port。
    /// - `https://github.com` → `"https://github.com"`
    /// - `https://github.com:443/foo` → `"https://github.com"`（443 是 https 默认）
    /// - `http://112.44.253.74:9210/x` → `"http://112.44.253.74:9210"`
    /// - 非 http(s) scheme / 无 host → nil（不可缓存的 URL，调用方走兜底显示）
    ///
    /// host 大小写 normalize：DNS 不区分大小写，统一小写避免 GitHub.com / github.com 双份缓存。
    private static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        let normalizedHost = host.lowercased()
        if let port = url.port, !isDefaultPort(port, scheme: scheme) {
            return "\(scheme)://\(normalizedHost):\(port)"
        }
        return "\(scheme)://\(normalizedHost)"
    }

    private static func isDefaultPort(_ port: Int, scheme: String) -> Bool {
        (scheme == "https" && port == 443) || (scheme == "http" && port == 80)
    }

    /// fetchRemote 返回 PNG-encoded Data：在 detached task 内一次性把网络数据 normalize
    /// 成 PNG（用 NSBitmapImageRep 转码），后续 cache/磁盘/UI 三个消费方都基于这份
    /// immutable Data 各自构造独立 NSImage，杜绝跨线程共享 NSImage 实例。
    ///
    /// 多源回退顺序（按"命中率 × 速度"权衡）：
    /// 1. **origin 直连** `<origin>/favicon.ico` —— 保留传入 URL 的 scheme + port，
    ///    覆盖 IP+port 服务（vite/dev server、内网面板等）；约 50% 公网站点命中
    /// 2. **根域直连** `https://<root>/favicon.ico` —— 覆盖 SPA 子域：
    ///    docs.feishu.cn 没有但 feishu.cn 有。仅对域名生效，IP 跳过
    /// 3. **HTML head 解析** `<link rel="icon">` —— 覆盖飞书/Notion/各种 SaaS 把
    ///    favicon 放在 CDN 的场景；保留原 origin，相对路径 resolve 到 origin 上
    /// 4. **Google s2 服务** —— 仅对域名走（s2 只查 DNS 域名），IP 跳过避免浪费 4s
    private nonisolated static func fetchRemote(url: URL, origin: String) async -> Data? {
        var triedURLs = Set<String>()

        func tryURL(_ urlString: String) async -> Data? {
            guard !triedURLs.contains(urlString), let u = URL(string: urlString) else { return nil }
            triedURLs.insert(urlString)
            return await downloadAndNormalize(url: u)
        }

        let host = url.host ?? ""
        let hostIsIP = isIPAddress(host)

        // 第 1 源：origin 直连（保留 scheme + port，关键能力）
        if let data = await tryURL("\(origin)/favicon.ico") { return data }

        // 第 2 源：根域回退（仅对域名生效；IP 没有"根域"概念）
        if !hostIsIP, let root = rootDomain(of: host), root != host {
            if let data = await tryURL("https://\(root)/favicon.ico") { return data }
            if let data = await tryURL("https://www.\(root)/favicon.ico") { return data }
        }

        // 第 3 源：HTML head 解析。优先用传入的 origin（保留 port 和 scheme），
        // 失败再回退根域 https://；IP 只试自身 origin。
        var htmlOrigins: [String] = [origin]
        if !hostIsIP, let root = rootDomain(of: host) {
            let rootOrigin = "https://\(root)"
            if !htmlOrigins.contains(rootOrigin) { htmlOrigins.append(rootOrigin) }
        }
        for htmlOrigin in htmlOrigins where !triedURLs.contains("html:\(htmlOrigin)") {
            triedURLs.insert("html:\(htmlOrigin)")
            if let iconHref = await fetchIconFromHTML(origin: htmlOrigin),
               let data = await tryURL(iconHref) {
                return data
            }
        }

        // 第 4 源：Google s2 兜底（仅域名）
        if !hostIsIP,
           let data = await tryURL("https://www.google.com/s2/favicons?domain=\(host)&sz=128") {
            return data
        }

        return nil
    }

    /// 下载单个 URL → 校验是真实图片 → normalize 成 PNG Data。
    /// 抽出独立函数让各源共用，避免 fetchRemote 主流程被 NSImage/NSBitmapImageRep
    /// 校验码淹没（之前所有源都重复一遍 校验+转 PNG 的样板）。
    private nonisolated static func downloadAndNormalize(url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return nil
            }
            // 校验是真实图片且非 1×1 透明占位：本地 NSImage 仅用于校验，校验完即丢
            guard let probe = NSImage(data: data), probe.size.width > 1 else { return nil }
            // Normalize 到 PNG：ico / svg / unknown 格式统一编码，磁盘读回来能直接构造 NSImage
            if let tiff = probe.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                return png
            }
            // 罕见：probe 成功但转 PNG 失败 → 兜底原始 data
            return data
        } catch {
            return nil
        }
    }

    /// 拉 HTML head 部分，提取 `<link rel="...icon...">` 的 href。
    /// 使用 `Range: bytes=0-65535` 限制下载量（绝大多数站点 head 在前 64KB 内），
    /// 但有些 CDN 会忽略 Range 头返回完整 HTML —— 4s 超时是兜底安全网。
    private nonisolated static func fetchIconFromHTML(origin: String) async -> String? {
        guard let url = URL(string: "\(origin)/") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        request.setValue("bytes=0-65535", forHTTPHeaderField: "Range")
        // 部分站点根据 UA 切首页（移动版/PC 版），用通用 Safari UA 拿到完整 HTML
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return nil
            }
            guard let html = String(data: data, encoding: .utf8)
                  ?? String(data: data, encoding: .isoLatin1) else { return nil }

            // 解析候选：rel 必须包含 icon 字样；优先级 apple-touch-icon > icon > shortcut icon
            // （apple-touch-icon 通常是高分辨率 PNG，最适合预览面板的 64×64 显示尺寸）
            let candidates = parseIconLinks(in: html)
            guard let best = chooseBestIcon(candidates) else { return nil }

            // resolve 相对路径到完整 URL，相对的 base 就是 origin/，保留 port + scheme
            return URL(string: best, relativeTo: url)?.absoluteString
        } catch {
            return nil
        }
    }

    /// 解析 HTML 里所有 `<link rel="...icon..." href="...">` 标签。
    /// 用 NSRegularExpression 比 swift-html-parser 类的第三方库更轻量，
    /// favicon meta 标签结构简单稳定，正则覆盖足够。
    private nonisolated static func parseIconLinks(in html: String) -> [(rel: String, href: String, sizes: String?)] {
        // 只截取 <head>...</head> 区间，避免扫到 body 里的伪 link
        let headRange: Range<String.Index>
        if let openTag = html.range(of: "<head", options: .caseInsensitive),
           let closeTag = html.range(of: "</head>", options: .caseInsensitive, range: openTag.upperBound..<html.endIndex) {
            headRange = openTag.lowerBound..<closeTag.upperBound
        } else {
            // 没有 </head>（不完整 HTML） → 退而求其次扫描全部
            headRange = html.startIndex..<html.endIndex
        }
        let head = String(html[headRange])

        guard let linkRegex = try? NSRegularExpression(
            pattern: "<link[^>]*?>",
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return [] }

        let nsHead = head as NSString
        let matches = linkRegex.matches(in: head, range: NSRange(location: 0, length: nsHead.length))

        var results: [(String, String, String?)] = []
        for match in matches {
            let tag = nsHead.substring(with: match.range)
            guard let rel = extractAttribute(name: "rel", in: tag)?.lowercased(),
                  rel.contains("icon"),
                  let href = extractAttribute(name: "href", in: tag),
                  !href.isEmpty,
                  // 排除 data:image/svg+xml 之类的内联 SVG —— 通常是 1×1 灰度占位，
                  // NSImage 拿到也是无意义图标
                  !href.hasPrefix("data:") else { continue }
            let sizes = extractAttribute(name: "sizes", in: tag)
            results.append((rel, href, sizes))
        }
        return results
    }

    /// 在候选里挑最优 icon：apple-touch-icon（高分辨率 PNG）> 大 sizes 的 icon > 小 icon > shortcut icon。
    /// 这套优先级是 Safari 自己也用的——预览面板 64pt @2x = 128px，apple-touch-icon
    /// 默认 180px 完全够，且通常是 PNG 比 ICO 渲染干净。
    private nonisolated static func chooseBestIcon(_ candidates: [(rel: String, href: String, sizes: String?)]) -> String? {
        guard !candidates.isEmpty else { return nil }

        func score(_ candidate: (rel: String, href: String, sizes: String?)) -> Int {
            var s = 0
            if candidate.rel.contains("apple-touch-icon") { s += 100 }
            if candidate.rel == "icon" || candidate.rel.contains(" icon") || candidate.rel.hasSuffix("icon") { s += 50 }
            if candidate.rel.contains("shortcut") { s += 10 }
            // sizes 包含明确像素数（如 "192x192"）的优先
            if let sizes = candidate.sizes, sizes.contains("x") {
                let dims = sizes.lowercased().split(separator: "x")
                if let w = dims.first.flatMap({ Int($0) }) {
                    s += min(w, 512) / 8  // 上限避免 1024x1024 的 icon 拖垮决分
                }
            }
            return s
        }

        return candidates.max(by: { score($0) < score($1) })?.href
    }

    private nonisolated static func extractAttribute(name: String, in tag: String) -> String? {
        // 匹配 name="value" 或 name='value'，name 后允许空格
        guard let regex = try? NSRegularExpression(
            pattern: "\\b\(name)\\s*=\\s*[\"']([^\"']*)[\"']",
            options: .caseInsensitive
        ) else { return nil }
        let nsTag = tag as NSString
        guard let match = regex.firstMatch(in: tag, range: NSRange(location: 0, length: nsTag.length)),
              match.numberOfRanges >= 2 else { return nil }
        return nsTag.substring(with: match.range(at: 1))
    }

    /// 提取 host 的根域（去掉 www / 子域）。
    /// 简化版：把 host 切成 labels，保留最后两段；不处理 .co.uk / .com.cn 等多级 TLD
    /// （会把 example.com.cn 错切成 com.cn，但 favicon 仍可能在该域命中——这种情况
    /// 极少出现在剪贴板里）。返回 nil 表示传入的就是单段（如 localhost）。
    ///
    /// **入口已经过滤 IP**（fetchRemote 里 hostIsIP 检测），这里不必再判一次。
    private nonisolated static func rootDomain(of host: String) -> String? {
        let labels = host.split(separator: ".")
        guard labels.count >= 2 else { return nil }
        // 已经是两段（example.com），返回自身让上层与原 host 比较后跳过
        if labels.count == 2 { return host }
        // www 子域：去 www 后剩 2+ 段，递归调用一次
        if labels.first == "www" {
            return labels.dropFirst().joined(separator: ".")
        }
        // 普通子域 → 取最后两段
        return labels.suffix(2).joined(separator: ".")
    }

    /// 检测 host 是否是 IP 地址（IPv4 或 IPv6）。IP 不走根域回退也不走 s2 兜底。
    /// IPv4: 严格 4 段、每段 0..255。IPv6: host 含 `:`（IPv6 必含 `:`，域名永远不含）。
    private nonisolated static func isIPAddress(_ host: String) -> Bool {
        if host.contains(":") { return true } // IPv6
        let parts = host.split(separator: ".")
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard let n = Int(part) else { return false }
            return (0...255).contains(n)
        }
    }

    /// origin → 磁盘文件名 sanitize。
    /// origin 含 `://` 和可能的 `:port`，FileManager 会把 `/` 当路径分隔符，必须替换。
    /// 例：`http://112.44.253.74:9210` → `http___112.44.253.74_9210.png`
    private static func diskName(for origin: String) -> String {
        var safe = origin
        safe = safe.replacingOccurrences(of: "://", with: "___")
        safe = safe.replacingOccurrences(of: ":", with: "_")
        safe = safe.replacingOccurrences(of: "/", with: "_")
        return safe
    }

    private func diskFile(for origin: String) -> URL {
        Self.diskDir.appendingPathComponent(Self.diskName(for: origin)).appendingPathExtension("png")
    }

    private func readDisk(origin: String) -> Data? {
        let file = diskFile(for: origin)
        let fm = FileManager.default
        guard fm.fileExists(atPath: file.path),
              let attrs = try? fm.attributesOfItem(atPath: file.path),
              let modDate = attrs[.modificationDate] as? Date,
              Date().timeIntervalSince(modDate) < Self.diskTTL,
              let data = try? Data(contentsOf: file) else {
            return nil
        }
        return data
    }

    private nonisolated func writeDisk(origin: String, data: Data) {
        // 写磁盘走 detached：避免阻塞 actor 队列。Data 是值类型 Sendable，跨线程安全。
        let file = Self.diskDir
            .appendingPathComponent(Self.diskName(for: origin))
            .appendingPathExtension("png")
        Task.detached(priority: .utility) {
            try? data.write(to: file)
        }
    }
}
