import SwiftUI
import AppKit
import ImageIO
import NaturalLanguage
import UniformTypeIdentifiers

/// 右侧预览面板
struct PreviewPane: View {
    let item: ClipItem?
    var searchQuery: String = ""
    let sceneState: ClipinSceneState
    @EnvironmentObject var vm: ClipboardViewModel

    var body: some View {
        Group {
            if let item {
                contentStage(for: item)
            } else if vm.selectedListItem != nil {
                // 已有选中行，但完整 ClipItem 还在后台 SQLite 读取中（或 ID-match guard
                // 拒绝了上一次选中的陈旧数据）。显式给一个安静的加载态，避免出现
                // "有内容 → 空占位 → 新内容" 的闪烁；正常路径 <16ms 看不到 spinner。
                contentStage {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                contentStage {
                    placeholder(
                        icon: "doc.text.magnifyingglass",
                        title: "Select an item",
                        subtitle: "Choose a clipboard item from the list to inspect it here."
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scaleEffect(sceneState.previewScale)
        .offset(y: sceneState.previewLift)
        .animation(ClipinMotion.focusShift, value: sceneState)
    }

    private func contentStage(for item: ClipItem) -> some View {
        contentStage {
            content(for: item)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    previewFooter(for: item)
                        .padding(.top, 8)
                }
        }
    }

    private func contentStage<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 16)
            .padding(.vertical, 15)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.bottom, ClipinChrome.floatingFooterBand)
    }

    private func previewFooter(for item: ClipItem) -> some View {
        let entries = footerEntries(for: item)
        return PreviewFooterRail(
            entries: entries
        )
        .opacity(sceneState.metadataOpacity)
        .offset(y: sceneState.metadataLift)
        .animation(ClipinMotion.focusShift, value: sceneState)
    }

    @ViewBuilder
    private func content(for item: ClipItem) -> some View {
        switch item.clipType {
        case .text:
            if let color = detectHexColor(in: item.content) {
                ColorSwatchPreview(color: color, originalText: item.content)
                    .frame(maxWidth: 480, alignment: .leading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                TextPreviewBody(
                    text: item.content,
                    font: previewTextFont(),
                    searchQuery: searchQuery
                )
                .environmentObject(vm)
                .frame(maxWidth: 560, maxHeight: .infinity, alignment: .topLeading)
            }

        case .url:
            URLPreviewView(
                urlString: item.content,
                searchQuery: searchQuery
            )
            .environmentObject(vm)

        case .image:
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let path = item.imagePath, let image = NSImage(contentsOfFile: path) {
                        mediaCanvas {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: .infinity, maxHeight: 392)
                        }
                    } else {
                        unavailableLabel("Image not found", systemImage: "exclamationmark.triangle")
                    }

                    // OCR 识别文字区域（有结果时展示，可选中复制，支持搜索高亮）
                    if let ocr = item.ocrText, !ocr.isEmpty {
                        supportingBlock(title: "OCR text", systemImage: "text.viewfinder") {
                            SelectableTextPreview(
                                text: ocr,
                                font: .systemFont(ofSize: 13, weight: .regular),
                                searchQuery: searchQuery,
                                vm: vm
                            )
                            .frame(minHeight: 72, maxHeight: 200)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

        case .file:
            let paths = FileClipboardContent.paths(from: item.content)
            let primaryPath = paths.first ?? item.content
            let primaryURL = URL(fileURLWithPath: primaryPath)
            let fileListText = paths.isEmpty ? item.content : paths.joined(separator: "\n")
            let singleImageFile = paths.count == 1 && isImageFile(primaryPath)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color(nsColor: .controlColor))
                            Image(nsImage: NSWorkspace.shared.icon(forFile: primaryPath))
                                .resizable()
                                .frame(width: 54, height: 54)
                        }
                        .frame(width: 72, height: 72)

                        VStack(alignment: .leading, spacing: 6) {
                            Text(FileClipboardContent.displayName(for: primaryPath))
                                .font(.system(size: 17, weight: .semibold))
                            Text(fileHeaderSubtitle(paths: paths, primaryURL: primaryURL))
                                .font(.system(size: 12.5))
                                .foregroundStyle(ClipinInk.secondary)
                                .textSelection(.enabled)
                        }
                    }

                    if singleImageFile, let image = NSImage(contentsOfFile: primaryPath) {
                        mediaCanvas {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: .infinity, maxHeight: 360)
                        }
                    } else {
                        supportingBlock(title: paths.count > 1 ? "Selection" : "Path", systemImage: "folder") {
                            SelectableTextPreview(
                                text: fileListText,
                                font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                                searchQuery: searchQuery,
                                vm: vm
                            )
                            .frame(minHeight: 80)
                        }
                    }
                }
            }
        }
    }

    private func footerEntries(for item: ClipItem) -> [PreviewRailEntry] {
        var entries: [PreviewRailEntry] = []

        if let source = primarySourceBadge(for: item) {
            entries.append(PreviewRailEntry(item: source, prominence: .context))
        }

        entries.append(PreviewRailEntry(item: timeBadge(for: item), prominence: .supporting))

        if let pinned = pinnedBadge(for: item) {
            entries.append(PreviewRailEntry(item: pinned, prominence: .context))
        }

        entries.append(contentsOf: metricBadges(for: item).map {
            PreviewRailEntry(item: $0, prominence: .supporting)
        })

        if let formats = formatsBadge(for: item) {
            entries.append(PreviewRailEntry(item: formats, prominence: .supporting))
        }

        if let usage = usageBadge(for: item) {
            entries.append(PreviewRailEntry(item: usage, prominence: .supporting))
        }

        if let ocr = ocrBadge(for: item) {
            entries.append(PreviewRailEntry(item: ocr, prominence: .context))
        }

        return entries
    }

    private func metricBadges(for item: ClipItem) -> [PreviewBadgeItem] {
        var items: [PreviewBadgeItem] = []

        switch item.clipType {
        case .text:
            items.append(
                PreviewBadgeItem(
                    id: "characters",
                    title: String(
                        format: NSLocalizedString("%d chars", comment: ""),
                        displayCharacterCount(for: item.content)
                    ),
                    systemImage: "character"
                )
            )

            if let words = wordCount(for: item.content) {
                items.append(
                        PreviewBadgeItem(
                            id: "words",
                            title: String(format: NSLocalizedString("%d words", comment: ""), words),
                            systemImage: "textformat"
                        )
                    )
            }

        case .image:
            if let path = item.imagePath {
                if let dimensions = imageDimensions(at: path) {
                    items.append(
                        PreviewBadgeItem(
                            id: "dimensions",
                            title: "\(dimensions.width) × \(dimensions.height)",
                            systemImage: "aspectratio"
                        )
                    )
                }

                if let size = fileSizeString(at: path) {
                    items.append(
                        PreviewBadgeItem(
                            id: "file_size",
                            title: size,
                            systemImage: "internaldrive"
                        )
                    )
                }
            }

        case .file:
            let paths = FileClipboardContent.paths(from: item.content)
            if paths.count > 1 {
                items.append(
                    PreviewBadgeItem(
                        id: "items",
                        title: String(format: NSLocalizedString("%d items", comment: ""), paths.count),
                        systemImage: "square.stack.3d.up"
                    )
                )
            }

            if let path = paths.first, paths.count == 1 {
                if let size = fileSizeString(at: path) {
                    items.append(
                        PreviewBadgeItem(
                            id: "file_size",
                            title: size,
                            systemImage: "internaldrive"
                        )
                    )
                }

                if isImageFile(path), let dimensions = imageDimensions(at: path) {
                    items.append(
                        PreviewBadgeItem(
                            id: "dimensions",
                            title: "\(dimensions.width) × \(dimensions.height)",
                            systemImage: "aspectratio"
                        )
                    )
                }
            }

        case .url:
            break
        }

        return items
    }

    private func displayCharacterCount(for text: String) -> Int {
        text.count
    }

    private func wordCount(for text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = trimmed
        let language = NLLanguageRecognizer.dominantLanguage(for: trimmed)
        if let language {
            tokenizer.setLanguage(language)
        }

        if shouldHideWordCount(for: language) {
            return nil
        }

        var count = 0
        tokenizer.enumerateTokens(in: trimmed.startIndex..<trimmed.endIndex) { _, _ in
            count += 1
            return true
        }

        return count > 0 ? count : nil
    }

    private func shouldHideWordCount(for language: NLLanguage?) -> Bool {
        guard let language else { return false }
        switch language {
        case .simplifiedChinese, .traditionalChinese, .japanese, .korean:
            return true
        default:
            return false
        }
    }

    private func imageDimensions(at path: String) -> (width: Int, height: Int)? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }

        return (width, height)
    }

    private func fileSizeString(at path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [
            .isDirectoryKey,
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
            .totalFileSizeKey,
            .fileSizeKey
        ]) else { return nil }

        if values.isDirectory == true {
            return nil
        }

        let bytes =
            values.totalFileAllocatedSize ??
            values.fileAllocatedSize ??
            values.totalFileSize ??
            values.fileSize

        guard let bytes else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func primarySourceBadge(for item: ClipItem) -> PreviewBadgeItem? {
        guard let sourceName = item.sourceName else { return nil }
        return PreviewBadgeItem(
            id: "source",
            title: sourceName,
            icon: sourceAppIcon(for: item)
        )
    }

    private func timeBadge(for item: ClipItem) -> PreviewBadgeItem {
        PreviewBadgeItem(
            id: "copied",
            title: relativeDate(item.createdAt),
            systemImage: "clock",
            helpText: Self.absoluteDateString(item.createdAt)
        )
    }

    private func pinnedBadge(for item: ClipItem) -> PreviewBadgeItem? {
        guard item.isPinned else { return nil }
        return PreviewBadgeItem(
            id: "pinned",
            title: NSLocalizedString("Pinned", comment: ""),
            systemImage: "pin.fill"
        )
    }

    /// 使用频率 badge：粘贴次数优先（更能反映真实使用价值），否则展示复制次数
    private func usageBadge(for item: ClipItem) -> PreviewBadgeItem? {
        if item.pasteCount > 0 {
            return PreviewBadgeItem(
                id: "usage",
                title: item.pasteCount == 1
                    ? NSLocalizedString("Pasted once", comment: "")
                    : String(format: NSLocalizedString("Pasted %d times", comment: ""), item.pasteCount),
                systemImage: "arrow.up.doc"
            )
        }
        if item.copyCount > 1 {
            return PreviewBadgeItem(
                id: "usage",
                title: String(format: NSLocalizedString("%d copies", comment: ""), item.copyCount),
                systemImage: "square.on.square"
            )
        }
        return nil
    }

    private var formatsDisplay: String {
        var labels: [String] = ["plain"]
        let utis = vm.selectedRepresentationUTIs
        if utis.contains("public.html") { labels.append("html") }
        if utis.contains("public.rtf")  { labels.append("rtf") }
        if utis.contains("public.rtfd") { labels.append("rtfd") }
        if utis.contains("public.url")  { labels.append("url") }
        return labels.joined(separator: " · ")
    }

    /// Formats badge：展示当前条目保留了哪些 representation（plain/html/rtf/rtfd/url）。
    /// 仅在文本/URL 条目，且除 plain 外还有其它格式时显示，避免对纯文本条目造成视觉噪声。
    private func formatsBadge(for item: ClipItem) -> PreviewBadgeItem? {
        guard item.clipType == .text || item.clipType == .url else { return nil }
        let display = formatsDisplay
        guard display != "plain" else { return nil }
        return PreviewBadgeItem(
            id: "formats",
            title: display,
            systemImage: "doc.richtext",
            helpText: NSLocalizedString("preview.metadata.formats", comment: "Formats label in preview metadata")
        )
    }

    private func ocrBadge(for item: ClipItem) -> PreviewBadgeItem? {
        guard item.clipType == .image,
              let ocr = item.ocrText, !ocr.isEmpty else { return nil }
        return PreviewBadgeItem(
            id: "ocr",
            title: NSLocalizedString("OCR", comment: ""),
            systemImage: "text.viewfinder"
        )
    }

    fileprivate struct PreviewBadgeItem: Identifiable {
        let id: String
        let title: String
        let systemImage: String?
        let icon: NSImage?
        let helpText: String?

        init(
            id: String,
            title: String,
            systemImage: String? = nil,
            icon: NSImage? = nil,
            helpText: String? = nil
        ) {
            self.id = id
            self.title = title
            self.systemImage = systemImage
            self.icon = icon
            self.helpText = helpText
        }
    }

    fileprivate struct PreviewRailEntry: Identifiable {
        let item: PreviewBadgeItem
        let prominence: PreviewBadgeProminence

        var id: String { item.id }
    }

    private func placeholder(icon: String, title: LocalizedStringKey, subtitle: LocalizedStringKey) -> some View {
        VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: ClipinChrome.heroOrbCornerRadius, style: .continuous)
                    .fill(Color.accentColor.opacity(0.10))
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 56, height: 56)

            Text(title)
                .font(.system(size: 14, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(ClipinInk.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func unavailableLabel(_ text: LocalizedStringKey, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 13))
            .foregroundStyle(ClipinInk.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // 预览图片直接落在毛玻璃面上：无底板、无描边、无阴影、无内边距，
    // 只给位图本身一个轻微圆角，避免裁切边过于锐利（对齐 Raycast）。
    private func mediaCanvas<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .clipShape(RoundedRectangle(cornerRadius: ClipinChrome.detailMediaCornerRadius, style: .continuous))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func supportingBlock<Content: View>(
        title: LocalizedStringKey,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ClipinInk.secondary)

            content()
        }
        .padding(12)
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

    private struct TextPreviewBody: View {
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

    private func previewTextFont() -> NSFont {
        .systemFont(ofSize: 13.5, weight: .regular)
    }

}

private struct ColorSwatchPreview: View {
    @Environment(\.colorScheme) private var colorScheme
    let color: Color
    let originalText: String

    private var nsColor: NSColor {
        NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ZStack {
                // 浅灰底，当颜色有透明度时可见
                Color(nsColor: .controlBackgroundColor)
                    .clipShape(RoundedRectangle(cornerRadius: ClipinChrome.cardCornerRadius, style: .continuous))
                RoundedRectangle(cornerRadius: ClipinChrome.cardCornerRadius, style: .continuous)
                    .fill(color)
                RoundedRectangle(cornerRadius: ClipinChrome.cardCornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
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
                .foregroundStyle(Color.primary.opacity(colorScheme == .dark ? 0.78 : 0.68))
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

private enum PreviewBadgeProminence {
    case context
    case supporting
}

private struct PreviewValueBadge: View {
    let item: PreviewPane.PreviewBadgeItem
    let prominence: PreviewBadgeProminence

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage = item.systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: prominence == .context ? 9.5 : 10, weight: .semibold))
            } else if let icon = item.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: prominence == .context ? 10 : 11, height: prominence == .context ? 10 : 11)
            }

            Text(item.title)
                .font(.system(size: prominence == .context ? 10 : 10.5, weight: .medium, design: .rounded))
                .lineLimit(1)
                .textSelection(.enabled)
        }
        .fixedSize(horizontal: true, vertical: false)
        .foregroundStyle(ClipinInk.secondary)
        .padding(.horizontal, prominence == .context ? 8 : 9)
        .padding(.vertical, prominence == .context ? 4 : 5)
        .clipinChromeGlass(in: Capsule(style: .continuous))
        .help(item.helpText ?? item.title)
    }
}

private struct PreviewFooterRail: View {
    let entries: [PreviewPane.PreviewRailEntry]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(entries) { entry in
                    PreviewValueBadge(
                        item: entry.item,
                        prominence: entry.prominence
                    )
                }
            }
            .padding(.horizontal, 1)
            .padding(.top, 8)
            .padding(.bottom, 1)
        }
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

// MARK: - URL Preview

/// `NSImage` 的 Sendable 包装：actor 已串行化访问，跨线程传递安全。
private final class SendableImage: @unchecked Sendable {
    let image: NSImage
    init(_ image: NSImage) { self.image = image }
}

/// 远程 favicon 缓存：actor 串行化 + pending dedup，避免列表来回切换时同一 host 重复发请求。
/// 拿不到就返回 nil，由调用方自己画 globe 占位，不在这里造假数据。
private actor FaviconCache {
    static let shared = FaviconCache()
    private var cache: [String: SendableImage] = [:]
    private var pending: [String: Task<SendableImage?, Never>] = [:]

    func icon(for host: String) async -> SendableImage? {
        if let cached = cache[host] { return cached }
        if let task = pending[host] { return await task.value }

        let task = Task<SendableImage?, Never> {
            guard let url = URL(string: "https://www.google.com/s2/favicons?domain=\(host)&sz=128") else {
                return nil
            }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let img = NSImage(data: data) else { return nil }
                return SendableImage(img)
            } catch {
                return nil
            }
        }
        pending[host] = task
        let result = await task.value
        pending[host] = nil
        if let result {
            cache[host] = result
        }
        return result
    }
}

private struct FaviconView: View {
    let host: String?
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlColor))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(12)
            } else {
                Image(systemName: "globe")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(ClipinInk.secondary)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.6)
        )
        .task(id: host ?? "") {
            image = nil
            guard let host, !host.isEmpty else { return }
            image = await FaviconCache.shared.icon(for: host)?.image
        }
    }
}

private struct URLPreviewView: View {
    let urlString: String
    let searchQuery: String
    @EnvironmentObject var vm: ClipboardViewModel

    private var url: URL? { URL(string: urlString) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                fullURLBlock
                if let url, !queryItems(for: url).isEmpty {
                    queryBlock(items: queryItems(for: url))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: 560, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: 14) {
            FaviconView(host: url?.host)
                .frame(width: 64, height: 64)

            VStack(alignment: .leading, spacing: 4) {
                Text(url?.host ?? urlString)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)

                if let subtitle = pathSubtitle {
                    Text(subtitle)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(ClipinInk.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let url {
                Link(destination: url) {
                    HStack(spacing: 5) {
                        Image(systemName: "safari")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Open")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .foregroundStyle(Color.accentColor)
                    .clipinChromeGlass(in: Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .help("Open in default browser")
            }
        }
    }

    private var pathSubtitle: String? {
        guard let url else { return nil }
        if !url.path.isEmpty, url.path != "/" { return url.path }
        return nil
    }

    private var fullURLBlock: some View {
        urlInfoBlock(title: "Full URL", systemImage: "link") {
            SelectableTextPreview(
                text: urlString,
                font: .monospacedSystemFont(ofSize: 12.5, weight: .regular),
                searchQuery: searchQuery,
                vm: vm
            )
            .frame(minHeight: 44, maxHeight: 92)
        }
    }

    private func queryItems(for url: URL) -> [(String, String)] {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems else { return [] }
        return items.map { ($0.name, $0.value ?? "") }
    }

    private func queryBlock(items: [(String, String)]) -> some View {
        urlInfoBlock(title: "Query parameters", systemImage: "questionmark.app") {
            VStack(spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, pair in
                    HStack(alignment: .top, spacing: 12) {
                        Text(pair.0)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(ClipinInk.secondary)
                            .frame(width: 96, alignment: .leading)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .textSelection(.enabled)
                        Text(pair.1)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(ClipinInk.primary)
                            .lineLimit(3)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private func urlInfoBlock<Content: View>(
        title: LocalizedStringKey,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ClipinInk.secondary)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
