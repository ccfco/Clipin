import Foundation
import AppKit

/// 远程 favicon 缓存：actor 串行化 + pending dedup + 磁盘持久化 + 多源回退。
///
/// 旧实现单上游写死 `google.com/s2/favicons`，重启即丢、且在中国大陆/离线场景容易长期 nil。
/// 当前实现：
/// 1. 启动即从磁盘 `~/Library/Application Support/Clipin/favicons/<host>.png` 异步读回
///    in-memory cache；
/// 2. 取 favicon 时按"直连 `/favicon.ico` → Google s2 兜底"顺序；
/// 3. 命中后异步写磁盘，TTL 7 天（避免站点换 favicon 后永久不更新）。
///
/// **关键设计：cache 持有 immutable `Data`（PNG），每次 `icon(for:)` 调用即时构造
/// 新的 `NSImage` 给 caller**。NSImage 内部 representations 可变非线程安全，如果让
/// UI 和后台磁盘写同一个 instance，会触发 race（AppKit 历史包袱：第一次 draw 时
/// lazy lock 到主线程，后台读 tiffRepresentation 同时绘制会并发 mutation）。
/// 把 cache 内层做成"序列化产物"，调用方每次都拿独立"渲染产物"，是唯一干净的解。
///
/// 拿不到就返回 nil，由调用方自己画 globe 占位，不在这里造假数据。
///
/// 访问权限：原先 file-private 仅供 PreviewPane 使用；现已抽到独立文件供列表 row
/// 也复用同一份内存/磁盘缓存（列表 favicon 与预览面板共享同一 host → 不重复拉）。
actor FaviconCache {
    static let shared = FaviconCache()

    /// PNG-encoded immutable data。每次 caller 调用都构造新的 NSImage，避免共享可变实例。
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

    func icon(for host: String) async -> NSImage? {
        if let data = cache[host] { return NSImage(data: data) }
        if let task = pending[host] {
            if let data = await task.value { return NSImage(data: data) }
            return nil
        }

        // 磁盘命中：填充 in-memory 后返回
        if let data = readDisk(host: host) {
            cache[host] = data
            return NSImage(data: data)
        }

        let task = Task<Data?, Never> {
            await Self.fetchRemote(host: host)
        }
        pending[host] = task
        let result = await task.value
        pending[host] = nil
        if let data = result {
            cache[host] = data
            // 写磁盘只需 Data，不再共享 NSImage 实例
            writeDisk(host: host, data: data)
            return NSImage(data: data)
        }
        return nil
    }

    /// fetchRemote 返回 PNG-encoded Data：在 detached task 内一次性把网络数据 normalize
    /// 成 PNG（用 NSBitmapImageRep 转码），后续 cache/磁盘/UI 三个消费方都基于这份
    /// immutable Data 各自构造独立 NSImage，杜绝跨线程共享 NSImage 实例。
    ///
    /// 多源回退顺序（按"命中率 × 速度"权衡）：
    /// 1. host 直连 `/favicon.ico` —— 最快，约 50% 站点命中
    /// 2. 根域直连 `/favicon.ico` —— 覆盖 SPA 子域：docs.feishu.cn 没有但 feishu.cn 有
    /// 3. 拉 HTML 头部解析 `<link rel="icon">` —— 覆盖飞书/Notion/各种 SaaS 把 favicon
    ///    放在 CDN 的场景；其他应用能显示的真正信源就是这一层
    /// 4. Google s2 服务 —— 大陆走 t2.gstatic.com 重定向，可达性看运气，作为最后兜底
    private nonisolated static func fetchRemote(host: String) async -> Data? {
        var triedURLs = Set<String>()

        func tryURL(_ urlString: String) async -> Data? {
            guard !triedURLs.contains(urlString), let url = URL(string: urlString) else { return nil }
            triedURLs.insert(urlString)
            return await downloadAndNormalize(url: url)
        }

        // 第 1 源：host 直连
        if let data = await tryURL("https://\(host)/favicon.ico") { return data }

        // 第 2 源：根域回退（处理 docs.feishu.cn / app.notion.so 等 SPA 子域）
        if let root = rootDomain(of: host), root != host {
            if let data = await tryURL("https://\(root)/favicon.ico") { return data }
            if let data = await tryURL("https://www.\(root)/favicon.ico") { return data }
        }

        // 第 3 源：解析 HTML 的 <link rel="icon">。优先用原始 host（保留子域语义，
        // 比如某些 SaaS 不同子域用不同品牌色 favicon），失败再退到根域 HTML。
        for htmlHost in [host, rootDomain(of: host)].compactMap({ $0 }) where !triedURLs.contains("html:\(htmlHost)") {
            triedURLs.insert("html:\(htmlHost)")
            if let iconHref = await fetchIconFromHTML(host: htmlHost),
               let data = await tryURL(iconHref) {
                return data
            }
        }

        // 第 4 源：Google s2 兜底
        if let data = await tryURL("https://www.google.com/s2/favicons?domain=\(host)&sz=128") {
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
    private nonisolated static func fetchIconFromHTML(host: String) async -> String? {
        guard let url = URL(string: "https://\(host)/") else { return nil }
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

            // resolve 相对路径到完整 URL
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

    private func diskFile(for host: String) -> URL {
        // host 可能包含 ":" 之类字符（IPv6/带端口），替换成安全字符
        let safe = host.replacingOccurrences(of: ":", with: "_")
        return Self.diskDir.appendingPathComponent(safe).appendingPathExtension("png")
    }

    private func readDisk(host: String) -> Data? {
        let file = diskFile(for: host)
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

    private nonisolated func writeDisk(host: String, data: Data) {
        // 写磁盘走 detached：避免阻塞 actor 队列。Data 是值类型 Sendable，跨线程安全。
        let file = Self.diskDir.appendingPathComponent(
            host.replacingOccurrences(of: ":", with: "_")
        ).appendingPathExtension("png")
        Task.detached(priority: .utility) {
            try? data.write(to: file)
        }
    }
}
