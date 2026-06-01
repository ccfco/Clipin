import AppKit
@preconcurrency import WebKit

/// URL 预览的「截图兜底」缓存。
///
/// **定位：预览大图的最后一层 fallback**。链路是 og:image / twitter:image → 图片直链 →
/// 本截图。前两层是站点声明的图（质量高、最轻），都拿不到时才由 URLPreviewView 调用这里。
///
/// **唯一优势场景**：SPA（飞书/钉钉文档、掘金等 JS 客户端渲染）、本地 `file://`、内网页面。
/// 这些页面服务端返回的 HTML 里 `<img>`/og:image 都是空的（内容靠 JS 渲染），纯抓 HTML
/// 永远拿不到图；只有真实浏览器引擎跑完 JS 渲染后截图，才有用户眼里的真容。
///
/// **隐私成本**（见 SettingsStore.urlPreviewScreenshot 开关，默认开、可关）：
/// - WKWebView 会执行页面 JS、加载第三方资源（广告/tracking），暴露面比纯抓 HTML 大。
/// - 用 `.nonPersistent()` data store：cookie/localStorage 仅内存态，renderer 实例释放即清，不落盘。
/// - token/webhook 黑名单由调用方（URLPreviewView.task 的 shouldAutoFetchMetadata 守卫）前置拦截，
///   不会对敏感链接截图。
///
/// 必须 `@MainActor`：WKWebView 是 UI 组件，创建/加载/截图都要主线程。截图频率低（只截当前
/// 选中项），串行 + 缓存足够，不需要并发。磁盘缓存 per-URL，7 天 TTL（同 FaviconCache）。
@MainActor
final class WebScreenshotCache {
    static let shared = WebScreenshotCache()

    /// 缓存持有不可变 PNG `Data`，每次 caller 都 NSImage(data:) 构造独立实例——
    /// 与 FaviconCache 同款规避：绝不让 UI 渲染和后台磁盘写共享同一个可变 NSImage 实例
    /// （NSImage representation 惰性可变，并发读 tiffRepresentation + draw 会触发 AppKit race）。
    private var memory = LRUStore<String, Data>()
    private var pending: [String: Task<RenderOutcome, Never>] = [:]
    /// 截图比 favicon 大得多，内存上限保守些（80 张约覆盖最近浏览的几屏 URL）。
    private let maxEntries = 80
    /// 已知截图失败/无意义（纯色空白：加载中骨架、登录墙、cookie 遮罩）的 URL。
    /// 记下来避免每次选中都重跑一个 6s WebContent 进程去截同一张必败页面。
    /// FIFO 上限（配 failedOrder 维护插入序）：不像 memory/磁盘有 LRU/TTL 淘汰，长 session
    /// 浏览大量失败 URL 会让裸 Set 单调增长；溢出淘汰最旧的，顺带给老失败页（如已登录的登录墙）
    /// 一次重试机会。**只有真失败/质量闸拒绝才进这里，「被取消」绝不入**（见 markFailed 调用点）。
    private var failed: Set<String> = []
    private var failedOrder: [String] = []
    private let maxFailed = 200
    private var hasPrunedDisk = false

    private nonisolated static let diskTTL: TimeInterval = 7 * 24 * 3600
    /// 渲染视口 16:9 宽图，贴近预览 hero 的横向构图；截到的是页面顶部首屏。
    private nonisolated static let viewportSize = CGSize(width: 1200, height: 675)
    /// 整个渲染（加载 + JS 首屏 + 截图）超时上限。超过即放弃，预览退化到无图。
    private nonisolated static let renderTimeout: TimeInterval = 6
    /// didFinish 后等 JS 渲染首屏的静置延迟——SPA 在 didFinish 时 DOM 常还没填充。
    private nonisolated static let settleDelay: TimeInterval = 0.7

    private nonisolated static let diskDir: URL = {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("Clipin/screenshots", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// 一次离屏渲染的产物三态。**blacklist 决策必须随产物走、不能靠 caller 的 `Task.isCancelled`**：
    /// pending dedup 让多个 caller 可能共享同一 render，把「失败 vs 取消」编码进产物，
    /// 才能保证任一 caller 取消时所有 awaiter 都拿到 `.cancelled`、谁都不会把这个 URL 误拉黑。
    private enum RenderOutcome {
        case image(Data)  // 过质量闸的不可变 PNG
        case failed       // 加载失败 / 超时 / 质量闸判纯色 → 记入 failed 不重试
        case cancelled    // 用户切走条目 → 不记入 failed，下次重试
    }

    /// 取 urlString 的页面截图：内存 → 磁盘 → 实时渲染，三级穿透。
    /// 返回 nil 表示渲染失败/超时/被取消——调用方退化到无图布局。
    func screenshot(for urlString: String) async -> NSImage? {
        if !hasPrunedDisk {
            hasPrunedDisk = true
            Self.pruneExpiredDiskFilesAsync()
        }
        if failed.contains(urlString) { return nil }
        if let data = memory.get(urlString) { return NSImage(data: data) }
        if let task = pending[urlString] {
            // 复用进行中的渲染：等其产物即可，失败判定由发起方负责，这里不重复记 failed。
            if case .image(let data) = await awaitOutcome(task) { return NSImage(data: data) }
            return nil
        }

        // 磁盘命中的都是写盘前已过质量闸的 PNG，直接构造新实例。
        if let data = await Self.readDiskAsync(urlString) {
            store(urlString, data)
            return NSImage(data: data)
        }

        // 渲染 + 质量闸 + 转不可变 PNG 全在 task 内完成；逃逸出来的只有 Data，NSImage 不外泄。
        // 先用拿到的有效图（取消晚到也不浪费一张好图），否则按是否被取消区分 failed / cancelled。
        let task = Task<RenderOutcome, Never> {
            let image = await Self.renderOffscreen(urlString)
            if let image, let png = Self.qualifiedPNG(from: image) {
                return .image(png)
            }
            return Task.isCancelled ? .cancelled : .failed
        }
        pending[urlString] = task
        let outcome = await awaitOutcome(task)
        pending[urlString] = nil

        switch outcome {
        case .image(let data):
            store(urlString, data)
            Self.writeDiskAsync(urlString, data: data)
            return NSImage(data: data)
        case .failed:
            markFailed(urlString)  // 纯色/空白/真失败 → 记下不重截
            return nil
        case .cancelled:
            return nil             // 用户切走 → 不拉黑，下次重试
        }
    }

    /// 等待一个 render task 的产物，并把**当前 caller 的取消**桥接进去：
    /// caller（SwiftUI `.task(id:)`）被取消时，`onCancel` 触发 `task.cancel()`，
    /// 经 ScreenshotRenderer 的取消处理终止离屏 WKWebView（停止其执行页面第三方 JS/tracker）。
    /// 共享 dedup 取 best-effort：单 caller 取消会 best-effort 终止共享 render，但产物为 `.cancelled`，
    /// 所有 awaiter 都不会误拉黑，下次重新触发即重试——单 preview 面板下并发同 URL 极罕见，可接受。
    private func awaitOutcome(_ task: Task<RenderOutcome, Never>) async -> RenderOutcome {
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// 把 URL 记入失败集合，维护 FIFO 上限：溢出淘汰最旧条目，避免无界增长。
    private func markFailed(_ key: String) {
        guard failed.insert(key).inserted else { return }
        failedOrder.append(key)
        while failed.count > maxFailed, let evict = failedOrder.first {
            failed.remove(evict)
            failedOrder.removeFirst()
        }
    }

    /// 质量闸阈值：纯色≈0，含文字/图的页面通常 >15，8 给登录墙/骨架留余量又能挡纯色。
    private nonisolated static let qualityStdThreshold: Double = 8

    /// 质量闸 + PNG 编码合一：从**单个 CGImage** 同时算方差与编码 PNG，避免成功路径双重栅格化
    /// （旧实现 isMeaningful 把图 draw 到 32×32 测方差，pngData 又独立 tiff→bitmap→png）。
    /// 返回非 nil = 过质量闸的不可变 PNG；nil = 纯色/空白被拒（→ .failed）。
    /// cgImage 提取失败是环境故障（非纯色）→ 退回 tiff 编码并放行，不因测不出方差而拉黑真截图。
    private nonisolated static func qualifiedPNG(from image: NSImage) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return pngDataViaTIFF(image)  // 测不出方差 → 放行，tiff 兜底编码
        }
        // 能测到方差且低于阈值 → 纯色拒；测不出（standardDeviation 返回 nil）→ 放行。
        if let sd = standardDeviation(of: cg), sd < qualityStdThreshold { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        return rep.representation(using: .png, properties: [:]) ?? pngDataViaTIFF(image)
    }

    /// CGImage 下采样到 32×32 灰度，算亮度标准差。CGContext 创建失败（环境故障）返回 nil → 调用方放行。
    private nonisolated static func standardDeviation(of cg: CGImage) -> Double? {
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side)
        let gray = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: &pixels, width: side, height: side, bitsPerComponent: 8,
            bytesPerRow: side, space: gray, bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        let count = Double(pixels.count)
        let mean = pixels.reduce(0.0) { $0 + Double($1) } / count
        let variance = pixels.reduce(0.0) { $0 + pow(Double($1) - mean, 2) } / count
        return sqrt(variance)
    }

    /// NSImage → 不可变 PNG Data（tiff 路径）。cgImage 提取失败时的兜底编码。
    private nonisolated static func pngDataViaTIFF(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// 截图质量闸（测试入口）：纯色/空白页（加载中骨架、登录墙纯色底、cookie 全屏遮罩）方差极低
    /// → 判无意义丢弃，宁可退回无图布局也不把"看起来 broken 的图"surface 给用户。
    /// 测不出方差（cgImage/CGContext 失败）是环境故障 → 放行（return true），不误判真截图为失败。
    /// 与 qualifiedPNG 共享 standardDeviation，闸语义单一来源。
    nonisolated static func isMeaningful(_ image: NSImage) -> Bool {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let sd = standardDeviation(of: cg) else { return true }
        return sd >= qualityStdThreshold
    }

    private func store(_ key: String, _ data: Data) {
        memory.set(key, data, maxEntries: maxEntries)
    }

    /// 用一次性离屏 renderer 渲染并截图。renderer 用完即弃，连带释放 .nonPersistent() data store。
    private static func renderOffscreen(_ urlString: String) async -> NSImage? {
        guard let url = URL(string: urlString) else { return nil }
        let renderer = ScreenshotRenderer(viewport: viewportSize, settleDelay: settleDelay)
        return await renderer.capture(url: url, timeout: renderTimeout)
    }

    // MARK: - Disk (off-MainActor IO)

    /// urlString → 稳定文件名。用 FNV-1a hash（跨启动一致，不像 Hasher 每进程换种子），
    /// 截图 per-URL 且路径含 query/长 path，hash 比 sanitize 更安全。
    private nonisolated static func diskName(for urlString: String) -> String {
        String(format: "%016llx", urlString.fnv1aHash())
    }

    private nonisolated static func diskFile(for urlString: String) -> URL {
        diskDir.appendingPathComponent(diskName(for: urlString)).appendingPathExtension("png")
    }

    private nonisolated static func readDiskAsync(_ urlString: String) async -> Data? {
        await Task.detached(priority: .userInitiated) {
            let file = diskFile(for: urlString)
            let fm = FileManager.default
            guard fm.fileExists(atPath: file.path),
                  let attrs = try? fm.attributesOfItem(atPath: file.path),
                  let modDate = attrs[.modificationDate] as? Date,
                  Date().timeIntervalSince(modDate) < diskTTL,
                  let data = try? Data(contentsOf: file) else { return nil }
            return data
        }.value
    }

    private nonisolated static func writeDiskAsync(_ urlString: String, data: Data) {
        // data 是不可变 PNG（Sendable），detached 直接写盘，无 NSImage 跨线程问题。
        Task.detached(priority: .utility) {
            try? data.write(to: diskFile(for: urlString))
        }
    }

    private nonisolated static func pruneExpiredDiskFilesAsync() {
        Task.detached(priority: .utility) {
            let fm = FileManager.default
            guard let entries = try? fm.contentsOfDirectory(
                at: diskDir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { return }
            let now = Date()
            for file in entries {
                guard let attrs = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
                      let modDate = attrs.contentModificationDate else { continue }
                if now.timeIntervalSince(modDate) > diskTTL {
                    try? fm.removeItem(at: file)
                }
            }
        }
    }
}

/// 一次性网页截图器：创建离屏 WKWebView → 加载 → 等首屏静置 → 截图。用完即弃。
///
/// 三条路径竞争结束渲染，由 `finish` 的 `continuation == nil` 守卫保证只 resume 一次：
/// ① didFinish 后静置 settleDelay 截图成功；② didFail / didFailProvisionalNavigation；③ 整体超时。
/// 全部在 MainActor 上串行，无数据竞争。
@MainActor
private final class ScreenshotRenderer: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private let settleDelay: TimeInterval
    private var continuation: CheckedContinuation<NSImage?, Never>?
    private var settleTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    init(viewport: CGSize, settleDelay: TimeInterval) {
        let config = WKWebViewConfiguration()
        // cookie/localStorage 仅内存态，renderer 释放即清，不落盘——隐私底线。
        config.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: CGRect(origin: .zero, size: viewport), configuration: config)
        self.settleDelay = settleDelay
        super.init()
        webView.customUserAgent = FaviconCache.browserUserAgent
        webView.navigationDelegate = self
    }

    func capture(url: URL, timeout: TimeInterval) async -> NSImage? {
        // 外层取消处理：caller（最终是 SwiftUI `.task(id:)`）取消时，立即 finish(nil) ——
        // finish 内 stopLoading + 弃 navigationDelegate，停止离屏 WKWebView 继续执行页面第三方
        // JS/tracker。这是「切走条目后还跑满 6s」隐私暴露面的真正堵点。
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<NSImage?, Never>) in
                continuation = cont
                // 装好 handler 前若已被取消（pre-cancel 竞态），这里直接收尾，否则仍会跑满 timeout。
                if Task.isCancelled {
                    finish(nil)
                    return
                }
                timeoutTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    finish(nil)
                }
                if url.isFileURL {
                    // file:// 必须用 loadFileURL 并授读所在目录，普通 load 会被拒。
                    webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
                } else {
                    webView.load(URLRequest(url: url))
                }
            }
        } onCancel: {
            // onCancel 在任意线程同步触发，跳回 MainActor 收尾；finish 的 resume-once 守卫保证幂等。
            Task { @MainActor in self.finish(nil) }
        }
    }

    private func finish(_ image: NSImage?) {
        guard let cont = continuation else { return }
        continuation = nil
        settleTask?.cancel()
        timeoutTask?.cancel()
        webView.stopLoading()
        webView.navigationDelegate = nil
        cont.resume(returning: image)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // didFinish 后等 settleDelay 让 SPA 把首屏渲染出来，再截图。
        settleTask?.cancel()
        settleTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(settleDelay * 1_000_000_000))
            guard !Task.isCancelled, continuation != nil else { return }
            let snap = WKSnapshotConfiguration()
            snap.rect = webView.bounds
            webView.takeSnapshot(with: snap) { [weak self] image, _ in
                self?.finish(image)
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(nil)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(nil)
    }
}
