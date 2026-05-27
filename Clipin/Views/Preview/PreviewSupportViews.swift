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

/// 滚动内容 + 渐隐遮罩 + 元数据底栏的共享容器。
/// 所有需要 "可滚动正文 + 底栏徽章" 的 preview body(image / file / url)统一用它,
/// 把"是否在滚动""底部渐隐多高""与底栏间距"等渲染细节单点收口。
///
/// 心智:外面只关心"给我一坨可滚动的内容 + footer 数据",fade/spacing 都由容器决定。
/// 旧实现 ImagePreviewBody 内联 VStack + mask,FilePreviewBody/URLPreviewView 走外层
/// safeAreaInset,导致仅图片有渐隐,其它没有——与"统一视觉语言"决策违背。
struct PreviewFadeFooterContainer<Content: View>: View {
    let footerEntries: [PreviewPane.PreviewRailEntry]
    @ViewBuilder var content: () -> Content

    /// 内容自然高度 vs 滚动视口高度的对比驱动"是否真正在滚动"——
    /// 内容刚好放下时保持全黑遮罩,不会无谓淡掉末行。
    @State private var contentHeight: CGFloat = 0
    @State private var scrollViewHeight: CGFloat = 0

    /// 底部渐隐段高度。32pt 对应正文 ~2 行,既能明显标记"下方还有内容",又不大到吃掉信息。
    /// computed 而非 static let:Swift 不允许 generic struct 持有 static stored property。
    /// 不下沉到 ClipinChrome:渲染微调档位,与"间距/圆角"网格不同源。
    private var fadeHeight: CGFloat { 32 }  // spacing-exempt: 渐隐遮罩段高度,纯渲染微调

    private var isScrolling: Bool { contentHeight > scrollViewHeight + 1 }

    var body: some View {
        VStack(spacing: ClipinChrome.gap) {
            ScrollView {
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .frame(maxHeight: contentHeight > 0 ? contentHeight : nil)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { scrollViewHeight = $0 }
            .mask(fadeMask)

            PreviewFooterRail(entries: footerEntries)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var fadeMask: some View {
        VStack(spacing: 0) {
            Color.black
            LinearGradient(
                colors: isScrolling
                    ? [Color.black, Color.black.opacity(0)]
                    : [Color.black, Color.black],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: fadeHeight)
        }
    }
}

