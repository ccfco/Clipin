import Foundation
import ImageIO

final class ClipImageThumbnailCache: @unchecked Sendable {
    /// 列表行 24×24 缩略图档位（默认实例）
    static let shared = ClipImageThumbnailCache()
    /// 预览面板大图档位：尺寸上限 ~1024，条目少一些（30），避免内存常驻过大。
    /// preview 切换比列表滚动稀疏得多，30 个 LRU 槽位足以覆盖典型来回浏览路径。
    /// 数值与 ClipinChrome.previewImageMaxPixelSize 同步，但本类保持自包含
    /// 不跨模块引用 token（cache 是基础设施，不依赖 UI 层）。
    static let preview = ClipImageThumbnailCache(maxSize: 30, maxPixelSize: 1024)

    private let maxSize: Int
    private let maxPixelSize: Int
    private var cache: [String: CGImage] = [:]
    private var keys: [String] = []
    private let lock = NSLock()

    init(maxSize: Int = 100, maxPixelSize: Int = 112) {
        self.maxSize = max(1, maxSize)
        self.maxPixelSize = max(16, maxPixelSize)
    }

    func cachedThumbnail(for path: String) -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        guard let cached = cache[path] else { return nil }
        touch(path)
        return cached
    }

    func thumbnail(for path: String) async -> CGImage? {
        if let cached = cachedThumbnail(for: path) {
            return cached
        }

        // 限并发闸门：列表快速滚动时几十张大图若同时解码会占满 CPU/内存、把主线程渲染挤掉帧
        // （已由 CLIPIN_QA_NO_LIST_THUMB 二分实验坐实是卡顿根因）。闸门把并发压到少量。
        await ThumbnailDecodeGate.shared.acquire()
        // 拿到名额后若该行已滚出可见区（.task 取消），跳过解码省 CPU——
        // CGImageSourceCreateThumbnailAtIndex 是同步调用，取消标志拦不住已开跑的解码，
        // 必须在「开跑前」这一刻拦截，让最终停留可见的行快速轮到。
        let image: CGImage?
        if Task.isCancelled {
            image = nil
        } else {
            let pixelSize = maxPixelSize
            image = await Task.detached(priority: .utility) {
                Self.makeThumbnail(path: path, maxPixelSize: pixelSize)
            }.value
        }
        await ThumbnailDecodeGate.shared.release()

        guard let image else {
            return nil
        }

        storeThumbnail(image, for: path)
        return image
    }

    private func storeThumbnail(_ image: CGImage, for path: String) {
        lock.lock()
        defer { lock.unlock() }
        insert(key: path, value: image)
    }

    private func touch(_ key: String) {
        keys.removeAll { $0 == key }
        keys.append(key)
    }

    private func insert(key: String, value: CGImage) {
        if cache[key] == nil, cache.count >= maxSize, let lru = keys.first {
            cache.removeValue(forKey: lru)
            keys.removeFirst()
        }
        cache[key] = value
        touch(key)
    }

    private static func makeThumbnail(path: String, maxPixelSize: Int) -> CGImage? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// 全局缩略图解码限并发闸门。列表滚动会瞬时请求大量解码，不限并发会让几十张大图同时在
/// utility 线程解码、占满 CPU/内存拖垮主线程渲染（卡顿根因）。limit 是经验值：留足核心给
/// 主线程，又不至于让缩略图逐个慢慢冒。acquire 拿不到名额时挂起排队，release 优先唤醒等待者。
actor ThumbnailDecodeGate {
    static let shared = ThumbnailDecodeGate(limit: 3)

    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.available = max(1, limit)
    }

    func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            available += 1
        } else {
            // 名额直接转交队首等待者，不经过 available，避免唤醒间隙被新请求插队抢走。
            waiters.removeFirst().resume()
        }
    }
}
