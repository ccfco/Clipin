import SwiftUI
import AppKit

/// 右侧预览面板
struct PreviewPane: View {
    let item: ClipItem?
    var searchQuery: String = ""

    var body: some View {
        Group {
            if let item {
                VStack(spacing: 0) {
                    content(for: item)
                    infoSection(for: item)
                }
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
                SelectableTextPreview(
                    text: item.content,
                    font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                    searchQuery: searchQuery
                )
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

        case .url:
            VStack(alignment: .leading, spacing: 14) {
                if let url = URL(string: item.content) {
                    Link(destination: url) {
                        Label(url.absoluteString, systemImage: "safari")
                            .font(.system(size: 13, weight: .medium))
                    }
                }

                SelectableTextPreview(
                    text: item.content,
                    font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                    searchQuery: searchQuery
                )
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

        case .image:
            ScrollView {
                if let path = item.imagePath, let image = NSImage(contentsOfFile: path) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: 360)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else {
                    unavailableLabel("Image not found", systemImage: "exclamationmark.triangle")
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

        case .file:
            VStack(alignment: .leading, spacing: 16) {
                let url = URL(fileURLWithPath: item.content)
                HStack(spacing: 14) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: item.content))
                        .resizable()
                        .frame(width: 56, height: 56)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(url.lastPathComponent)
                            .font(.system(size: 15, weight: .semibold))
                        Text(url.deletingLastPathComponent().path)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                SelectableTextPreview(
                    text: item.content,
                    font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                    searchQuery: searchQuery
                )
                .frame(minHeight: 80)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func infoSection(for item: ClipItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                infoRow("Source", value: item.sourceName ?? "Unknown", icon: sourceAppIcon(for: item))
                infoRow("Type", value: typeLabel(item.clipType))
                if item.clipType == .image, let path = item.imagePath {
                    if let image = NSImage(contentsOfFile: path),
                       let rep = image.representations.first {
                        let w = rep.pixelsWide > 0 ? rep.pixelsWide : Int(image.size.width)
                        let h = rep.pixelsHigh > 0 ? rep.pixelsHigh : Int(image.size.height)
                        infoRow("Dimensions", value: "\(w) × \(h)")
                    }
                    if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                       let bytes = attrs[.size] as? Int64 {
                        infoRow("Size", value: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                    }
                }
                if item.isPinned {
                    infoRow("Status", value: "Pinned")
                }
                if item.clipType == .text || item.clipType == .url {
                    infoRow("Characters", value: "\(item.charCount)")
                    let lines = item.content.components(separatedBy: .newlines).count
                    infoRow("Lines", value: "\(lines)")
                    let words = item.content.split { $0.isWhitespace || $0.isNewline }.count
                    infoRow("Words", value: "\(words)")
                }
                if item.copyCount > 1 {
                    infoRow("Times copied", value: "\(item.copyCount)")
                }
                if item.firstCopiedAt != item.createdAt {
                    infoRow("First copied", value: Self.absoluteDateString(item.firstCopiedAt))
                }
                infoRow("Copied", value: relativeDate(item.createdAt))
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 170)
        .background(Color.primary.opacity(0.04))
    }

    private func infoRow(_ label: String, value: String, icon: NSImage? = nil) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer()
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 13, height: 13)
            }
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private func placeholder(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 14, weight: .medium))
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func unavailableLabel(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sourceAppIcon(for item: ClipItem) -> NSImage? {
        guard let bundleId = item.sourceApp else { return nil }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private func typeLabel(_ type: ClipType) -> String {
        switch type {
        case .text: return "Text"
        case .image: return "Image"
        case .file: return "File"
        case .url: return "Link"
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

}

private struct ColorSwatchPreview: View {
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
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(color)
                RoundedRectangle(cornerRadius: 16, style: .continuous)
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

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        let textColor = NSColor.labelColor
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 4
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

        // 只在内容或高亮变化时更新，避免不必要的重绘
        if textView.attributedString() != attributed {
            textView.textStorage?.setAttributedString(attributed)
            textView.setSelectedRange(NSRange(location: 0, length: 0))
        }
    }
}
