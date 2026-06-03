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

/// 底部渐隐遮罩。供 `.mask()` 复用——image/file/url 走 `PreviewFadeFooterContainer`,
/// text 路径(SelectableTextPreview 内嵌 NSScrollView 无法包外层 ScrollView)直接挂本 mask,
/// 视觉语言一致。`isScrolling` 决定下方 32pt 是渐隐(true)还是全黑等价无遮罩(false)。
struct PreviewBottomFadeMask: View {
    let isScrolling: Bool

    /// 渐隐段高度。32pt 对应正文 ~2 行,既能明显标记"下方还有内容",又不大到吃掉信息。
    /// 不下沉到 ClipinChrome:渲染微调档位,与"间距/圆角"网格不同源。
    private static let fadeHeight: CGFloat = 32  // spacing-exempt: 渐隐遮罩段高度,纯渲染微调

    var body: some View {
        VStack(spacing: 0) {
            Color.black
            LinearGradient(
                colors: isScrolling
                    ? [Color.black, Color.black.opacity(0)]
                    : [Color.black, Color.black],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: Self.fadeHeight)
        }
    }
}

/// 滚动内容 + 渐隐遮罩 + 元数据底栏的共享容器。
/// 所有 preview body(image / file / url / text)统一走它,把"是否在滚动""底部渐隐多高"
/// "与底栏间距"等渲染细节单点收口。
///
/// 心智:外面只关心"给我一坨内容 + footer 数据",fade/spacing 都由容器决定。
/// `scrollStrategy` 决定滚动归属:
/// - `.managed`(默认):内容是普通 SwiftUI view,容器自带 ScrollView 包裹 + 高度追踪 +
///   按内容溢出动态切 fade(image / file / url 路径)
/// - `.external`:内容自管滚动(如 NSScrollView / SelectableTextPreview),容器只负责
///   fade mask + 底栏布局,fade 写死 true——内容不溢出时 mask 覆盖空白区视觉无差异(text 路径)
struct PreviewFadeFooterContainer<Content: View>: View {
    enum ScrollStrategy {
        case managed   // 容器自带 ScrollView
        case external  // 内容自管滚动
    }

    let footerEntries: [PreviewPane.PreviewRailEntry]
    let scrollStrategy: ScrollStrategy
    @ViewBuilder var content: () -> Content

    init(
        footerEntries: [PreviewPane.PreviewRailEntry],
        scrollStrategy: ScrollStrategy = .managed,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.footerEntries = footerEntries
        self.scrollStrategy = scrollStrategy
        self.content = content
    }

    /// 内容自然高度 vs 滚动视口高度的对比驱动"是否真正在滚动"——
    /// 内容刚好放下时保持全黑遮罩,不会无谓淡掉末行。仅 `.managed` 模式生效。
    @State private var contentHeight: CGFloat = 0
    @State private var scrollViewHeight: CGFloat = 0

    private var isScrolling: Bool {
        switch scrollStrategy {
        case .managed:  return contentHeight > scrollViewHeight + 1
        case .external: return true  // 自管模式拿不到内容/视口对比,默认假定有滚动需求
        }
    }

    var body: some View {
        VStack(spacing: ClipinChrome.gap) {
            switch scrollStrategy {
            case .managed:
                ScrollView {
                    content()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                }
                .frame(maxHeight: contentHeight > 0 ? contentHeight : nil)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { scrollViewHeight = $0 }
                .mask(PreviewBottomFadeMask(isScrolling: isScrolling))
            case .external:
                // 内容自管 ScrollView(text 的 SelectableTextPreview),容器不再叠一层
                // ScrollView 包裹——避免双层滚动。仍套 fade mask 维持视觉一致。
                content()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .mask(PreviewBottomFadeMask(isScrolling: isScrolling))
            }

            // 短内容时把 metadata 脚注顶到底、紧贴底栏命令胶囊上方,而非紧跟矮内容浮在中上部——后者
            // 会让脚注离命令很远、上下不对称。Spacer 吸收内容与脚注间的空高;内容满屏时收为 0、脚注自然落底。
            Spacer(minLength: 0)
            PreviewFooterRail(entries: footerEntries)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

extension View {
    /// 预览区图片大图的统一圆角收口（cornerControl 单点可改）——图片预览、URL 圆角卡、URL 占位骨架
    /// 都走它，杜绝各 preview body 各写 clipShape 漏裁或取值分叉；与列表行小缩略图的方角刻意区分。
    ///
    /// 注意：clipShape 只裁「视图框」。图片填满框（.fill）时圆角才落在图片真实边缘；.fit 完整图填不满框、
    /// 四角是空白、圆角裁在空白上、图片本身仍方角——「图片本身圆角」与「完整不裁」二选一，由调用方按场景定。
    func previewHeroClip() -> some View {
        clipShape(RoundedRectangle(cornerRadius: ClipinChrome.cornerControl, style: .continuous))
    }
}

