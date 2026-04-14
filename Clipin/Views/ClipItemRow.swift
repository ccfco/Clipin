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

/// bundle identifier → app icon 缓存
private let appIconCache = AppIconCache()

/// 图片缩略图缓存
private let thumbnailCache = ThumbnailCache()

private final class AppIconCache: @unchecked Sendable {
    private static let maxSize = 100
    private var cache: [String: NSImage] = [:]
    private var keys: [String] = []   // 尾部 = 最近使用
    private let lock = NSLock()

    func icon(for bundleId: String) -> NSImage? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[bundleId] {
            touch(bundleId)
            return cached
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        insert(key: bundleId, value: icon)
        return icon
    }

    private func touch(_ key: String) {
        keys.removeAll { $0 == key }
        keys.append(key)
    }

    private func insert(key: String, value: NSImage) {
        if cache.count >= Self.maxSize, let lru = keys.first {
            cache.removeValue(forKey: lru)
            keys.removeFirst()
        }
        cache[key] = value
        keys.append(key)
    }
}

private final class ThumbnailCache: @unchecked Sendable {
    private static let maxSize = 100
    private var cache: [String: NSImage] = [:]
    private var keys: [String] = []
    private let lock = NSLock()

    func thumbnail(for path: String) -> NSImage? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[path] {
            touch(path)
            return cached
        }
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        let thumbSize: CGFloat = 56
        let thumb = NSImage(size: NSSize(width: thumbSize, height: thumbSize))
        thumb.lockFocus()
        image.draw(in: NSRect(x: 0, y: 0, width: thumbSize, height: thumbSize),
                   from: .zero, operation: .copy, fraction: 1.0)
        thumb.unlockFocus()
        insert(key: path, value: thumb)
        return thumb
    }

    private func touch(_ key: String) {
        keys.removeAll { $0 == key }
        keys.append(key)
    }

    private func insert(key: String, value: NSImage) {
        if cache.count >= Self.maxSize, let lru = keys.first {
            cache.removeValue(forKey: lru)
            keys.removeFirst()
        }
        cache[key] = value
        keys.append(key)
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
    let glass: ClipinGlassPalette
    let hierarchy: ClipinPanelHierarchy

    var body: some View {
        HStack(spacing: 9) {
            typeIndicator
                .scaleEffect(typeIndicatorScale)
                .animation(ClipinMotion.feedback, value: isHovered)

            Text(highlightedDisplayText)
                .font(.system(size: 13.5, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? hierarchy.selection.ink : Color.primary.opacity(0.92))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(isSelected ? hierarchy.selection.dimInk : hierarchy.support.smallLabelInk)
                    .opacity(isSelected || isHovered ? 1 : 0)
            }

            trailingMeta
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .animation(ClipinMotion.selection, value: isSelected)
    }

    /// 类型指示器：图片显示缩略图，颜色值显示色块，其他显示单色图标
    @ViewBuilder
    private var typeIndicator: some View {
        if item.clipType == .image, let path = item.imagePath,
           let nsImage = thumbnailCache.thumbnail(for: path) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 24, height: 24)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
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
                .foregroundStyle(isSelected ? hierarchy.selection.ink : hierarchy.support.subduedInk)
                .frame(width: 24, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isSelected ? hierarchy.selection.badgeFill : glass.keycapTint)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(
                                    isSelected ? hierarchy.selection.stroke.opacity(0.72) : glass.hoverStroke.opacity(0.85),
                                    lineWidth: 0.5
                                )
                        )
                )
                .shadow(
                    color: glass.emphasisStrongFill.opacity(isSelected ? 0.18 * sceneState.stripAccentOpacity : 0),
                    radius: 8,
                    y: 2
                )
        }
    }

    private var trailingMeta: some View {
        HStack(spacing: 6) {
            if let n = shortcutNumber {
                Text("⌘\(n)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(
                        isSelected
                            ? hierarchy.selection.dimInk
                            : hierarchy.support.smallLabelInk
                    )
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(
                                isSelected
                                    ? hierarchy.selection.badgeFill
                                    : Color.primary.opacity(isHovered ? 0.08 : 0.05)
                            )
                    )
            }

            Text(timeLabel)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(isSelected ? hierarchy.selection.dimInk : hierarchy.support.smallLabelInk)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(metaFill)
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(metaStroke, lineWidth: 0.5)
                )
        )
    }

    private var metaFill: Color {
        if isSelected {
            return hierarchy.selection.badgeFill.opacity(0.94)
        }
        return glass.keycapTint.opacity(isHovered ? 0.94 : 0.82)
    }

    private var metaStroke: Color {
        if isSelected {
            return hierarchy.selection.stroke.opacity(0.72)
        }
        return glass.controlStroke.opacity(isHovered ? 0.72 : 0.56)
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
                result[attrRange].backgroundColor = hierarchy.selection.highlight
                result[attrRange].foregroundColor = .primary
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
