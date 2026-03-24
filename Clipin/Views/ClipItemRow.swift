import SwiftUI

/// 列表中的单行剪贴板项
struct ClipItemRow: View {
    let item: ClipItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            // 类型图标
            typeIcon
                .frame(width: 24, height: 24)
                .foregroundStyle(isSelected ? .white : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(displayText)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? .white : .primary)

                if let sourceName = item.sourceName {
                    Text(sourceName)
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? .white.opacity(0.7) : .secondary)
                }
            }

            Spacer()

            if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(isSelected ? .white : .orange)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private var typeIcon: some View {
        switch item.clipType {
        case .text:
            Image(systemName: "doc.text")
        case .image:
            Image(systemName: "photo")
        case .file:
            Image(systemName: "folder")
        case .url:
            Image(systemName: "link")
        }
    }

    private var displayText: String {
        switch item.clipType {
        case .text, .url:
            return item.content.isEmpty ? "(empty)" : item.content
        case .image:
            return "Image"
        case .file:
            let url = URL(fileURLWithPath: item.content)
            return url.lastPathComponent
        }
    }
}
