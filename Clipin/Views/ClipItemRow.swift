import SwiftUI
import AppKit

/// 检测十六进制颜色字符串，返回 SwiftUI Color（#RGB / #RRGGBB / #RRGGBBAA）
func detectHexColor(in text: String) -> Color? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("#"), (4...9).contains(trimmed.count) else { return nil }
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
    private var cache: [String: NSImage] = [:]
    private let lock = NSLock()

    func icon(for bundleId: String) -> NSImage? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[bundleId] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache[bundleId] = icon
        return icon
    }
}

private final class ThumbnailCache: @unchecked Sendable {
    private var cache: [String: NSImage] = [:]
    private let lock = NSLock()

    func thumbnail(for path: String) -> NSImage? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[path] { return cached }
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        let thumbSize: CGFloat = 56
        let thumb = NSImage(size: NSSize(width: thumbSize, height: thumbSize))
        thumb.lockFocus()
        image.draw(in: NSRect(x: 0, y: 0, width: thumbSize, height: thumbSize),
                   from: .zero, operation: .copy, fraction: 1.0)
        thumb.unlockFocus()
        cache[path] = thumb
        return thumb
    }
}

/// 列表中的单行剪贴板项 — 极简单行布局
struct ClipItemRow: View {
    let item: ClipListItem
    var shortcutNumber: Int? = nil
    var searchQuery: String = ""
    var isSelected: Bool = false
    var isHovered: Bool = false

    var body: some View {
        HStack(spacing: 9) {
            typeIndicator

            Text(highlightedDisplayText)
                .font(.system(size: 13.5, weight: isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.92))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Pin 标记 — 仅选中/hover 时可见
            if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(isSelected ? Color.accentColor.opacity(0.58) : Color(nsColor: .tertiaryLabelColor))
                    .opacity(isSelected || isHovered ? 1 : 0.3)
            }

            // ⌘N 快捷键徽章
            // ⌘1-3 默认半显（opacity: 0.4），让用户发现最快路径；其余 hover/selected 才显
            if let n = shortcutNumber {
                let alwaysVisible = n <= 3
                Text("⌘\(n)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(isSelected ? Color.accentColor.opacity(0.64) : Color(nsColor: .quaternaryLabelColor))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(isSelected ? Color.white.opacity(0.54) : Color.white.opacity(0.18))
                    )
                    .opacity(isSelected || isHovered ? 1 : (alwaysVisible ? 0.4 : 0))
            }

            // 时间 — 右对齐，退场角色
            Text(timeLabel)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(isSelected ? Color.accentColor.opacity(0.60) : Color(nsColor: .tertiaryLabelColor))
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .animation(.easeOut(duration: 0.1), value: isSelected)
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
                .foregroundStyle(isSelected ? Color.accentColor.opacity(0.72) : Color.secondary)
                .frame(width: 24, height: 24)
        }
    }

    private var displayText: String {
        switch item.clipType {
        case .text, .url:
            let firstLine = item.preview.split(whereSeparator: \.isNewline).first.map(String.init) ?? item.preview
            let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return "(empty)" }
            return trimmed.count > 120 ? String(trimmed.prefix(120)) + "…" : trimmed
        case .image:
            return "Image"
        case .file:
            let url = URL(fileURLWithPath: item.preview)
            return url.lastPathComponent.isEmpty ? item.preview : url.lastPathComponent
        }
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
                result[attrRange].backgroundColor = .accentColor.opacity(0.17)
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
