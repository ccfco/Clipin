import Foundation

/// 列表条目的展示派生属性。主列表 row 与 ⌘K 动作面板头部共用同一套
/// 标题/图标推导，避免两处各算一遍导致文案漂移。
extension ClipListItem {
    /// 单行展示标题：文本/URL 取首行截断；图片有 OCR 取 OCR 文字、否则 "Image"；文件取文件标题。
    var displayTitle: String {
        // 别名优先于一切类型标题：用户显式命名的意图最高，覆盖 text/url/image/file 四类。
        if let alias, !alias.isEmpty { return alias }
        switch clipType {
        case .text, .url:
            return Self.firstLineTruncated(preview) ?? "(empty)"
        case .image:
            // 图片标题用元信息（来源 App + 尺寸），不用 OCR 文字。真实数据验证过：
            // 剪贴板图片绝大多数是密集截图，本身没有「标题」，OCR 第一行几乎都是
            // UI chrome / 乱码。OCR 结果仍写入 ocr_text 喂 FTS——图片照样可按文字
            // 搜到，只是不再拿来当标题。
            let base: String
            if let source = sourceName, !source.isEmpty {
                base = String(
                    format: NSLocalizedString("Image · %@", comment: "图片标题：Image · 来源应用名"),
                    source)
            } else {
                base = NSLocalizedString("Image", comment: "")
            }
            guard let suffix = imageDimensionSuffix else { return base }
            return "\(base) \(suffix)"
        case .file:
            return FileClipboardContent.displayTitle(for: preview)
        }
    }

    /// 类型对应的通用 SF Symbol 名（与主列表 row 的类型图标一致）。
    var typeIconName: String {
        switch clipType {
        case .text:  return "doc.text"
        case .image: return "photo"
        case .file:  return "folder"
        case .url:   return "link"
        }
    }

    /// 图片像素尺寸后缀 "(1920×1080)"；尺寸未知（NULL 或 0×0 哨兵）时返回 nil。
    /// 0×0 是 backfill 对文件缺失 / 不可解析图片写入的哨兵，此处一并视为「未知」。
    private var imageDimensionSuffix: String? {
        guard let width = imageWidth, let height = imageHeight,
              width > 0, height > 0 else { return nil }
        return "(\(width)×\(height))"
    }

    /// 取文本首行，trim 后截断到 limit 字符；空内容返回 nil。
    private static func firstLineTruncated(_ text: String, limit: Int = 120) -> String? {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count > limit ? String(trimmed.prefix(limit)) + "…" : trimmed
    }
}
