import AppKit
import Foundation
import ImageIO

/// 预览面板 footer / file header 用到的"轻量元数据"统一缓存。
///
/// 之前这些 metadata 在 PreviewPane.body / footerEntries 里**同步**计算：
/// - `imageDimensions(at:)`：CGImageSourceCreateWithURL 读文件头
/// - `fileSizeString(at:)`：URL.resourceValues stat
/// - `NSWorkspace.shared.icon(forFile:)`：IconServices 同步
/// - `NSWorkspace.shared.urlForApplication(...)` + icon：source app 徽章
///
/// SwiftUI body 是纯函数，preview 每次重建（搜索词 / scene state / selection）
/// 都会重新跑一遍上述 IO，频繁切条目时主线程会感觉到卡。
///
/// 这层缓存的语义：
/// - `cached*` 同步路径，命中即返回，永不触发 IO；UI body 用它做"即时显示"。
/// - `load*` 异步路径，未命中时在 detached task 中算，结果回填缓存；UI 在
///   `.task(id: itemID)` 中调用一次预热即可。
/// - LRU 容量与列表分页规模匹配（200），保证用户在最近浏览的几屏内来回切换永不重算。
final class PreviewMetadataCache: @unchecked Sendable {
    static let shared = PreviewMetadataCache()

    private let lock = NSLock()
    private let maxEntries = 200

    private var dimensions: LRUStore<String, ImageDimensions> = .init()
    private var fileSizes: LRUStore<String, String> = .init()
    private var appIcons: LRUStore<String, NSImage> = .init()
    private var fileIcons: LRUStore<String, NSImage> = .init()

    struct ImageDimensions: Equatable, Sendable {
        let width: Int
        let height: Int
    }

    // MARK: - Sync (cache-only) accessors

    func cachedDimensions(at path: String) -> ImageDimensions? {
        lock.lock(); defer { lock.unlock() }
        return dimensions.get(path)
    }

    func cachedFileSize(at path: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return fileSizes.get(path)
    }

    func cachedAppIcon(for bundleID: String) -> NSImage? {
        lock.lock(); defer { lock.unlock() }
        return appIcons.get(bundleID)
    }

    func cachedFileIcon(at path: String) -> NSImage? {
        lock.lock(); defer { lock.unlock() }
        return fileIcons.get(path)
    }

    // MARK: - Async (load + cache) accessors

    func loadDimensions(at path: String) async -> ImageDimensions? {
        if let cached = cachedDimensions(at: path) { return cached }
        let value = await Task.detached(priority: .userInitiated) {
            Self.readImageDimensions(at: path)
        }.value
        if let value { storeDimensions(value, for: path) }
        return value
    }

    func loadFileSize(at path: String) async -> String? {
        if let cached = cachedFileSize(at: path) { return cached }
        let value = await Task.detached(priority: .userInitiated) {
            Self.readFileSize(at: path)
        }.value
        if let value { storeFileSize(value, for: path) }
        return value
    }

    func loadAppIcon(for bundleID: String) async -> NSImage? {
        if let cached = cachedAppIcon(for: bundleID) { return cached }
        // urlForApplication / icon(forFile:) 都是同步 IconServices 调用，必须出主线程。
        let value = await Task.detached(priority: .userInitiated) { @Sendable in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                return UncheckedSendableImage(image: nil)
            }
            return UncheckedSendableImage(image: NSWorkspace.shared.icon(forFile: url.path))
        }.value
        if let image = value.image {
            storeAppIcon(image, for: bundleID)
            return image
        }
        return nil
    }

    func loadFileIcon(at path: String) async -> NSImage? {
        if let cached = cachedFileIcon(at: path) { return cached }
        let value = await Task.detached(priority: .userInitiated) { @Sendable in
            UncheckedSendableImage(image: NSWorkspace.shared.icon(forFile: path))
        }.value
        if let image = value.image {
            storeFileIcon(image, for: path)
            return image
        }
        return nil
    }

    // MARK: - Sync (cache-write) helpers
    // NSLock 在 Swift 6 async 上下文不可用（锁跨 await 是危险模式）。
    // 所有写都收口成同步小函数，async 接口里只调这些 sync helper。

    private func storeDimensions(_ value: ImageDimensions, for path: String) {
        lock.lock(); defer { lock.unlock() }
        dimensions.set(path, value, maxEntries: maxEntries)
    }

    private func storeFileSize(_ value: String, for path: String) {
        lock.lock(); defer { lock.unlock() }
        fileSizes.set(path, value, maxEntries: maxEntries)
    }

    private func storeAppIcon(_ image: NSImage, for bundleID: String) {
        lock.lock(); defer { lock.unlock() }
        appIcons.set(bundleID, image, maxEntries: maxEntries)
    }

    private func storeFileIcon(_ image: NSImage, for path: String) {
        lock.lock(); defer { lock.unlock() }
        fileIcons.set(path, image, maxEntries: maxEntries)
    }

    // MARK: - Raw IO helpers (run on background task)

    private static func readImageDimensions(at path: String) -> ImageDimensions? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return ImageDimensions(width: width, height: height)
    }

    private static func readFileSize(at path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [
            .isDirectoryKey,
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
            .totalFileSizeKey,
            .fileSizeKey
        ]) else { return nil }

        if values.isDirectory == true { return nil }

        let bytes =
            values.totalFileAllocatedSize ??
            values.fileAllocatedSize ??
            values.totalFileSize ??
            values.fileSize
        guard let bytes else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// 让 NSImage 安全跨越 Task.detached → main actor 边界的最小 wrapper。
/// NSImage 没有 Sendable conformance（内部 representations 可变），
/// 但 cache 写入后即只读，跨线程传递一次后由 actor 串行化访问，安全。
private struct UncheckedSendableImage: @unchecked Sendable {
    let image: NSImage?
}
