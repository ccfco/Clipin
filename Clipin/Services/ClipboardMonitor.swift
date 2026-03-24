import AppKit
import SwiftUI

/// 剪贴板监控 — 每 0.5s 检查 NSPasteboard.changeCount
@MainActor
final class ClipboardMonitor: ObservableObject {
    private let core: ClipinCore
    private var timer: Timer?
    private var lastChangeCount: Int

    init(core: ClipinCore) {
        self.core = core
        self.lastChangeCount = NSPasteboard.general.changeCount
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkClipboard()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// 有新内容被保存时触发
    var onNewItem: (() -> Void)?

    private func checkClipboard() {
        let pasteboard = NSPasteboard.general
        let currentCount = pasteboard.changeCount

        guard currentCount != lastChangeCount else { return }
        lastChangeCount = currentCount

        let tracker = SourceAppTracker.shared
        let sourceApp = tracker.bundleIdentifier
        let sourceName = tracker.appName

        // 优先级: 图片 > 文件 > URL > 文本
        if let imageData = pasteboard.data(forType: .tiff) ?? pasteboard.data(forType: .png) {
            saveImage(imageData, sourceApp: sourceApp, sourceName: sourceName)
        } else if let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL], let firstURL = fileURLs.first {
            saveFile(firstURL, sourceApp: sourceApp, sourceName: sourceName)
        } else if let urlString = pasteboard.string(forType: .URL) ?? extractURL(from: pasteboard) {
            saveContent(urlString, type: .url, sourceApp: sourceApp, sourceName: sourceName)
        } else if let text = pasteboard.string(forType: .string), !text.isEmpty {
            saveContent(text, type: .text, sourceApp: sourceApp, sourceName: sourceName)
        }
    }

    private func saveContent(_ content: String, type: ClipType, sourceApp: String?, sourceName: String?) {
        _ = try? core.saveItem(
            content: content,
            clipType: type,
            sourceApp: sourceApp,
            sourceName: sourceName,
            imagePath: nil
        )
        onNewItem?()
    }

    private func saveImage(_ data: Data, sourceApp: String?, sourceName: String?) {
        let imageDir = core.imageDir()
        let filename = UUID().uuidString + ".png"
        let path = (imageDir as NSString).appendingPathComponent(filename)

        guard let image = NSImage(data: data),
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else { return }

        do {
            try pngData.write(to: URL(fileURLWithPath: path))
            _ = try core.saveItem(
                content: "image",
                clipType: .image,
                sourceApp: sourceApp,
                sourceName: sourceName,
                imagePath: path
            )
            onNewItem?()
        } catch {
            print("⚠️ Failed to save image: \(error)")
        }
    }

    private func saveFile(_ url: URL, sourceApp: String?, sourceName: String?) {
        saveContent(url.path, type: .file, sourceApp: sourceApp, sourceName: sourceName)
    }

    /// 尝试从文本中提取 URL
    private func extractURL(from pasteboard: NSPasteboard) -> String? {
        guard let text = pasteboard.string(forType: .string),
              let url = URL(string: text),
              let scheme = url.scheme,
              ["http", "https"].contains(scheme) else { return nil }
        return text
    }
}
