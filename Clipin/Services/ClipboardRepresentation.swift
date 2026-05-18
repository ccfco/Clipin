import AppKit

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
}
