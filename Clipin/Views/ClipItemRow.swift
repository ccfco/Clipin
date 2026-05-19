import SwiftUI
import AppKit

/// 检测十六进制颜色字符串，返回 SwiftUI Color（#RGB / #RRGGBB / #RRGGBBAA）
func detectHexColor(in text: String) -> Color? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("#"), [4, 7, 9].contains(trimmed.count) else { return nil }
    let hex = String(trimmed.dropFirst())
    guard hex.allSatisfy(\.isHexDigit) else { return nil }

    var rgb: UInt64 = 0
    guard Scanner(string: hex).scanHexInt64(&rgb) else { return nil }

    switch hex.count {
    case 3:
        let r = CGFloat((rgb >> 8) & 0xF) * 17 / 255
        let g = CGFloat((rgb >> 4) & 0xF) * 17 / 255
        let b = CGFloat(rgb & 0xF) * 17 / 255
        return Color(red: r, green: g, blue: b)
    case 6:
        let r = CGFloat((rgb >> 16) & 0xFF) / 255
        let g = CGFloat((rgb >> 8) & 0xFF) / 255
        let b = CGFloat(rgb & 0xFF) / 255
        return Color(red: r, green: g, blue: b)
    case 8:
        let r = CGFloat((rgb >> 24) & 0xFF) / 255
        let g = CGFloat((rgb >> 16) & 0xFF) / 255
        let b = CGFloat((rgb >> 8) & 0xFF) / 255
        let a = CGFloat(rgb & 0xFF) / 255
        return Color(red: r, green: g, blue: b, opacity: a)
    default:
        return nil
    }
}

private struct ClipThumbnailImage: View {
    let path: String
    @State private var thumbnail: CGImage?

    var body: some View {
        Group {
            if let thumbnail {
                Image(decorative: thumbnail, scale: 1, orientation: .up)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(ClipinInk.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color(nsColor: .controlColor))
                    )
            }
        }
        .frame(width: 24, height: 24)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .task(id: path) {
            thumbnail = ClipImageThumbnailCache.shared.cachedThumbnail(for: path)
            if thumbnail == nil {
                let generatedThumbnail = await ClipImageThumbnailCache.shared.thumbnail(for: path)
                guard !Task.isCancelled else { return }
                thumbnail = generatedThumbnail
            }
        }
    }
}

/// 列表中的单行剪贴板项 — 极简单行布局
struct ClipItemRow: View {
    let item: ClipListItem
    var shortcutNumber: Int? = nil
    var searchQuery: String = ""
    var isSelected: Bool = false
    var isHovered: Bool = false
    let sceneState: ClipinSceneState

    var body: some View {
        HStack(spacing: 9) {
            typeIndicator
                .scaleEffect(typeIndicatorScale)
                .animation(ClipinMotion.feedback, value: isHovered)

            Text(highlightedDisplayText)
                // 选中 → accent(蓝),对齐 Spotlight 选中高亮的 accent 心智(用户明确要求);
                // 未选 → 字重 .regular(原 .medium 在玻璃上显"太黑",降重即变柔,不动系统 label 色)。
                .font(.system(size: 13.5, weight: isSelected ? .semibold : .regular))
                // 未选标题用柔化 primary(用户反馈纯 label 在玻璃上"太黑");
                // 选中走 accent(蓝)。
                .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary.opacity(0.82)))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            // pin 信号已交给左侧中性细 rail（ClipinSelectableRowBackground.isPinned），
            // 这里不再放 pin.fill icon，避免列表 row 视觉重量过高。

            if isSelected {
                trailingMeta
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .animation(ClipinMotion.selection, value: isSelected)
    }

    /// 类型指示器：图片显示缩略图，颜色值显示色块，其他显示单色图标
    @ViewBuilder
    private var typeIndicator: some View {
        if item.clipType == .image, let path = item.imagePath,
           !path.isEmpty {
            ClipThumbnailImage(
                path: path
            )
        } else if item.clipType == .text, let color = detectHexColor(in: item.preview) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous).fill(color)
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
            }
            .frame(width: 24, height: 24)
        } else {
            Image(systemName: iconName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(ClipinInk.secondary)
                .frame(width: 24, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .controlColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(ClipinHoverInk.stroke, lineWidth: 0.5)
                        )
                )
        }
    }

    /// trailing 区域：⌘N + 时间戳，无胶囊背景，贴边显示。
    /// 仅在选中行显示（非选中时整体隐藏），常驻中性色调。
    private var trailingMeta: some View {
        HStack(spacing: 7) {
            if let n = shortcutNumber {
                Text("⌘\(n)")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(ClipinSelectionInk.dim)
            }

            Text(timeLabel)
                .font(.system(size: 10.5, weight: .regular))
                .foregroundStyle(ClipinSelectionInk.dim)
        }
        .padding(.trailing, 2)
    }

    private var typeIndicatorScale: CGFloat {
        if isSelected {
            return sceneState.selectedRowIconEmphasis
        }
        return isHovered ? 1.03 : 1.0
    }

    private var displayText: String {
        switch item.clipType {
        case .text, .url:
            return firstLineTruncated(item.preview) ?? "(empty)"
        case .image:
            // preview 经 SQL COALESCE 处理：有 OCR 结果时为识别文字，否则为固定占位符 "image"
            // 用 "image" 作为哨兵判断是否有可展示的 OCR 文字
            if item.preview != "image", let line = firstLineTruncated(item.preview) {
                return line
            }
            return NSLocalizedString("Image", comment: "")
        case .file:
            return FileClipboardContent.displayTitle(for: item.preview)
        }
    }

    /// 取文本首行，trim 后截断到 120 字符；空内容返回 nil
    private func firstLineTruncated(_ text: String, limit: Int = 120) -> String? {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count > limit ? String(trimmed.prefix(limit)) + "…" : trimmed
    }

    private var highlightedDisplayText: AttributedString {
        let text = displayText
        var result = AttributedString(text)

        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return result }

        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let range = text.range(of: query, options: .caseInsensitive, range: searchStart..<text.endIndex) {
            if let attrRange = Range(range, in: result) {
                result[attrRange].backgroundColor = ClipinSelectionInk.highlight
                // 命中词前景必须跟随选中态:选中行标题走 accent,这里若硬写 .primary
                // 会让命中字在选中行不变蓝(Codex 复审抓到)。
                result[attrRange].foregroundColor = isSelected ? .accentColor : .primary
            }
            searchStart = range.upperBound
        }

        return result
    }

    private var iconName: String {
        switch item.clipType {
        case .text:  return "doc.text"
        case .image: return "photo"
        case .file:  return "folder"
        case .url:   return "link"
        }
    }

    private var timeLabel: String {
        let date = Date(timeIntervalSince1970: TimeInterval(item.createdAt) / 1000.0)
        if Calendar.current.isDateInToday(date) {
            return Self.timeFormatter.string(from: date)
        }
        return Self.dateFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M/d"
        return f
    }()
}
