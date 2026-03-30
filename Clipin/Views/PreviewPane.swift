import SwiftUI
import AppKit
import ImageIO
import NaturalLanguage
import UniformTypeIdentifiers

/// 右侧预览面板
struct PreviewPane: View {
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.colorScheme) private var colorScheme
    let item: ClipItem?
    var searchQuery: String = ""
    let sceneState: ClipinSceneState
    @EnvironmentObject var vm: ClipboardViewModel

    private var glass: ClipinGlassPalette {
        .make(theme: settings.visualTheme, colorScheme: colorScheme)
    }

    private var hierarchy: ClipinPanelHierarchy {
        .make(glass: glass, colorScheme: colorScheme)
    }

    var body: some View {
        Group {
            if let item {
                contentStage(for: item)
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
            VStack(alignment: .leading, spacing: 16) {
                content(for: item)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                previewFooter(for: item)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func contentStage<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 16)
            .padding(.vertical, 15)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                ClipinSurfaceBackground(
                    role: .contentStage,
                    cornerRadius: ClipinChrome.detailStageCornerRadius,
                    glass: glass
                )
            )
            .overlay {
                RoundedRectangle(cornerRadius: ClipinChrome.detailStageCornerRadius, style: .continuous)
                    .strokeBorder(glass.emphasisStroke.opacity(sceneState.hasSelection ? 0.12 : 0.06), lineWidth: 0.6)
            }
            .padding(.horizontal, ClipinChrome.detailObjectInset)
    }

    private func previewFooter(for item: ClipItem) -> some View {
        let entries = footerEntries(for: item)
        return PreviewFooterRail(
            entries: entries,
            glass: glass,
            hierarchy: hierarchy,
            colorScheme: colorScheme
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
            VStack(alignment: .leading, spacing: 14) {
                if let url = URL(string: item.content) {
                    Link(destination: url) {
                        Label(url.absoluteString, systemImage: "safari")
                            .font(.system(size: 13, weight: .medium))
                    }
                }

                TextPreviewBody(
                    text: item.content,
                    font: previewTextFont(),
                    searchQuery: searchQuery
                )
                .environmentObject(vm)
            }
            .frame(maxWidth: 560, maxHeight: .infinity, alignment: .topLeading)

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
                                .fill(glass.keycapTint)
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
                                .foregroundStyle(hierarchy.support.subduedInk)
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

        if let copies = copiesBadge(for: item) {
            entries.append(PreviewRailEntry(item: copies, prominence: .supporting))
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
                    title: "\(displayCharacterCount(for: item.content)) chars",
                    systemImage: "character"
                )
            )

            if let words = wordCount(for: item.content) {
                items.append(
                    PreviewBadgeItem(
                        id: "words",
                        title: "\(words) words",
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
                        title: "\(paths.count) items",
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
        if let language = NLLanguageRecognizer.dominantLanguage(for: trimmed) {
            tokenizer.setLanguage(language)
        }

        var count = 0
        tokenizer.enumerateTokens(in: trimmed.startIndex..<trimmed.endIndex) { _, _ in
            count += 1
            return true
        }

        return count > 0 ? count : nil
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
            systemImage: "pin.fill",
            emphasis: true
        )
    }

    private func copiesBadge(for item: ClipItem) -> PreviewBadgeItem? {
        guard item.copyCount > 1 else { return nil }
        return PreviewBadgeItem(
            id: "copies",
            title: "\(item.copyCount) copies",
            systemImage: "square.on.square"
        )
    }

    fileprivate struct PreviewBadgeItem: Identifiable {
        let id: String
        let title: String
        let systemImage: String?
        let icon: NSImage?
        let emphasis: Bool
        let helpText: String?

        init(
            id: String,
            title: String,
            systemImage: String? = nil,
            icon: NSImage? = nil,
            emphasis: Bool = false,
            helpText: String? = nil
        ) {
            self.id = id
            self.title = title
            self.systemImage = systemImage
            self.icon = icon
            self.emphasis = emphasis
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
            ClipinSymbolOrb(
                systemImage: icon,
                glass: glass,
                hierarchy: hierarchy,
                size: 56,
                iconSize: 18,
                emphasis: 0.55
            )
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(hierarchy.support.subduedInk)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func unavailableLabel(_ text: LocalizedStringKey, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 13))
            .foregroundStyle(hierarchy.support.subduedInk)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func mediaCanvas<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: ClipinChrome.detailMediaCornerRadius, style: .continuous)
                .fill(glass.previewCanvasTint.opacity(colorScheme == .dark ? 0.74 : 0.58))
            content()
                .padding(16)
        }
        .clipShape(RoundedRectangle(cornerRadius: ClipinChrome.detailMediaCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ClipinChrome.detailMediaCornerRadius, style: .continuous)
                .strokeBorder(glass.controlStroke.opacity(colorScheme == .dark ? 0.68 : 0.48), lineWidth: 0.6)
        )
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.12 : 0.06), radius: 8, y: 3)
    }

    private func supportingBlock<Content: View>(
        title: LocalizedStringKey,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hierarchy.support.subduedInk)

            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ClipinSurfaceBackground(
                role: .grouped,
                cornerRadius: ClipinChrome.detailMetadataCornerRadius,
                glass: glass
            )
        )
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
    let glass: ClipinGlassPalette
    let hierarchy: ClipinPanelHierarchy
    let colorScheme: ColorScheme

    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage = item.systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: prominence == .context ? 10 : 10.5, weight: .semibold))
            } else if let icon = item.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: prominence == .context ? 11 : 12, height: prominence == .context ? 11 : 12)
            }

            Text(item.title)
                .font(.system(size: prominence == .context ? 10.5 : 11, weight: .medium, design: .rounded))
                .lineLimit(1)
                .textSelection(.enabled)
        }
        .fixedSize(horizontal: true, vertical: false)
        .foregroundStyle(foreground)
        .padding(.horizontal, prominence == .context ? 8 : 10)
        .padding(.vertical, prominence == .context ? 5 : 6)
        .background(
            Capsule(style: .continuous)
                .fill(backgroundFill)
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(borderColor, lineWidth: 0.5)
                )
        )
        .help(item.helpText ?? item.title)
    }

    private var foreground: Color {
        if item.emphasis {
            return glass.emphasisInk.opacity(isDark ? 0.92 : 0.82)
        }
        return prominence == .context ? hierarchy.support.smallLabelInk : hierarchy.support.subduedInk
    }

    private var backgroundFill: Color {
        if item.emphasis {
            return hierarchy.selection.badgeFill.opacity(isDark ? 0.94 : 0.90)
        }
        switch prominence {
        case .context:
            return glass.keycapTint.opacity(isDark ? 1.0 : 0.94)
        case .supporting:
            return glass.controlFill.opacity(isDark ? 0.76 : 0.60)
        }
    }

    private var borderColor: Color {
        if item.emphasis {
            return hierarchy.selection.stroke.opacity(isDark ? 0.92 : 0.76)
        }
        switch prominence {
        case .context:
            return glass.hoverStroke.opacity(isDark ? 0.85 : 0.68)
        case .supporting:
            return glass.controlStroke.opacity(isDark ? 0.72 : 0.50)
        }
    }
}

private struct PreviewFooterRail: View {
    let entries: [PreviewPane.PreviewRailEntry]
    let glass: ClipinGlassPalette
    let hierarchy: ClipinPanelHierarchy
    let colorScheme: ColorScheme

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(entries) { entry in
                    PreviewValueBadge(
                        item: entry.item,
                        prominence: entry.prominence,
                        glass: glass,
                        hierarchy: hierarchy,
                        colorScheme: colorScheme
                    )
                }
            }
            .padding(.horizontal, 1)
            .padding(.top, 10)
            .padding(.bottom, 1)
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(glass.controlStroke.opacity(colorScheme == .dark ? 0.36 : 0.22))
                .frame(height: 0.6)
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
