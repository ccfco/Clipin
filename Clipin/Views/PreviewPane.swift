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
                VStack(alignment: .leading, spacing: ClipinChrome.detailGroupSpacing) {
                    contentStage(for: item)

                    metadataSection(for: item)
                }
                .padding(ClipinChrome.detailContentInset)
            } else {
                contentStage {
                    placeholder(
                        icon: "doc.text.magnifyingglass",
                        title: "Select an item",
                        subtitle: "Choose a clipboard item from the list to inspect it here."
                    )
                }
                .padding(ClipinChrome.detailContentInset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func contentStage(for item: ClipItem) -> some View {
        contentStage {
            content(for: item)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func contentStage<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(ClipinChrome.detailStageInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                ClipinSurfaceBackground(
                    role: .contentStage,
                    cornerRadius: ClipinChrome.detailStageCornerRadius,
                    glass: glass
                )
            )
            .padding(.horizontal, ClipinChrome.detailObjectInset)
    }

    @ViewBuilder
    private func content(for item: ClipItem) -> some View {
        switch item.clipType {
        case .text:
            if let color = detectHexColor(in: item.content) {
                ColorSwatchPreview(color: color, originalText: item.content)
                    .frame(maxWidth: 460, alignment: .leading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                TextPreviewBody(
                    text: item.content,
                    font: previewTextFont(),
                    searchQuery: searchQuery
                )
                .environmentObject(vm)
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

        case .image:
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let path = item.imagePath, let image = NSImage(contentsOfFile: path) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: 392)
                            .clipShape(RoundedRectangle(cornerRadius: ClipinChrome.detailMediaCornerRadius, style: .continuous))
                            .shadow(color: .black.opacity(0.06), radius: 8, y: 3)
                    } else {
                        unavailableLabel("Image not found", systemImage: "exclamationmark.triangle")
                    }

                    // OCR 识别文字区域（有结果时展示，可选中复制，支持搜索高亮）
                    if let ocr = item.ocrText, !ocr.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("OCR", systemImage: "text.viewfinder")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)

                            SelectableTextPreview(
                                text: ocr,
                                font: .systemFont(ofSize: 13, weight: .regular),
                                searchQuery: searchQuery,
                                vm: vm
                            )
                            .frame(minHeight: 60, maxHeight: 200)
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
                        .frame(maxWidth: .infinity, maxHeight: 360)
                        .clipShape(RoundedRectangle(cornerRadius: ClipinChrome.detailMediaCornerRadius, style: .continuous))
                        .shadow(color: .black.opacity(0.06), radius: 8, y: 3)
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
        }
    }

    private func metadataSection(for item: ClipItem) -> some View {
        infoGrid(for: item)
            .padding(ClipinChrome.detailMetadataInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                ClipinSurfaceBackground(
                    role: .metadata,
                    cornerRadius: ClipinChrome.detailMetadataCornerRadius,
                    glass: glass
                )
            )
            .padding(.horizontal, ClipinChrome.detailObjectInset)
    }

    private func infoGrid(for item: ClipItem) -> some View {
        LazyVGrid(columns: infoGridColumns, alignment: .leading, spacing: 6) {
            ForEach(infoItems(for: item)) { item in
                infoRow(item)
            }
        }
    }

    private var infoGridColumns: [GridItem] {
        [
            GridItem(.flexible(minimum: 210), spacing: 14, alignment: .leading),
            GridItem(.flexible(minimum: 210), spacing: 14, alignment: .leading)
        ]
    }

    private func infoItems(for item: ClipItem) -> [InfoItem] {
        var items: [InfoItem] = []

        items.append(
            InfoItem(
                id: "source",
                label: "Source",
                value: item.sourceName ?? NSLocalizedString("Unknown", comment: ""),
                icon: sourceAppIcon(for: item)
            )
        )
        items.append(InfoItem(id: "type", label: "Type", value: typeLabel(item.clipType)))

        if item.isPinned {
            items.append(InfoItem(id: "status", label: "Status", value: NSLocalizedString("Pinned", comment: "")))
        }

        if item.clipType == .image, let path = item.imagePath {
            if let image = NSImage(contentsOfFile: path),
               let rep = image.representations.first {
                let w = rep.pixelsWide > 0 ? rep.pixelsWide : Int(image.size.width)
                let h = rep.pixelsHigh > 0 ? rep.pixelsHigh : Int(image.size.height)
                items.append(InfoItem(id: "dimensions", label: "Dimensions", value: "\(w) × \(h)"))
            }
            if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
               let bytes = attrs[.size] as? Int64 {
                items.append(
                    InfoItem(
                        id: "file_size",
                        label: "File size",
                        value: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
                    )
                )
            }
        }

        if item.clipType == .file {
            let paths = FileClipboardContent.paths(from: item.content)
            if paths.count > 1 {
                items.append(InfoItem(id: "items", label: "Items", value: "\(paths.count)"))
            }
            if let path = paths.first, paths.count == 1, isImageFile(path) {
                if let image = NSImage(contentsOfFile: path),
                   let rep = image.representations.first {
                    let w = rep.pixelsWide > 0 ? rep.pixelsWide : Int(image.size.width)
                    let h = rep.pixelsHigh > 0 ? rep.pixelsHigh : Int(image.size.height)
                    items.append(InfoItem(id: "dimensions", label: "Dimensions", value: "\(w) × \(h)"))
                }
                if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                   let bytes = attrs[.size] as? Int64 {
                    items.append(
                        InfoItem(
                            id: "file_size",
                            label: "File size",
                            value: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
                        )
                    )
                }
            }
        }

        if item.clipType == .text || item.clipType == .url {
            let words = item.content.split { $0.isWhitespace || $0.isNewline }.count
            items.append(InfoItem(id: "words", label: "Words", value: "\(words)"))
            items.append(InfoItem(id: "characters", label: "Characters", value: "\(item.charCount)"))
        }

        if item.copyCount > 1 {
            items.append(InfoItem(id: "copies", label: "Copies", value: "\(item.copyCount)"))
        }
        items.append(InfoItem(id: "copied", label: "Copied", value: relativeDate(item.createdAt)))

        return items
    }

    private func infoRow(_ item: InfoItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(item.label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(minWidth: 40, idealWidth: 52, maxWidth: 68, alignment: .leading)
                .lineLimit(1)

            HStack(spacing: 4) {
                if let icon = item.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 11, height: 11)
                        .opacity(0.7)
                }

                Text(item.value)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
                    .help(item.value)
            }

            Spacer(minLength: 4)
        }
    }

    private struct InfoItem: Identifiable {
        let id: String
        let label: LocalizedStringKey
        let value: String
        let icon: NSImage?

        init(id: String, label: LocalizedStringKey, value: String, icon: NSImage? = nil) {
            self.id = id
            self.label = label
            self.value = value
            self.icon = icon
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
