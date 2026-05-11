import Foundation
import ImageIO

final class ClipImageThumbnailCache: @unchecked Sendable {
    static let shared = ClipImageThumbnailCache()

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
