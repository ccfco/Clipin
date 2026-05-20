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

        let pixelSize = maxPixelSize
        let image = await Task.detached(priority: .utility) {
            Self.makeThumbnail(path: path, maxPixelSize: pixelSize)
        }.value
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
