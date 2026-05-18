import Foundation
import SwiftUI

enum VisualTheme: String, CaseIterable {
    case native = "native"
    case mist = "mist"
    case graphite = "graphite"
    case sunrise = "sunrise"

    var displayName: String {
        switch self {
        case .native:
            return NSLocalizedString("Native", comment: "")
        case .mist:
            return NSLocalizedString("Mist", comment: "")
        case .graphite:
            return NSLocalizedString("Graphite", comment: "")
        case .sunrise:
            return NSLocalizedString("Sunrise", comment: "")
        }
    }
}

enum ClipinChrome {
    // 圆角层级：shell 24 → section 16 → contentStage/field 14 → metadata 12 → row 12 → badge 10/7
    static let shellCornerRadius: CGFloat = 24
    static let sectionCornerRadius: CGFloat = 16
    static let cardCornerRadius: CGFloat = 18
    static let searchCornerRadius: CGFloat = 14
    static let rowCornerRadius: CGFloat = 12
    static let paletteCornerRadius: CGFloat = 26
    static let primaryBadgeCornerRadius: CGFloat = 14
    static let badgeCornerRadius: CGFloat = 10
    // 全局间距节奏：所有 shell→section / section→section / section 垂直节奏统一用 shellGap
    static let shellGap: CGFloat = 8
    static let listRowOuterInset: CGFloat = 8
    static let detailContentInset: CGFloat = 12
    static let detailObjectInset: CGFloat = 0
    static let detailStageInset: CGFloat = 12
    static let detailMetadataInset: CGFloat = 12
    static let detailGroupSpacing: CGFloat = 8
    static let detailStageCornerRadius: CGFloat = 14
    static let detailMetadataCornerRadius: CGFloat = 12
    static let detailMediaCornerRadius: CGFloat = 14
    static let footerMinHeight: CGFloat = 44
    /// 底栏命令胶囊/来源面包屑的圆角:实测对齐 Raycast——是「圆角矩形」(~12pt)而非整颗药丸。
    /// 用户原话:那个按钮的弧度是「个角的弧度」。所有 footer glass chip 共用此度量。
    static let footerChipCornerRadius: CGFloat = 12
    /// 悬浮液态玻璃底栏「外接带」高度(玻璃元件高 + 与窗口边间距)。
    /// 列表 scroll 底部 inset 与预览卡 bottom margin 共用此单一度量,防两处各算漂移。规格单元 B。
    static let floatingFooterBand: CGFloat = 56
    static let footerContentInset: CGFloat = 6
    static let footerCalloutVerticalInset: CGFloat = 4
    static let footerCalloutHorizontalLeading: CGFloat = 10
    static let footerCalloutHorizontalTrailing: CGFloat = 10
    static let footerCalloutIconSize: CGFloat = 20
    static let heroOrbCornerRadius: CGFloat = 20
    static let sectionIntroSpacing: CGFloat = 10
}

enum ClipinMotion {
    static let reduced = Animation.easeOut(duration: 0.16)
    static let feedback = Animation.spring(response: 0.22, dampingFraction: 0.82)
    static let focusShift = Animation.spring(response: 0.28, dampingFraction: 0.86)
    static let selection = Animation.spring(response: 0.26, dampingFraction: 0.84)
    static let commandReveal = Animation.spring(response: 0.34, dampingFraction: 0.88)
    static let statePulse = Animation.spring(response: 0.42, dampingFraction: 0.82)
    static let ambient = Animation.easeInOut(duration: 7.6)
    static let panel = commandReveal
}

/// 主面板共享状态语法。把“正在搜索 / 打开命令面板 / 连续粘贴”等状态
/// 收口成统一场景描述，避免各个子视图各自猜自己的强调程度。
struct ClipinSceneState: Equatable {
    let hasSelection: Bool
    let isSearching: Bool
    let isFiltered: Bool
    let isShowingActions: Bool
    let isContinuousPasteEnabled: Bool

    var hasActiveQuery: Bool { isSearching || isFiltered }
    var ambientStrength: Double {
        if isShowingActions { return 1.0 }
        if isContinuousPasteEnabled { return 0.92 }
        if hasActiveQuery { return 0.74 }
        return 0.58
    }

    var headerAccentOpacity: Double {
        if isShowingActions { return 0.68 }
        if hasActiveQuery { return 0.54 }
        return 0.18
    }

    var headerGlowOpacity: Double {
        if isShowingActions { return 0.18 }
        if hasActiveQuery { return 0.14 }
        return 0.06
    }

    var headerLift: CGFloat {
        hasActiveQuery ? -0.5 : 0
    }

    var listRestingOpacity: Double {
        isShowingActions ? 0.965 : 1.0
    }

    var selectedRowScale: CGFloat {
        if isShowingActions { return 0.996 }
        if isContinuousPasteEnabled { return 1.008 }
        return 1.0
    }

    var selectedRowLift: CGFloat {
        if isContinuousPasteEnabled { return -0.5 }
        if isShowingActions { return -0.25 }
        return 0
    }

    var selectedRowIconEmphasis: CGFloat {
        if isContinuousPasteEnabled { return 1.08 }
        if isShowingActions { return 1.04 }
        return 1.0
    }

    var previewScale: CGFloat {
        isShowingActions ? 0.998 : 1.0
    }

    var previewLift: CGFloat {
        isShowingActions ? -1.0 : 0
    }

    var metadataOpacity: Double {
        hasSelection ? (isShowingActions ? 0.88 : 1.0) : 0.74
    }

    var metadataLift: CGFloat {
        isShowingActions ? -1.5 : 0
    }

    var stripScale: CGFloat {
        isShowingActions ? 0.997 : 1.0
    }

    var paletteScale: CGFloat { isShowingActions ? 1.0 : 0.985 }
    var paletteLift: CGFloat { isShowingActions ? 0 : 6 }

    static let idle = ClipinSceneState(
        hasSelection: false,
        isSearching: false,
        isFiltered: false,
        isShowingActions: false,
        isContinuousPasteEnabled: false
    )
}

struct ClipinKeycap: View {
    let key: String
    let foreground: Color

    var body: some View {
        // Raycast 式扁平键帽:低调中性圆角块,不上玻璃(窗面已是 Liquid Glass,
        // 键帽再上玻璃就成玻璃叠玻璃)。
        Text(key)
            .font(.system(size: 10.5, weight: .medium, design: .rounded))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 5)
            .padding(.vertical, 2.5)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
    }
}

struct ClipinSymbolOrb: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isFloating = false

    let systemImage: String
    var size: CGFloat = 64
    var iconSize: CGFloat = 22
    var emphasis: Double = 1.0

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: ClipinChrome.heroOrbCornerRadius, style: .continuous)
                .fill(Color.accentColor.opacity(0.10 + (0.05 * emphasis)))
                .frame(width: size + 14, height: size + 14)
                .blur(radius: 18)
                .scaleEffect(reduceMotion ? 1 : (isFloating ? 1.04 : 0.98))

            RoundedRectangle(cornerRadius: ClipinChrome.heroOrbCornerRadius, style: .continuous)
                .fill(Color.clear)
                .frame(width: size, height: size)
                .clipinChromeGlass(in: RoundedRectangle(cornerRadius: ClipinChrome.heroOrbCornerRadius, style: .continuous))
                .scaleEffect(reduceMotion ? 1 : (isFloating ? 1.01 : 0.99))

            Image(systemName: systemImage)
                .font(.system(size: iconSize, weight: .medium))
                .foregroundStyle(Color.accentColor)
        }
        .onAppear {
            guard !reduceMotion else { return }
            isFloating = false
            withAnimation(ClipinMotion.ambient.repeatForever(autoreverses: true)) {
                isFloating = true
            }
        }
    }
}

struct ClipinSectionIntro: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    var eyebrow: LocalizedStringKey? = nil
    var titleFontSize: CGFloat = 24
    var subtitleFontSize: CGFloat = 13

    var body: some View {
        VStack(alignment: .leading, spacing: ClipinChrome.sectionIntroSpacing) {
            if let eyebrow {
                Text(eyebrow)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(ClipinInk.secondary)
                    .tracking(0.45)
            }

            Text(title)
                .font(.system(size: titleFontSize, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)

            Text(subtitle)
                .font(.system(size: subtitleFontSize))
                .foregroundStyle(ClipinInk.secondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 所有列表型界面的选中/悬停底板,主列表、动作面板、设置侧栏共用。
/// 减法重构:选中=单一中性填充(无 rail/无描边);pinned 仍用左侧中性细 rail 表达常驻 pin 状态。
struct ClipinSelectableRowBackground: View {
    let isSelected: Bool
    let isHovered: Bool
    let selectionFill: Color
    let selectionStroke: Color
    let hoverFill: Color
    let hoverStroke: Color
    var isPinned: Bool = false

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: ClipinChrome.rowCornerRadius, style: .continuous)
                .fill(
                    isSelected
                        ? selectionFill
                        : isHovered
                            ? hoverFill
                            : Color.clear
                )

            // pinned 态 rail:2pt 中性细条(非选中时表达常驻 pin 状态)。
            // 选中态不再画 rail/描边,仅靠中性填充区分。
            if isPinned && !isSelected {
                Capsule(style: .continuous)
                    .fill(selectionStroke.opacity(0.45))
                    .frame(width: 2)
                    .padding(.vertical, 11)
                    .padding(.leading, 7.5)
            }
        }
    }
}

// MARK: - Liquid Glass (macOS 26 原生)

/// 唯一玻璃缝:chrome 才用玻璃,内容区永不调用。
/// 首版单 native 无 tint —— 不接 tint 参数,杜绝"主题兜底"。
extension View {
    /// Requires macOS 26+ (deployment target enforced in project.yml).
    /// 窗口附着的 chrome 玻璃(搜索栏/底栏/动作面板/胶囊/orb)。
    func clipinChromeGlass(in shape: some Shape) -> some View {
        glassEffect(.regular, in: shape)
    }

    /// 圆角矩形 chrome 玻璃的便捷写法。
    func clipinChromeGlass(cornerRadius: CGFloat) -> some View {
        glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// 底栏命令按钮样式 = macOS 26 标准 Liquid Glass 按钮(ChatGPT 等同款)。
/// 配方三件套,缺一就翻车:
/// ① 先内边距给 chip「身体」——glass 只在当前 bounds 内渲染,label 不留 padding
///    时 bounds≈文字紧贴框,玻璃缩成一条发丝、看着像没有(之前反复翻车的真因)。
/// ② `.regular.interactive()` 原生交互玻璃——鼠标悬停给那层灰色高亮(露出单个按钮
///    轮廓)、按下给原生 press,无需手搓 hover/scale。
/// ③ `Capsule` 胶囊形——配合外层 GlassEffectContainer 把相邻胶囊「融合」成一条
///    连续液态玻璃,四周一圈共享 rim(用户要的「椭圆形、一圈玻璃边」)。
/// 不是 `.glassProminent`(不透明)、不是手搓扁平条。
struct ClipinFooterGlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .glassEffect(.regular.interactive(), in: Capsule(style: .continuous))
    }
}

/// 内容区实色中性面(列表区/预览 contentStage/metadata):
/// 显式不上玻璃,文字坐其上保持清晰。可选 shadow 表达"浮起"。
struct ClipinContentSurface: View {
    let cornerRadius: CGFloat
    let elevated: Bool

    init(cornerRadius: CGFloat, elevated: Bool = false) {
        self.cornerRadius = cornerRadius
        self.elevated = elevated
    }

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor))
            .shadow(
                color: elevated ? .black.opacity(0.10) : .clear,
                radius: elevated ? 12 : 0,
                y: elevated ? 4 : 0
            )
    }
}

/// 文字层级语义色,统一命名以便日后整体替换/分流(如 accent 化)。
/// primary/secondary 是 SwiftUI 语义色别名,tertiary/quaternary 桥接 NSColor
/// (SwiftUI 未原生暴露)。统一走 ClipinInk 让 search-replace 有单一抓手。
enum ClipinInk {
    static let primary = Color.primary
    static let secondary = Color.secondary
    static let tertiary = Color(nsColor: .tertiaryLabelColor)
    static let quaternary = Color(nsColor: .quaternaryLabelColor)
}

/// 选中态语义色:列表/动作面板/侧栏共用,改一处调全局。
/// 减法重构后全部中性化(规格单元 A/E:accent 仅余 Paste 主键帽)。
enum ClipinSelectionInk {
    static let fill = Color.primary.opacity(0.07)          // 选中填充,明确强于 hover
    static let stroke = Color.primary.opacity(0.28)        // 仅余 pinned rail 用(中性)
    static let dim = Color.secondary                        // 选中态次要文字/⌘N,中性
    static let highlight = Color.accentColor.opacity(0.20)  // 仅搜索命中高亮保留极淡 accent
}

/// 悬停态语义色:与选中态同一套抓手,明确弱于选中。
enum ClipinHoverInk {
    static let fill = Color.primary.opacity(0.035)
    static let stroke = Color.clear
}

/// iOS/macOS 26 同心圆角形状(已对 Xcode 26.5 / macOS SDK 26 编译核验,Task 1)。
/// curvature 随最近 `.containerShape(...)` 自动推导,不硬编码圆角魔数 ——
/// 这是 iOS 26 原生做法,实测 API 是 `ConcentricRectangle` 形状(非
/// `RoundedRectangle(cornerRadius: .containerConcentric)`)。
/// 用法:玻璃容器根部 `.containerShape(RoundedRectangle(cornerRadius: shell, style: .continuous))`,
/// 内部子形状/选中底板用 `ClipinConcentric()`,改 shell 一处全联动。
typealias ClipinConcentric = ConcentricRectangle
