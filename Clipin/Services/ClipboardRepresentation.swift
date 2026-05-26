import AppKit
import UniformTypeIdentifiers

/// 单条剪贴板条目的一种 UTI representation。
/// 对应 Rust 侧的 ClipRepresentation。
struct ClipboardRepresentation: Equatable {
    let uti: String
    let data: Data
}

enum ClipboardRepresentationExtractor {
    /// 单 representation 大小上限（1 MB）。
    /// 富文本 HTML/RTF 通常 < 100KB，1MB 已覆盖嵌入 base64 图片的极端富文本。
    static let perRepresentationLimit = 1 * 1024 * 1024

    /// 单 item 所有 representations 总和上限（4 MB）。
    /// 超过则 fallback 仅保留 plain，避免极端 RTFD 把 DB 撑大。
    static let totalLimit = 4 * 1024 * 1024

    /// 白名单：只采集能被另一个 app 理解的公共 UTI。
    /// 不收 dyn.xxx、应用私有 UTI、过时的 com.apple.flat-rtfd 等。
    static let whitelist: [NSPasteboard.PasteboardType] = [
        .html,                                 // public.html
        .rtf,                                  // public.rtf
        NSPasteboard.PasteboardType("public.rtfd"),
        .URL,                                  // public.url
    ]

    /// 从 pasteboard 提取白名单 representations，去掉与 primaryContent 完全重复的。
    /// 返回空数组表示这条 item 没有额外 representation（纯 plain 复制 / 全部超大被 fallback）。
    static func extract(
        from pasteboard: NSPasteboard,
        primaryContent: String
    ) -> [ClipboardRepresentation] {
        var result: [ClipboardRepresentation] = []
        var totalBytes = 0
        let availableTypes = pasteboard.types ?? []

        for type in whitelist where availableTypes.contains(type) {
            guard let data = pasteboard.data(forType: type) else { continue }

            // 空 data 直接跳过：空的 public.html/rtf 持久化后会让 UI 暴露
            // Paste as HTML/RTF，粘贴时目标 app 可能优先消费空富文本而丢掉 plain text。
            guard !data.isEmpty else { continue }

            // 去重：data 解码为 UTF-8 后等同于 primaryContent → 跳过
            if let asString = String(data: data, encoding: .utf8), asString == primaryContent {
                continue
            }

            // 单条上限
            guard data.count <= perRepresentationLimit else { continue }

            result.append(ClipboardRepresentation(uti: type.rawValue, data: data))
            totalBytes += data.count
        }

        // 总和上限 → fallback 全丢
        guard totalBytes <= totalLimit else { return [] }
        return result
    }

    /// 给 image/file 类型采集时使用的辅助 UTI 收集器。
    ///
    /// 区别于 extract(from:primaryContent:)：image/file 没有"primary 字符串"可做去重锚点
    /// （image 主载体是 imagePath 上的 PNG 文件、file 主载体是 content 列的多路径文本）。
    /// 这里收集的是 pasteboard 上"对粘贴有补充价值"的辅助 UTI——让粘贴时能多 UTI 回放：
    /// - image 类型：拿到 file-url 后，粘到 Finder 仍是文件粘贴（前提是源文件还在）；
    ///   拿到 html/url 后，富文本编辑器有更多消费方式。
    /// - file 类型：拿到 image data 后，粘到富文本编辑器是图而不是路径字符串。
    ///
    /// 主载体对应的 UTI 由 primaryClipType 决定并跳过：
    /// - .image 跳过所有 image-conforming UTI（已经在 imagePath 里）
    /// - .file 跳过 public.file-url（已经在 content 里）
    /// 单条/总量上限沿用 perRepresentationLimit / totalLimit。
    static func extractAuxiliary(
        from pasteboard: NSPasteboard,
        primaryClipType: ClipType
    ) -> [ClipboardRepresentation] {
        // 辅助白名单：HTML/RTF/URL 是任何类型都可能附带的富表达；
        // 跨类型补充："file 复制" 顺带的 image bytes、"image 复制" 顺带的 file-url。
        // 与 whitelist 不同：whitelist 是 text/url primary 之外的补充，这里覆盖跨类型。
        var candidates: [NSPasteboard.PasteboardType] = [
            .html,
            .rtf,
            NSPasteboard.PasteboardType("public.rtfd"),
            .URL,
        ]
        if primaryClipType == .file {
            // file 主载体不挂 image bytes；可以补一份 image 给富文本消费方
            candidates.append(.png)
            candidates.append(.tiff)
        }
        if primaryClipType == .image {
            // image 主载体已落 imagePath；file-url 是关键补充——本地图片场景能继续按文件粘贴
            candidates.append(.fileURL)
        }

        var result: [ClipboardRepresentation] = []
        var totalBytes = 0
        let availableTypes = pasteboard.types ?? []

        for type in candidates where availableTypes.contains(type) {
            // primary 已涵盖的 UTI 跳过——防止与主载体重复占用
            if primaryClipType == .image, isImageConformingType(type) { continue }
            if primaryClipType == .file, type == .fileURL { continue }

            guard let data = pasteboard.data(forType: type), !data.isEmpty else { continue }
            guard data.count <= perRepresentationLimit else { continue }
            result.append(ClipboardRepresentation(uti: type.rawValue, data: data))
            totalBytes += data.count
        }

        guard totalBytes <= totalLimit else { return [] }
        return result
    }

    /// 判断 UTI 是否表示图片内容。复用 ClipboardMonitor 同源判定逻辑，避免散布。
    private static func isImageConformingType(_ type: NSPasteboard.PasteboardType) -> Bool {
        guard type.rawValue != "public.file-url" else { return false }
        guard let utType = UTType(type.rawValue) else { return false }
        return utType.conforms(to: .image)
    }
}
