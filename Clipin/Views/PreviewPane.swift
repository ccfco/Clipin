import SwiftUI

/// 右侧预览面板
struct PreviewPane: View {
    let item: ClipItem?

    var body: some View {
        if let item {
            VStack(alignment: .leading, spacing: 0) {
                // 内容预览
                ScrollView {
                    contentPreview(for: item)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }

                Divider()

                // 元信息
                infoSection(for: item)
                    .padding(12)
            }
        } else {
            VStack {
                Image(systemName: "clipboard")
                    .font(.system(size: 40))
                    .foregroundStyle(.tertiary)
                Text("Select an item to preview")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func contentPreview(for item: ClipItem) -> some View {
        switch item.clipType {
        case .text:
            Text(item.content)
                .font(.system(size: 13, design: .monospaced))
                .textSelection(.enabled)

        case .url:
            VStack(alignment: .leading, spacing: 8) {
                Link(item.content, destination: URL(string: item.content) ?? URL(string: "about:blank")!)
                    .font(.system(size: 13))
                Text(item.content)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

        case .image:
            if let path = item.imagePath, let image = NSImage(contentsOfFile: path) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Label("Image not found", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }

        case .file:
            VStack(alignment: .leading, spacing: 8) {
                let url = URL(fileURLWithPath: item.content)
                HStack(spacing: 8) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: item.content))
                        .resizable()
                        .frame(width: 48, height: 48)

                    VStack(alignment: .leading) {
                        Text(url.lastPathComponent)
                            .font(.system(size: 14, weight: .medium))
                        Text(url.deletingLastPathComponent().path)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func infoSection(for item: ClipItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Information")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            infoRow("Source", value: item.sourceName ?? "Unknown", icon: sourceAppIcon(for: item))
            infoRow("Content type", value: typeLabel(item.clipType))
            if item.clipType == .text || item.clipType == .url {
                infoRow("Characters", value: "\(item.charCount)")
            }
            infoRow("Copied", value: formatDate(item.createdAt))
        }
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
        }
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
        case .url: return "URL"
        }
    }

    private func formatDate(_ timestamp: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000.0)
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}
