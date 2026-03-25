import SwiftUI
import AppKit

/// 右侧预览面板
struct PreviewPane: View {
    let item: ClipItem?

    var body: some View {
        Group {
            if let item {
                VStack(spacing: 0) {
                    header(for: item)
                    Divider()
                    content(for: item)
                    Divider()
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
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func header(for item: ClipItem) -> some View {
        HStack(spacing: 10) {
            Label(typeLabel(item.clipType), systemImage: headerIconName(for: item.clipType))
                .font(.system(size: 13, weight: .semibold))

            if item.isPinned {
                Label("Pinned", systemImage: "pin.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(relativeDate(item.createdAt))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private func content(for item: ClipItem) -> some View {
        switch item.clipType {
        case .text:
            SelectableTextPreview(
                text: item.content,
                font: .monospacedSystemFont(ofSize: 13, weight: .regular)
            )
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

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
                    font: .monospacedSystemFont(ofSize: 12, weight: .regular)
                )
            }
            .padding(20)
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
            .padding(20)
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
                    font: .monospacedSystemFont(ofSize: 12, weight: .regular)
                )
                .frame(minHeight: 80)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func infoSection(for item: ClipItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Information")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            infoRow("Source", value: item.sourceName ?? "Unknown", icon: sourceAppIcon(for: item))
            infoRow("Type", value: typeLabel(item.clipType))
            if item.clipType == .text || item.clipType == .url {
                infoRow("Characters", value: "\(item.charCount)")
            }
            if item.copyCount > 1 {
                infoRow("Times copied", value: "\(item.copyCount)")
            }
            if item.firstCopiedAt != item.createdAt {
                infoRow("First copied", value: absoluteDate(item.firstCopiedAt))
            }
            infoRow("Last copied", value: absoluteDate(item.createdAt))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
    }

    private func infoRow(_ label: String, value: String, icon: NSImage? = nil) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 16, height: 16)
            }
            Text(value)
                .font(.system(size: 12))
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

    private func absoluteDate(_ timestamp: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000.0)
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }

    private func relativeDate(_ timestamp: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000.0)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: .now)
    }

    private func headerIconName(for type: ClipType) -> String {
        switch type {
        case .text: return "doc.text"
        case .image: return "photo"
        case .file: return "folder"
        case .url: return "link"
        }
    }
}

private struct SelectableTextPreview: NSViewRepresentable {
    let text: String
    let font: NSFont

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
        textView.isRichText = false
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
        textView.font = font

        if textView.string != text {
            textView.string = text
            textView.setSelectedRange(NSRange(location: 0, length: 0))
        }
    }
}
