import Foundation
import AppKit

/// 远程 favicon 缓存：actor 串行化 + pending dedup + 磁盘持久化 + 浏览器风格抓取。
///
/// 当前实现：
/// 1. 启动即从磁盘 `~/Library/Application Support/Clipin/favicons/<origin>.png` 异步读回
///    in-memory cache；
/// 2. 取 favicon 时按"候选收集 → 评分选最佳 → 单次下载"的浏览器风格抓取
///    （参考 Chromium FaviconHandler / Firefox places favicon service）；
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

    /// in-memory LRU：避免长 session 里用户复制大量不同站点 URL 导致 cache 无界增长。
    /// 命中/写入时 touch，超 maxEntries 时淘汰最久未访问的。磁盘文件不受影响（仍由 7 天 TTL 管）。
    private var lru: [String] = []
    private let maxEntries = 500

    /// 7 天 TTL：favicon 改动频率远低于此，但也不至于让旧文件永远滞留。
    private static let diskTTL: TimeInterval = 7 * 24 * 3600

    /// 本进程是否已跑过磁盘过期清理。每个 session 跑一次足够，避免每次 icon 调用都遍历目录。
    private var hasPrunedDisk = false

    /// favicon 图片下载大小上限 5MB：正常 favicon < 1MB（GitHub 512×512 PNG 约 50KB），
    /// 5MB 足够覆盖极端高分辨率 icon，又能挡住恶意服务器返回的 GB 级"图片炸弹"。
    private static let maxImageBytes = 5 * 1024 * 1024

    /// HTML head 下载大小上限 256KB：Range 头只请求前 64KB，但服务端可忽略 Range
    /// 返回完整页面；256KB 给重型 SPA 的 head 留足空间，又能挡住超大响应。
    private static let maxHTMLBytes = 256 * 1024

    private static let diskDir: URL = {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("Clipin/favicons", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    func icon(for url: URL) async -> NSImage? {
        // 进程内首次 icon 调用时启动一次磁盘过期清理（detached 后台跑，不阻塞当前请求）。
        // 旧实现 readDisk 命中 TTL 外只是返回 nil 重新下载，**旧文件本身从不删除**——
        // 长期使用 favicon 目录会随访问过的不同站点无界增长。
        if !hasPrunedDisk {
            hasPrunedDisk = true
            Self.pruneExpiredDiskFilesAsync()
        }
        guard let origin = Self.origin(of: url) else { return nil }

        if let data = cache[origin] {
            touch(origin)
            return NSImage(data: data)
        }
        if let task = pending[origin] {
            if let data = await task.value { return NSImage(data: data) }
            return nil
        }

        // 磁盘命中：填充 in-memory 后返回
        if let data = readDisk(origin: origin) {
            store(origin, data: data)
            return NSImage(data: data)
        }

        let task = Task<Data?, Never> {
            await Self.fetchRemote(url: url, origin: origin)
        }
        pending[origin] = task
        let result = await task.value
        pending[origin] = nil
        if let data = result {
            store(origin, data: data)
            // 写磁盘只需 Data，不再共享 NSImage 实例
            writeDisk(origin: origin, data: data)
            return NSImage(data: data)
        }
        return nil
    }

    /// 写入 cache 并维护 LRU：超 maxEntries 时淘汰最久未访问条目。
    private func store(_ origin: String, data: Data) {
        cache[origin] = data
        touch(origin)
        while cache.count > maxEntries, let evict = lru.first {
            cache.removeValue(forKey: evict)
            lru.removeFirst()
        }
    }

    /// 把 origin 标记为最近访问：从 lru 序列里移到末尾。
    private func touch(_ origin: String) {
        lru.removeAll { $0 == origin }
        lru.append(origin)
    }

    /// 把 URL normalize 成 origin 字符串：scheme + host + 非默认 port。
    /// - `https://github.com` → `"https://github.com"`
    /// - `https://github.com:443/foo` → `"https://github.com"`（443 是 https 默认）
    /// - `http://112.44.253.74:9210/x` → `"http://112.44.253.74:9210"`
    /// - `http://[::1]:8080/x` → `"http://[::1]:8080"`（IPv6 host 必须 [] 包裹）
    /// - 非 http(s) scheme / 无 host → nil（不可缓存的 URL，调用方走兜底显示）
    ///
    /// host 大小写 normalize：DNS 不区分大小写，统一小写避免 GitHub.com / github.com 双份缓存。
    private static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        // IPv6 host（`url.host` 返回裸 `::1`，不带方括号）必须 `[]` 包裹才是合法 URL，
        // 否则 `http://::1:8080` 里的 `:` 会被 URL 解析器当成 scheme/port 分隔符。
        let normalizedHost = host.lowercased()
        let formattedHost = normalizedHost.contains(":") ? "[\(normalizedHost)]" : normalizedHost
        if let port = url.port, !isDefaultPort(port, scheme: scheme) {
            return "\(scheme)://\(formattedHost):\(port)"
        }
        return "\(scheme)://\(formattedHost)"
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
    /// 1. **候选收集**：拉 origin 的 HTML head 64KB，解析 `<link rel="icon">`。候选只是
    ///    href 元数据，**不下载图片字节**——这是性能关键，HTML head 64KB 比图片完整下载轻 10×
    /// 2. **隐式 fallback 候选**：始终给候选列表追加 `<origin>/favicon.ico`。这是浏览器对
    ///    "HTML 没声明 icon"的隐式 fallback——老站点不声明 icon link，但 /favicon.ico 有图
    /// 3. **评分排序 + 去重 + top-2 下载**：按 apple-touch-icon > icon > sizes 从高到低
    ///    排序，下载 top-2，第一个成功就用。top-2 是 best 失败时的 fallback。
    ///
    /// **只抓 origin 自身、不做"根域回退"**：与浏览器一致——浏览器访问 `docs.feishu.cn`
    /// 只解析该页 HTML + 试 `docs.feishu.cn/favicon.ico`，绝不会拉 `feishu.cn` 的 favicon
    /// 安上去。现代 SPA（Next.js/Vite/CRA）的 favicon 声明在所有子域共享的 index.html 里，
    /// 子域 HTML 自带 `<link rel=icon>`，origin 解析已自足。根域回退既要猜 TLD 边界
    /// （`a.x.co.uk` 易切错成 `co.uk`，回退拉到错误站点的 favicon），又对现代站点几乎
    /// 永不命中——是净负资产，删除。
    private nonisolated static func fetchRemote(url: URL, origin: String) async -> Data? {
        // === 阶段 1: 收集 origin 的 HTML 候选 ===
        var allCandidates = await collectCandidates(from: origin)

        // === 阶段 2: 加入隐式 /favicon.ico 候选 ===
        // 评分基础分 50（与 rel="icon" 同分），低于 apple-touch-icon（100）。
        // 如果 HTML 声明了高优先级 icon link，会优先选 HTML 的；HTML 没声明的话隐式 ico 兜底。
        if let originURL = URL(string: origin) {
            allCandidates.append(IconCandidate(
                rel: "icon", href: "/favicon.ico", sizes: nil, baseURL: originURL
            ))
        }

        // === 阶段 3: 评分排序 + 去重 → 下载 top-2 ===
        // 去重：HTML 可能已声明 `<link rel="icon" href="/favicon.ico">`，与阶段 2 追加的
        // 隐式 /favicon.ico 解析到同一 URL；不去重会连续等两次相同的 4s 超时。
        // 排序在前、去重在后 → 同 URL 的多个候选保留分数最高那个。
        // top-2 是 best 失败时的 fallback：apple-touch-icon 链接如果服务器 404
        //（站点 HTML 配错），仍能下载到次优 icon。极端最坏 2 × 4s = 8s。
        let sorted = allCandidates.sorted { score(of: $0) > score(of: $1) }
        var seenURLs = Set<String>()
        var downloadTargets: [URL] = []
        for candidate in sorted {
            // sorted 降序，遇到第一个非 favicon（score < 0）后面全是非 favicon，停。
            // 实际 parseIconLinks 已过滤非 favicon rel，这里是防御性兜底。
            guard score(of: candidate) >= 0 else { break }
            guard let resolved = URL(string: candidate.href, relativeTo: candidate.baseURL)?.absoluteURL,
                  seenURLs.insert(resolved.absoluteString).inserted else { continue }
            downloadTargets.append(resolved)
            if downloadTargets.count == 2 { break }
        }
        for target in downloadTargets {
            if let data = await downloadAndNormalize(url: target) { return data }
        }
        return nil
    }

    /// 限制响应大小的下载：用 `URLSession.bytes` streaming 边读边累积，超阈值立即放弃。
    ///
    /// 两道防线挡"响应炸弹"——恶意服务器忽略 `Range` 头返回 GB 级数据导致进程 OOM：
    /// 1. `expectedContentLength` 预检：拦截诚实声明 Content-Length 的服务器
    /// 2. streaming 累积检查：拦截"声明小、实际发大"的恶意服务器（Content-Length 不可信）
    ///
    /// 用 streaming（而非 `data(for:)` 一次性拿完再判断）的原因：`data(for:)` 会先把
    /// 完整响应缓冲进内存才返回，恶意 GB 级响应在"判断大小"之前就已经把内存撑爆了。
    ///
    /// internal（非 private）：URLMetadataCache 拉 URL 页面 title 也走 URLSession，
    /// 同样需要响应大小防护——这是同 module 内共享的网络安全工具，不是 FaviconCache 私有。
    nonisolated static func downloadWithLimit(_ request: URLRequest, maxBytes: Int) async -> Data? {
        do {
            let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return nil
            }
            if response.expectedContentLength > Int64(maxBytes) { return nil }
            var data = Data()
            let hint = Int(response.expectedContentLength)
            if hint > 0 { data.reserveCapacity(min(hint, maxBytes)) }
            for try await byte in asyncBytes {
                data.append(byte)
                if data.count > maxBytes { return nil }
            }
            return data
        } catch {
            return nil
        }
    }

    /// HTML metadata/favicon 候选只需要页面前缀，不要求整个响应小于 maxBytes。
    ///
    /// 与图片下载的 `downloadWithLimit` 不同：很多现代页面完整 HTML 远超 256KB，
    /// 但 `<head>` 的 title/meta/link 通常在前缀里。这里读到 maxBytes 即返回，既避免
    /// 大页面被 Content-Length 预检误杀，也不会把超大响应完整吃进内存。
    nonisolated static func downloadHTMLPrefixWithLimit(_ request: URLRequest, maxBytes: Int) async -> Data? {
        do {
            let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return nil
            }
            var data = Data()
            let hint = Int(response.expectedContentLength)
            if hint > 0 { data.reserveCapacity(min(hint, maxBytes)) }
            for try await byte in asyncBytes {
                data.append(byte)
                if data.count >= maxBytes { return data }
            }
            return data
        } catch {
            return nil
        }
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
        // Range + gzip 在部分服务器上会返回不可解的压缩分片；HTML 前缀抓取要求未压缩字节。
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        // Safari UA：部分站点按 UA 切版本（移动版 vs PC 版），通用 UA 拿到完整 head
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        guard let data = await downloadHTMLPrefixWithLimit(request, maxBytes: maxHTMLBytes) else { return [] }
        guard let html = String(data: data, encoding: .utf8)
              ?? String(data: data, encoding: .isoLatin1) else { return [] }
        return parseIconLinks(in: html, baseURL: url)
    }

    /// 下载单个 URL → 校验是真实图片 → normalize 成 PNG Data。
    /// 抽出独立函数让各源共用，避免 fetchRemote 主流程被 NSImage/NSBitmapImageRep
    /// 校验码淹没（之前所有源都重复一遍 校验+转 PNG 的样板）。
    ///
    /// 下载经 downloadWithLimit 限制到 maxImageBytes，杜绝恶意"图片炸弹"撑爆内存。
    private nonisolated static func downloadAndNormalize(url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        guard let data = await downloadWithLimit(request, maxBytes: maxImageBytes) else { return nil }
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
                  // 只收真正的彩色 raster favicon（icon / shortcut icon / apple-touch-icon）。
                  // 排除 mask-icon / fluid-icon —— 它们 rel 含 "icon" 但不是常规 favicon。
                  iconRelKind(rel) != nil,
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

    /// 可用作彩色 favicon 的 rel 类型。
    private enum IconRelKind {
        case appleTouch  // apple-touch-icon[-precomposed]：通常高分辨率 PNG
        case standard    // icon / shortcut icon
    }

    /// 判定 rel 是否是可用的 raster favicon，并返回其类型。
    ///
    /// **必须按空格分词精确匹配，不能用 `contains`/`hasSuffix`**：HTML 里有一类含 "icon"
    /// 字样但不是常规 favicon 的 link——`mask-icon`（Safari pinned tab 的**单色矢量蒙版**，
    /// 选中会得到纯色剪影而非彩色 logo）、`fluid-icon`（Fluid.app 专用）。
    /// `"mask-icon".hasSuffix("icon")` 是 true，模糊匹配会把它们误纳入候选。
    /// 分词后 `"mask-icon"` 是单 token `["mask-icon"]`，不含独立的 `"icon"` token → 被排除；
    /// `"shortcut icon"` 分词为 `["shortcut", "icon"]` → 含 `"icon"` → 正确保留。
    private nonisolated static func iconRelKind(_ rel: String) -> IconRelKind? {
        let tokens = Set(rel.lowercased().split(separator: " ").map(String.init))
        if tokens.contains("apple-touch-icon") || tokens.contains("apple-touch-icon-precomposed") {
            return .appleTouch
        }
        if tokens.contains("icon") {  // "icon" 或 "shortcut icon"
            return .standard
        }
        return nil  // mask-icon / fluid-icon / 非 icon 类型
    }

    /// 对单个候选评分：apple-touch-icon（高分辨率 PNG）> 带大 sizes 的 icon > 普通 icon。
    /// 这套优先级是 Safari 自己也用的——预览面板 64pt @2x = 128px，apple-touch-icon
    /// 默认 180px 完全够，且通常是 PNG 比 ICO 渲染干净。
    ///
    /// 非 favicon 类型（mask-icon 等）返回 -1，排序后排在末尾，fetchRemote 不会下载。
    /// 提到 file-level 是因为 fetchRemote 阶段 3 的排序也要用同一份评分逻辑。
    private nonisolated static func score(of candidate: IconCandidate) -> Int {
        guard let kind = iconRelKind(candidate.rel) else { return -1 }
        var s = (kind == .appleTouch) ? 100 : 50
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

    /// origin → 磁盘文件名 sanitize。
    /// origin 含 `://`、可能的 `:port` 和 IPv6 的 `[]`，FileManager 会把 `/` 当路径分隔符，
    /// `[]` 在文件名里虽合法但易引发 shell/glob 歧义，统一替换为 `_`。
    /// 例：`http://112.44.253.74:9210` → `http___112.44.253.74_9210.png`
    ///     `http://[::1]:8080` → `http____::1__8080.png`（`[` `]` `:` 都转 `_`）
    private static func diskName(for origin: String) -> String {
        var safe = origin
        safe = safe.replacingOccurrences(of: "://", with: "___")
        safe = safe.replacingOccurrences(of: ":", with: "_")
        safe = safe.replacingOccurrences(of: "/", with: "_")
        safe = safe.replacingOccurrences(of: "[", with: "_")
        safe = safe.replacingOccurrences(of: "]", with: "_")
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

    /// 删除磁盘上已超 TTL 的 favicon 文件。每个 session 跑一次。
    /// detached + .utility 优先级：纯文件 IO，不抢主队列。
    private static func pruneExpiredDiskFilesAsync() {
        Task.detached(priority: .utility) {
            let fm = FileManager.default
            guard let entries = try? fm.contentsOfDirectory(
                at: Self.diskDir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { return }
            let now = Date()
            for file in entries {
                guard let attrs = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
                      let modDate = attrs.contentModificationDate else { continue }
                if now.timeIntervalSince(modDate) > Self.diskTTL {
                    try? fm.removeItem(at: file)
                }
            }
        }
    }
}
