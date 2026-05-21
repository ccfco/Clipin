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

    /// 单个 icon 候选：HTML `<link rel="...">` 标签或隐式 `/favicon.ico` 都用同一种类型表达。
    /// 通过统一候选模型，所有可能的 favicon 信源都参与同一次评分排序——避免之前 4 源串行
    /// "试一个等超时再试下一个"的累加延迟。
    private struct IconCandidate {
        let rel: String        // "icon" / "apple-touch-icon" / "shortcut icon"
        let href: String       // 可能是相对路径（"/icon.png"）或绝对 URL
        let sizes: String?     // "32x32" / "180x180" / nil（隐式 /favicon.ico 没 sizes 信息）
        let baseURL: URL       // 用于 resolve 相对 href 到完整 URL
    }

    /// 浏览器风格 favicon 抓取（借鉴 Chromium FaviconHandler + Firefox places favicon service）：
    ///
    /// **核心哲学**：先轻量收集所有候选元数据（href + sizes 声明），再用评分函数选最佳，
    /// 最后单次下载选定的图片字节。区别于之前的"多源串行回退"——后者会在最佳源失败后
    /// 退而求其次下载次优 icon（如 32×32 ico 而不是 180×180 apple-touch-icon）。
    ///
    /// 三阶段：
    /// 1. **候选收集**（并行）：拉 origin / 根域的 HTML head 64KB，解析 `<link rel="icon">`。
    ///    候选只是 href 元数据，**不下载图片字节**——这是性能关键，HTML head 64KB 比图片
    ///    完整下载轻 10×
    /// 2. **隐式 fallback 候选**：始终给候选列表追加 `<origin>/favicon.ico`（IP 服务）和
    ///    `https://<root>/favicon.ico`（域名）。这是浏览器对"HTML 没声明 icon"的隐式
    ///    fallback——大多数老站点不声明 icon link，但 /favicon.ico 路径有图
    /// 3. **评分排序 + top-K 下载**：chooseBestIcon 按 apple-touch-icon > icon > sizes
    ///    从高到低排序。下载 top-2，第一个成功就用。top-2 是为了 best 失败时还能 fallback
    ///    到次优，最坏 2 × 4s = 8s（vs 之前 4 源串行最坏 24s）
    ///
    /// 删除 Google s2 第三方代理：浏览器从不用代理，s2 自己也是用 HTML+ico 抓 favicon，
    /// 我们直连比绕一层更准；ATS 放开后没有"HTTP 拉不到只能靠 s2 HTTPS"的需求。
    private nonisolated static func fetchRemote(url: URL, origin: String) async -> Data? {
        let host = url.host ?? ""
        let hostIsIP = isIPAddress(host)
        let root = hostIsIP ? nil : rootDomain(of: host)
        let needsRootFallback = !hostIsIP && root != nil && root != host

        // === 阶段 1: 并行收集 HTML 候选 ===
        // origin HTML 几乎总要看（除非 origin 拉不通）；根域 HTML 仅对子域有意义。
        async let originCandidates = collectCandidates(from: origin)
        async let rootCandidates: [IconCandidate] = needsRootFallback
            ? collectCandidates(from: "https://\(root!)")
            : []

        var allCandidates = await originCandidates
        allCandidates.append(contentsOf: await rootCandidates)

        // === 阶段 2: 加入隐式 /favicon.ico 候选 ===
        // 评分基础分 50（与 rel="icon" 同分），低于 apple-touch-icon（100）。
        // 如果 HTML 声明了高优先级 icon link，会优先选 HTML 的；HTML 没声明的话隐式 ico 兜底。
        if let originURL = URL(string: origin) {
            allCandidates.append(IconCandidate(
                rel: "icon", href: "/favicon.ico", sizes: nil, baseURL: originURL
            ))
        }
        if needsRootFallback, let r = root, let rootURL = URL(string: "https://\(r)") {
            allCandidates.append(IconCandidate(
                rel: "icon", href: "/favicon.ico", sizes: nil, baseURL: rootURL
            ))
        }

        // === 阶段 3: 评分排序 → 下载 top-2 ===
        // top-2 是 best 失败时的 fallback：apple-touch-icon 链接如果服务器 404（站点 HTML 错），
        // 我们仍能下载到次优 icon。极端最坏 2 × 4s = 8s。
        let sorted = allCandidates.sorted { score(of: $0) > score(of: $1) }
        for candidate in sorted.prefix(2) {
            guard let resolved = URL(string: candidate.href, relativeTo: candidate.baseURL)?.absoluteURL,
                  let data = await downloadAndNormalize(url: resolved) else { continue }
            return data
        }
        return nil
    }

    /// 拉 `<origin>/` 的 HTML head 64KB，解析所有 `<link rel="...icon...">` 候选。
    /// 失败（网络错 / 非 2xx / 解析失败）返回空数组——不抛错，让上层用其它候选 fallback。
    ///
    /// 注意：函数名从"fetchIconFromHTML（返回单个 best href）"改成"collectCandidates（返回所有候选）"，
    /// 反映新的设计哲学——HTML 解析只负责"提供候选"，"选最佳"留给上层统一评分。
    private nonisolated static func collectCandidates(from origin: String) async -> [IconCandidate] {
        guard let url = URL(string: "\(origin)/") else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        // Range 64KB：绝大多数站点 head 在前 64KB 内，避免下载完整页面浪费带宽。
        // 部分 CDN 忽略 Range 返回完整 HTML —— 4s 超时是兜底安全网。
        request.setValue("bytes=0-65535", forHTTPHeaderField: "Range")
        // Safari UA：部分站点按 UA 切版本（移动版 vs PC 版），通用 UA 拿到完整 head
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return []
            }
            guard let html = String(data: data, encoding: .utf8)
                  ?? String(data: data, encoding: .isoLatin1) else { return [] }
            return parseIconLinks(in: html, baseURL: url)
        } catch {
            return []
        }
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

    /// 解析 HTML 里所有 `<link rel="...icon..." href="...">` 标签，返回 IconCandidate 数组。
    /// 用 NSRegularExpression 比 swift-html-parser 类的第三方库更轻量，
    /// favicon meta 标签结构简单稳定，正则覆盖足够。
    ///
    /// baseURL 用于后续 resolve 相对 href（"/icon.png" → "https://example.com/icon.png"）；
    /// 这里不立即 resolve 而是把 baseURL 存进 IconCandidate，让上层评分排序后再 resolve。
    private nonisolated static func parseIconLinks(in html: String, baseURL: URL) -> [IconCandidate] {
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

        var results: [IconCandidate] = []
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
            results.append(IconCandidate(rel: rel, href: href, sizes: sizes, baseURL: baseURL))
        }
        return results
    }

    /// 对单个候选评分：apple-touch-icon（高分辨率 PNG）> 大 sizes 的 icon > 小 icon > shortcut icon。
    /// 这套优先级是 Safari 自己也用的——预览面板 64pt @2x = 128px，apple-touch-icon
    /// 默认 180px 完全够，且通常是 PNG 比 ICO 渲染干净。
    ///
    /// 提到 file-level 是因为 fetchRemote 阶段 3 的排序也要用同一份评分逻辑——把它锁在
    /// chooseBestIcon 内部会导致 sort 时要重复实现一遍。
    private nonisolated static func score(of candidate: IconCandidate) -> Int {
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
