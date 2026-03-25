import AppKit
import ImageIO
import UniformTypeIdentifiers

/// 剪贴板监控 — 每 0.5s 检查 NSPasteboard.changeCount
@MainActor
final class ClipboardMonitor: ObservableObject {
    private enum ClipboardPayload: Sendable {
        case text(String, String?, String?)
        case url(String, String?, String?)
        case file(String, String?, String?)
        case image(Data, String?, String?)
    }

    private let core: ClipinCore
    private var timer: Timer?
    private var lastChangeCount: Int
    private var isPaused = false

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

    /// 暂停监控（粘贴时用，避免把自己写入的内容又存一遍）
    func pause() {
        isPaused = true
    }

    /// 恢复监控，跳过暂停期间的变化
    func resume() {
        lastChangeCount = NSPasteboard.general.changeCount
        isPaused = false
    }

    var onNewItem: (() -> Void)?

    private func checkClipboard() {
        guard !isPaused else { return }

        let pasteboard = NSPasteboard.general
        let currentCount = pasteboard.changeCount
        guard currentCount != lastChangeCount else { return }
        lastChangeCount = currentCount

        let tracker = SourceAppTracker.shared
        let sourceApp = tracker.bundleIdentifier
        let sourceName = tracker.appName

        // 高层语义优先，低层二进制兜底
        // file → url → image → text
        if let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL], let firstURL = fileURLs.first {
            persist(.file(firstURL.path, sourceApp, sourceName))
        } else if let urlString = pasteboard.string(forType: .URL) ?? extractURL(from: pasteboard) {
            persist(.url(urlString, sourceApp, sourceName))
        } else if let imageData = pasteboard.data(forType: .tiff) ?? pasteboard.data(forType: .png) {
            persist(.image(imageData, sourceApp, sourceName))
        } else if let text = pasteboard.string(forType: .string), !text.isEmpty {
            persist(.text(text, sourceApp, sourceName))
        }
    }

    private func persist(_ payload: ClipboardPayload) {
        let core = self.core

        Task.detached(priority: .utility) { [weak self] in
            do {
                switch payload {
                case let .text(content, sourceApp, sourceName):
                    _ = try core.saveItem(
                        content: content,
                        clipType: .text,
                        sourceApp: sourceApp,
                        sourceName: sourceName,
                        imagePath: nil
                    )

                case let .url(content, sourceApp, sourceName):
                    _ = try core.saveItem(
                        content: content,
                        clipType: .url,
                        sourceApp: sourceApp,
                        sourceName: sourceName,
                        imagePath: nil
                    )

                case let .file(path, sourceApp, sourceName):
                    _ = try core.saveItem(
                        content: path,
                        clipType: .file,
                        sourceApp: sourceApp,
                        sourceName: sourceName,
                        imagePath: nil
                    )

                case let .image(data, sourceApp, sourceName):
                    let imageDir = core.imageDir()
                    let filename = UUID().uuidString + ".png"
                    let path = (imageDir as NSString).appendingPathComponent(filename)
                    let pngData = try Self.makePNGData(from: data)
                    try pngData.write(to: URL(fileURLWithPath: path), options: .atomic)
                    _ = try core.saveItem(
                        content: "image",
                        clipType: .image,
                        sourceApp: sourceApp,
                        sourceName: sourceName,
                        imagePath: path
                    )
                }

                guard let self else { return }
                await self.notifyNewItem()
            } catch {
                print("⚠️ Failed to persist clipboard item: \(error)")
            }
        }
    }

    private func extractURL(from pasteboard: NSPasteboard) -> String? {
        guard let text = pasteboard.string(forType: .string),
              let url = URL(string: text),
              let scheme = url.scheme,
              ["http", "https"].contains(scheme) else { return nil }
        return text
    }

    nonisolated private static func makePNGData(from data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ClipboardMonitorError.invalidImageData
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw ClipboardMonitorError.failedToEncodePNG
        }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ClipboardMonitorError.failedToEncodePNG
        }

        return output as Data
    }

    @MainActor
    private func notifyNewItem() {
        onNewItem?()
    }
}

private enum ClipboardMonitorError: Error {
    case invalidImageData
    case failedToEncodePNG
}
