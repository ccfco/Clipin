import Foundation

/// 列表条目的展示派生属性。主列表 row 与 ⌘K 动作面板头部共用同一套
/// 标题/图标推导，避免两处各算一遍导致文案漂移。
extension ClipListItem {
    /// 单行展示标题：文本/URL 取首行截断；图片有 OCR 取 OCR 文字、否则 "Image"；文件取文件标题。
    var displayTitle: String {
        switch clipType {
        case .text, .url:
            return Self.firstLineTruncated(preview) ?? "(empty)"
        case .image:
            // preview 经 SQL COALESCE：有 OCR 时为识别文字，否则为占位符 "image"。
            // 用 "image" 作为哨兵判断是否有可展示的 OCR 文字。
            let base: String
            if preview != "image", let line = Self.firstLineTruncated(preview) {
                base = line
            } else {
                base = NSLocalizedString("Image", comment: "")
            }
            // 尺寸始终追加：无论是占位标题还是 OCR 文字，都把 (宽×高) 拼到尾部。
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
