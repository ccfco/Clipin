import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 右侧预览面板
struct PreviewPane: View {
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.colorScheme) private var colorScheme
    let item: ClipItem?
    var searchQuery: String = ""
    @EnvironmentObject var vm: ClipboardViewModel

    private var glass: ClipinGlassPalette {
        .make(theme: settings.visualTheme, colorScheme: colorScheme)
    }

    var body: some View {
        Group {
            if let item {
                VStack(spacing: 0) {
                    content(for: item)
                    infoSection(for: item)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                }
                .padding(.top, 4)
            } else {
                placeholder(
                    icon: "doc.text.magnifyingglass",
                    title: "Select an item",
                    subtitle: "Choose a clipboard item from the list to inspect it here."
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func content(for item: ClipItem) -> some View {
        switch item.clipType {
        case .text:
            if let color = detectHexColor(in: item.content) {
                ColorSwatchPreview(color: color, originalText: item.content)
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                textPreviewBody(
                    text: item.content,
                    font: preferredTextFont(for: item.content),
                    searchQuery: searchQuery
                )
                .environmentObject(vm)
                .padding(28)
            }

        case .url:
            VStack(alignment: .leading, spacing: 14) {
                if let url = URL(string: item.content) {
                    Link(destination: url) {
                        Label(url.absoluteString, systemImage: "safari")
                            .font(.system(size: 13, weight: .medium))
                    }
                }

                textPreviewBody(
                    text: item.content,
                    font: preferredTextFont(for: item.content, baseSize: 13.5),
                    searchQuery: searchQuery
                )
                .environmentObject(vm)
            }
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

        case .image:
            ScrollView {
                if let path = item.imagePath, let image = NSImage(contentsOfFile: path) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: 400)
                        .clipShape(RoundedRectangle(cornerRadius: ClipinChrome.searchCornerRadius, style: .continuous))
                        .shadow(color: .black.opacity(0.10), radius: 12, y: 6)
                } else {
                    unavailableLabel("Image not found", systemImage: "exclamationmark.triangle")
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

        case .file:
            let paths = FileClipboardContent.paths(from: item.content)
            let primaryPath = paths.first ?? item.content
            let primaryURL = URL(fileURLWithPath: primaryPath)
            let fileListText = paths.isEmpty ? item.content : paths.joined(separator: "\n")
            let singleImageFile = paths.count == 1 && isImageFile(primaryPath)

            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: primaryPath))
                        .resizable()
                        .frame(width: 56, height: 56)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(FileClipboardContent.displayName(for: primaryPath))
                            .font(.system(size: 16, weight: .semibold))
                        Text(fileHeaderSubtitle(paths: paths, primaryURL: primaryURL))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                if singleImageFile, let image = NSImage(contentsOfFile: primaryPath) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: 320)
                        .clipShape(RoundedRectangle(cornerRadius: ClipinChrome.searchCornerRadius, style: .continuous))
                        .shadow(color: .black.opacity(0.10), radius: 12, y: 6)
                } else {
                    SelectableTextPreview(
                        text: fileListText,
                        font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                        searchQuery: searchQuery,
                        vm: vm
                    )
                    .frame(minHeight: 80)
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func infoSection(for item: ClipItem) -> some View {
        infoGrid(for: item)
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: ClipinChrome.cardCornerRadius, style: .continuous)
                    .fill(glass.controlFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: ClipinChrome.cardCornerRadius, style: .continuous)
                            .strokeBorder(glass.controlStroke, lineWidth: 0.5)
                    )
            )
    }

    private func infoGrid(for item: ClipItem) -> some View {
        // 收集所有 info 条目，然后均匀分两列（ceil(n/2) 在左，floor(n/2) 在右）
        var all: [(LocalizedStringKey, String, NSImage?)] = []

        all.append(("Source", item.sourceName ?? NSLocalizedString("Unknown", comment: ""), sourceAppIcon(for: item)))
        all.append(("Type", typeLabel(item.clipType), nil))
        if item.isPinned { all.append(("Status", NSLocalizedString("Pinned", comment: ""), nil)) }

        if item.clipType == .image, let path = item.imagePath {
            if let image = NSImage(contentsOfFile: path),
               let rep = image.representations.first {
                let w = rep.pixelsWide > 0 ? rep.pixelsWide : Int(image.size.width)
                let h = rep.pixelsHigh > 0 ? rep.pixelsHigh : Int(image.size.height)
                all.append(("Dimensions", "\(w) × \(h)", nil))
            }
            if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
               let bytes = attrs[.size] as? Int64 {
                all.append(("File size", ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file), nil))
            }
        }

        if item.clipType == .file {
            let paths = FileClipboardContent.paths(from: item.content)
            if paths.count > 1 {
                all.append(("Items", "\(paths.count)", nil))
            }
            // 单图片文件：补充尺寸和大小
            if let path = paths.first, paths.count == 1, isImageFile(path) {
                if let image = NSImage(contentsOfFile: path),
                   let rep = image.representations.first {
                    let w = rep.pixelsWide > 0 ? rep.pixelsWide : Int(image.size.width)
                    let h = rep.pixelsHigh > 0 ? rep.pixelsHigh : Int(image.size.height)
                    all.append(("Dimensions", "\(w) × \(h)", nil))
                }
                if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                   let bytes = attrs[.size] as? Int64 {
                    all.append(("File size", ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file), nil))
                }
            }
        }

        if item.clipType == .text || item.clipType == .url {
            let words = item.content.split { $0.isWhitespace || $0.isNewline }.count
            all.append(("Words", "\(words)", nil))
            all.append(("Characters", "\(item.charCount)", nil))
        }

        if item.copyCount > 1 { all.append(("Copies", "\(item.copyCount)", nil)) }
        all.append(("Copied", relativeDate(item.createdAt), nil))

        let mid = (all.count + 1) / 2
        let leftItems  = Array(all[..<mid])
        let rightItems = all.count > mid ? Array(all[mid...]) : []

        return HStack(alignment: .top, spacing: 24) {
            infoColumn(items: leftItems)
            infoColumn(items: rightItems)
        }
    }

    private func infoColumn(items: [(LocalizedStringKey, String, NSImage?)]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, entry in
                infoRow(entry.0, value: entry.1, icon: entry.2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func infoRow(_ label: LocalizedStringKey, value: String, icon: NSImage? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)

            HStack(spacing: 6) {
                if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 13, height: 13)
                        .opacity(0.78)
                }

                Text(value)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.76))
                    .textSelection(.enabled)
            }
        }
    }

    private func placeholder(icon: String, title: LocalizedStringKey, subtitle: LocalizedStringKey) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func unavailableLabel(_ text: LocalizedStringKey, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func isImageFile(_ path: String) -> Bool {
        let ext = URL(fileURLWithPath: path).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .image)
    }

    private func fileHeaderSubtitle(paths: [String], primaryURL: URL) -> String {
        let directory = primaryURL.deletingLastPathComponent().path
        guard paths.count > 1 else { return directory }
        return "\(FileClipboardContent.summaryLabel(for: paths.joined(separator: "\n"))) • \(directory)"
    }

    private func sourceAppIcon(for item: ClipItem) -> NSImage? {
        guard let bundleId = item.sourceApp else { return nil }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private func typeLabel(_ type: ClipType) -> String {
        switch type {
        case .text:  return NSLocalizedString("Text", comment: "")
        case .image: return NSLocalizedString("Image", comment: "")
        case .file:  return NSLocalizedString("File", comment: "")
        case .url:   return NSLocalizedString("Link", comment: "")
        }
    }

    private static let _absoluteDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f
    }()

    private static func absoluteDateString(_ timestamp: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000.0)
        return _absoluteDateFormatter.string(from: date)
    }

    private static let _relativeDateFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    private func relativeDate(_ timestamp: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000.0)
        return Self._relativeDateFormatter.localizedString(for: date, relativeTo: .now)
    }

    private struct textPreviewBody: View {
    let text: String
    let font: NSFont
    let searchQuery: String
    @EnvironmentObject var vm: ClipboardViewModel

    var body: some View {
        SelectableTextPreview(
            text: text,
            font: font,
            searchQuery: searchQuery,
            vm: vm
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
    private func preferredTextFont(for text: String, baseSize: CGFloat = 13) -> NSFont {
        return .systemFont(ofSize: baseSize, weight: .regular)
    }

}

private struct ColorSwatchPreview: View {
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.colorScheme) private var colorScheme
    let color: Color
    let originalText: String

    private var nsColor: NSColor {
        NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
    }

    private var glass: ClipinGlassPalette {
        .make(theme: settings.visualTheme, colorScheme: colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ZStack {
                // 浅灰底，当颜色有透明度时可见
                glass.previewCanvasTint
                    .clipShape(RoundedRectangle(cornerRadius: ClipinChrome.cardCornerRadius, style: .continuous))
                RoundedRectangle(cornerRadius: ClipinChrome.cardCornerRadius, style: .continuous)
                    .fill(color)
                RoundedRectangle(cornerRadius: ClipinChrome.cardCornerRadius, style: .continuous)
                    .strokeBorder(glass.controlStroke, lineWidth: 1)
            }
            .frame(height: 120)

            VStack(alignment: .leading, spacing: 10) {
                colorRow("HEX", value: originalText.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())
                colorRow("RGB", value: rgbString)
                colorRow("HSL", value: hslString)
            }
        }
    }

    private func colorRow(_ label: String, value: String) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .leading)
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    private var rgbString: String {
        let c = nsColor
        let r = Int((c.redComponent * 255).rounded())
        let g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent * 255).rounded())
        return "rgb(\(r), \(g), \(b))"
    }

    private var hslString: String {
        let c = nsColor
        let r = c.redComponent, g = c.greenComponent, b = c.blueComponent
        let maxC = max(r, g, b), minC = min(r, g, b)
        let l = (maxC + minC) / 2
        guard maxC != minC else {
            return "hsl(0°, 0%, \(Int((l * 100).rounded()))%)"
        }
        let d = maxC - minC
        let s = l > 0.5 ? d / (2 - maxC - minC) : d / (maxC + minC)
        var h: CGFloat
        switch maxC {
        case r: h = (g - b) / d + (g < b ? 6 : 0)
        case g: h = (b - r) / d + 2
        default: h = (r - g) / d + 4
        }
        h /= 6
        return "hsl(\(Int((h * 360).rounded()))°, \(Int((s * 100).rounded()))%, \(Int((l * 100).rounded()))%)"
    }
}

private struct SelectableTextPreview: NSViewRepresentable {
    let text: String
    let font: NSFont
    var searchQuery: String = ""
    weak var vm: ClipboardViewModel?

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = NSTextView()
        textView.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.usesFindBar = true
        textView.allowsUndo = false
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.minSize = .zero
        textView.autoresizingMask = [.width]
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.controlAccentColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand
        ]

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        let textColor = NSColor.labelColor
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 6
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: para
        ]
        let attributed = NSMutableAttributedString(string: text, attributes: attrs)

        // 搜索高亮
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            let nsText = text as NSString
            var searchRange = NSRange(location: 0, length: nsText.length)
            let highlightBg = NSColor.controlAccentColor.withAlphaComponent(0.25)
            while searchRange.location < nsText.length {
                let found = nsText.range(of: query, options: .caseInsensitive, range: searchRange)
                guard found.location != NSNotFound else { break }
                attributed.addAttribute(.backgroundColor, value: highlightBg, range: found)
                searchRange.location = found.location + found.length
                searchRange.length = nsText.length - searchRange.location
            }
        }

        // URL 链接检测：用 NSDataDetector 写入 .link 属性，使链接可点击
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            detector.enumerateMatches(in: text, options: [], range: fullRange) { match, _, _ in
                if let match, let url = match.url {
                    attributed.addAttribute(.link, value: url, range: match.range)
                }
            }
        }

        // 只在内容或高亮变化时更新，避免不必要的重绘
        if textView.attributedString() != attributed {
            textView.textStorage?.setAttributedString(attributed)
            textView.setSelectedRange(NSRange(location: 0, length: 0))
        }
    }
}
