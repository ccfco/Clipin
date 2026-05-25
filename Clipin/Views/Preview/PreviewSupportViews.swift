import AppKit
import SwiftUI

struct PreviewValueBadge: View {
    let item: PreviewPane.PreviewBadgeItem

    var body: some View {
        HStack(spacing: ClipinChrome.gap) {
            if let systemImage = item.systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
            } else if let icon = item.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 11, height: 11)
            }

            Text(item.title)
                .font(.system(size: ClipinChrome.previewBadgeFontSize, weight: .medium, design: .rounded))
                .lineLimit(1)
                .textSelection(.enabled)
        }
        .fixedSize(horizontal: true, vertical: false)
        .foregroundStyle(ClipinInk.secondary)
        .padding(.horizontal, ClipinChrome.gap)
        .padding(.vertical, ClipinChrome.gap)
        // 元数据徽章是内容区 chip,不上玻璃(玻璃叠窗面会二次发白):用与 ClipinKeycap
        // 同值的扁平半透明填充,Color.primary.opacity 明暗自适应、无需 colorScheme 分支。
        .background(
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .help(item.helpText ?? item.title)
    }
}

struct PreviewFooterRail: View {
    let entries: [PreviewPane.PreviewRailEntry]

    var body: some View {
        // 外层 previewFooter 已 .padding(.top, ClipinChrome.gap)，rail 内部不再重复加 top；
        // .horizontal/.bottom 1pt 是历史防 clip 残留（glass capsule 现已自带 padding），删除。
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: ClipinChrome.gap) {
                ForEach(entries) { entry in
                    PreviewValueBadge(item: entry.item)
                }
            }
        }
    }
}

