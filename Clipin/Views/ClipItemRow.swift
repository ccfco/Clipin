import SwiftUI
import AppKit

/// bundle identifier → app icon 缓存，避免每次渲染都查 NSWorkspace
private let appIconCache = AppIconCache()

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

/// 列表中的单行剪贴板项
struct ClipItemRow: View {
    let item: ClipListItem
    let isSelected: Bool
    var shortcutNumber: Int? = nil
    var searchQuery: String = ""

    var body: some View {
        HStack(spacing: 10) {
            // 图片类型显示缩略图，其他类型显示图标
            if item.clipType == .image, let path = item.imagePath,
               let nsImage = NSImage(contentsOfFile: path) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                Image(systemName: iconName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(iconColor)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(iconBackground)
                    )
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(highlightedDisplayText)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)

                HStack(spacing: 4) {
                    if let bundleId = item.sourceApp,
                       let icon = appIconCache.icon(for: bundleId) {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 12, height: 12)
                    }

                    if let sourceName = item.sourceName, !sourceName.isEmpty {
                        Text(sourceName)
                    }

                    Text(timeLabel)
                        .fontDesign(.monospaced)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            if let n = shortcutNumber {
                Text("⌘\(n)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.15))
                    )
            }

            if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.22) : Color.clear, lineWidth: 1)
        )
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

        // 大小写不敏感查找所有匹配范围并加高亮背景
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let range = text.range(of: query, options: .caseInsensitive, range: searchStart..<text.endIndex) {
            if let attrRange = Range(range, in: result) {
                result[attrRange].backgroundColor = .accentColor.opacity(0.25)
                result[attrRange].foregroundColor = .primary
            }
            searchStart = range.upperBound
        }

        return result
    }

    private var iconName: String {
        switch item.clipType {
        case .text:
            return "doc.text"
        case .image:
            return "photo"
        case .file:
            return "folder"
        case .url:
            return "link"
        }
    }

    private var iconColor: Color {
        switch item.clipType {
        case .text:
            return .accentColor
        case .image:
            return .green
        case .file:
            return .orange
        case .url:
            return .blue
        }
    }

    private var iconBackground: Color {
        if isSelected {
            return Color.accentColor.opacity(0.14)
        }
        return Color(nsColor: .quaternaryLabelColor).opacity(0.08)
    }

    private var timeLabel: String {
        let date = Date(timeIntervalSince1970: TimeInterval(item.createdAt) / 1000.0)
        if Calendar.current.isDateInToday(date) {
            return Self.timeFormatter.string(from: date)
        }
        return Self.dateFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        return formatter
    }()
}
