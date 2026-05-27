import Foundation
import SwiftUI

/// QA 视觉自检钩子(显式 opt-in,默认全 false → 行为零变化,非静默兜底 CLAUDE.md #7)。
/// 用途:让自截图验收环路不依赖全局热键 / TCC Accessibility / 状态栏管理器,
/// 也能用合成鼠标驱动真 hover——ad-hoc 重构建会丢 TCC 授权使热键失效。
enum QAFlags {
    private static func on(_ key: String) -> Bool {
        ProcessInfo.processInfo.environment[key] == "1"
    }

    /// 启动即显主面板,不依赖全局热键 / 状态栏。
    static var showPanelOnLaunch: Bool { on("CLIPIN_QA_SHOW_PANEL") }
    /// 启动即打开 ⌘K 动作面板(自截图验收动作面板视觉,免去合成键盘发 ⌘K)。
    static var showActionsOnLaunch: Bool { on("CLIPIN_QA_SHOW_ACTIONS") }
    /// 去掉 .nonactivatingPanel 并跳过失焦自关,让合成鼠标能触发真 hover。
    static var hoverablePanel: Bool { on("CLIPIN_QA_HOVERABLE") }
    /// 强制常显派生簇(合成鼠标对 nonactivating panel 的 .onHover 不可靠)。
    static var alwaysShowDerivedPills: Bool { on("CLIPIN_QA_SHOW_PILLS") }
    /// 强制底栏分段 hover 高亮态(同上:合成 hover run-to-run 不稳,
    /// 用此确定性自截图核对效果②内缩高亮的视觉/明暗;真机真鼠标走标准 .onHover)。
    static var forceSegmentHover: Bool { on("CLIPIN_QA_FORCE_HOVER") }
}

enum ClipinChrome {
    /// 全 app 唯一间距 / 圆角基准单位。改这一个数，整个 app 的间距与圆角等比缩放。
    /// 设计规则见 CLAUDE.md「统一间距系统」决策：所有间距与圆角都是 edge 的整数倍，
    /// 不允许任何组件再硬编码独立的 padding / cornerRadius 字面量。
    static let edge: CGFloat = 8

    // MARK: 间距（两档，均为 edge 的整数倍）

    /// 标准间隔：文字↔选中底板、选中底板↔容器、容器↔窗口、图标↔文字、两栏之间——
    /// 用户能在界面上指到的「一段间隔」一律是这个值。
    static var gap: CGFloat { edge }
    /// 分组间隔：仅用于「相邻信息块之间」需要看出分界的留白（预览段落、设置分节）。
    static var groupGap: CGFloat { edge * 2 }

    // MARK: 圆角（四档，均为 edge 的整数倍；每向内嵌套一层 −edge，保持同心）

    /// 小图标块、徽标、缩略图占位。
    static var cornerTile: CGFloat { edge }
    /// 行、控件、搜索框、媒体卡。
    static var cornerControl: CGFloat { edge * 2 }
    /// 浮层面板、内容卡片。
    static var cornerSurface: CGFloat { edge * 3 }
    /// 窗口外壳。
    static var cornerShell: CGFloat { edge * 4 }

    // MARK: 非缩放度量（不参与 edge 体系：要么是高度档位，要么是字号）

    /// ⌘K 动作面板内容区最大高度（窗口 540 − 顶部搜索区 − 底边距）。超出则内层 ScrollView 滚动。
    static let paletteMaxHeight: CGFloat = 460
    /// 浮动底栏为列表 / 预览预留的底部避让高度。列表 scroll 底 inset 与预览底 margin 共用此度量。
    static let floatingFooterBand: CGFloat = 52

    // MARK: 组件度量（收口到此处单一可改，但刻意不挂 edge 网格）

    /// 键帽（ClipinKeycap）内距。键帽是排版微元件（单字符才 ~8pt 宽），
    /// 套 6pt 网格会被撑成胖片，故保留紧凑比例；放在此处仍满足「一处可改」。
    static let keycapInsetH: CGFloat = 5
    static let keycapInsetV: CGFloat = 2.5

    /// 底栏按钮 hover 高亮相对玻璃胶囊边的内缩量——高亮比按钮小一圈、露出一圈玻璃 rim。
    /// 纯渲染细节，远小于最小网格单位，不挂 edge。
    static let footerHoverRimInset: CGFloat = 2

    /// 设置页 Picker 宽度三档：短数字 / 中等枚举 / 长枚举。
    /// 不挂 edge 网格——Picker 宽度由内部文本决定，不是设计间距。
    /// 收口在此避免散落 120/160/170/220 等魔数。
    static let pickerNarrow: CGFloat = 120
    static let pickerMedium: CGFloat = 170
    static let pickerWide: CGFloat = 220

    /// 搜索框输入字号。刻意远大于列表行标题（13.5），让输入框读作 launcher 的视觉主角
    /// （Raycast / Spotlight 心智），而非又一行列表项。
    static let searchFieldFontSize: CGFloat = 20

    /// 预览正文（text / OCR / URL full / file path list）字号
    static let previewBodyFontSize: CGFloat = 13.5
    /// 预览 footer 徽章字号；与 ClipinKeycap (10.5) 区分，信息密度更高需更易读。
    static let previewBadgeFontSize: CGFloat = 11
    /// 预览图片最大解码像素（缩略图档位，避免主线程解原图全尺寸）
    static let previewImageMaxPixelSize: Int = 1024
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
    /// ⌘K 动作面板入场：从右下角 ⌘K 按钮缩放展开，带一点生气、不过弹。
    static let paletteReveal = Animation.spring(response: 0.30, dampingFraction: 0.80)
    /// ⌘K 动作面板退场：向右下角快速收回，不回弹、收得干脆。
    static let paletteDismiss = Animation.spring(response: 0.20, dampingFraction: 0.92)
    /// 多文件叠放栈切换动画。Apple `.smooth` 同款曲线(WWDC23 curated),自动适配
    /// reduce motion + ProMotion;显式 duration 0.28s 替代默认 ~0.5s——栈翻动场景
    /// 用户期望"响应即时",0.25–0.32s 是视觉甜点(低于 0.2 突兀,高于 0.35 拖)。
    static let stackSwitch = Animation.smooth(duration: 0.28)
}

/// 主面板共享状态语法。把“正在搜索 / 打开命令面板 / 连续粘贴”等状态
/// 收口成统一场景描述，避免各个子视图各自猜自己的强调程度。
struct ClipinSceneState: Equatable {
    let hasSelection: Bool
    let isSearching: Bool
    let isFiltered: Bool
    let isShowingActions: Bool
    let isContinuousPasteEnabled: Bool

    var headerLift: CGFloat {
        (isSearching || isFiltered) ? -0.5 : 0
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

    var previewLift: CGFloat {
        isShowingActions ? -1.0 : 0
    }

    var metadataOpacity: Double {
        hasSelection ? (isShowingActions ? 0.88 : 1.0) : 0.74
    }

    var metadataLift: CGFloat {
        isShowingActions ? -1.5 : 0
    }

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
            .padding(.horizontal, ClipinChrome.keycapInsetH)
            .padding(.vertical, ClipinChrome.keycapInsetV)
            .background(
                // 键帽 = 圆角方块(cornerTile),与 ⌘1-9 数字徽标 / 筛选 chip / 图标块
                // 共用同一套 RoundedRectangle 圆角语言。不用 Capsule:Capsule 圆角恒为
                // 高度/2,会随键帽宽度变"圆度"(单字符像圆球、组合键像长药丸),反而是
                // 整套统一体系里唯一圆角不统一的元件;固定 cornerTile 才真·统一。
                RoundedRectangle(cornerRadius: ClipinChrome.cornerTile, style: .continuous)
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
            RoundedRectangle(cornerRadius: ClipinChrome.cornerSurface, style: .continuous)
                .fill(Color.accentColor.opacity(0.10 + (0.05 * emphasis)))
                .frame(width: size + 14, height: size + 14)
                .blur(radius: 18)
                .scaleEffect(reduceMotion ? 1 : (isFloating ? 1.04 : 0.98))

            RoundedRectangle(cornerRadius: ClipinChrome.cornerSurface, style: .continuous)
                .fill(Color.clear)
                .frame(width: size, height: size)
                .clipinChromeGlass(in: RoundedRectangle(cornerRadius: ClipinChrome.cornerSurface, style: .continuous))
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
        VStack(alignment: .leading, spacing: ClipinChrome.groupGap) {
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

    private var fillColor: Color {
        if isSelected { return selectionFill }
        if isHovered { return hoverFill }
        return .clear
    }

    /// 选中/hover 底板恒为固定圆角矩形(cornerControl,与行/控件同档)。
    /// 不用 ConcentricRectangle:同心半径 = 容器半径 − 到容器边距离,列表中部的
    /// 行离 shell 边很远 → 半径被算成 ~0 = **尖角**(用户实测 bug)。固定 rounded 才对。
    private var fillShape: some View {
        RoundedRectangle(cornerRadius: ClipinChrome.cornerControl, style: .continuous)
            .fill(fillColor)
    }

    var body: some View {
        ZStack(alignment: .leading) {
            fillShape

            // pinned 态 rail:2pt 中性细条(非选中时表达常驻 pin 状态)。
            // 选中态不再画 rail/描边,仅靠中性填充区分。
            if isPinned && !isSelected {
                Capsule(style: .continuous)
                    .fill(selectionStroke.opacity(0.45))
                    .frame(width: 2)
                    .padding(.vertical, ClipinChrome.edge)
                    .padding(.leading, ClipinChrome.edge)
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
///
/// 与 `ClipinFooterSegmentStyle` 的分工(底栏两套 hover 机制,改底栏前先读):
/// - 本样式 = **独立**胶囊(派生簇 FooterHoverDerivedPills),每颗自带 `.regular.interactive()`
///   原生玻璃 + 系统 hover;
/// - SegmentStyle = **融合**胶囊内的分段(bottomBar 命令簇),整簇共用一块组级玻璃,
///   hover 自绘。二者不可混用:组级玻璃会杀掉 per-button `.interactive()`。
struct ClipinFooterGlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration)
    }

    /// 与 `ClipinFooterSegmentStyle` 视觉语言对齐:hover 都是「内缩灰高亮 capsule +
    /// scale 0.97 press」(memory raycast-footer-reference 写的 Raycast 1:1 三层效果②)。
    /// 实现差别只在玻璃来源:
    /// - SegmentStyle 自身不带玻璃,内缩 capsule 画在 `.background` 上,露出外层组级玻璃
    /// - 本样式自带 `.glassEffect`,内缩 capsule 画在 `.overlay` 上,叠在自身玻璃内部
    /// `.regular.interactive()` 在派生 overlay 场景下系统 hover 不响应(用户实测确认),
    /// 自绘是唯一保证视觉一致的方式。`.interactive()` 仍保留作为压感双保险。
    /// @State 必须在内嵌 View 上,ButtonStyle 不是 View,无法挂状态(踩过)。
    private struct HoverBody: View {
        let configuration: Configuration
        @State private var isHovered = false

        var body: some View {
            let pressed = configuration.isPressed
            let highlighted = isHovered
            return configuration.label
                .padding(.horizontal, ClipinChrome.groupGap)
                .padding(.vertical, ClipinChrome.gap)
                .glassEffect(.regular.interactive(), in: Capsule(style: .continuous))
                .overlay(
                    Capsule(style: .continuous)
                        .fill(Color.primary.opacity(pressed ? 0.16 : (highlighted ? 0.09 : 0)))
                        .padding(ClipinChrome.footerHoverRimInset) // 内缩一圈,露出外层玻璃 capsule 边
                        .allowsHitTesting(false) // 高亮层不抢 Button 的命中
                )
                .scaleEffect(pressed ? 0.97 : 1)
                .contentShape(Capsule(style: .continuous))
                .onHover { hovering in
                    withAnimation(ClipinMotion.feedback) { isHovered = hovering }
                }
                .animation(ClipinMotion.feedback, value: pressed)
        }
    }
}

/// 底栏融合胶囊内的「分段按钮」样式:整簇共用**一块**玻璃 Capsule(连续胶囊=
/// Raycast 效果①),分段本身不再各自上玻璃。hover/press 由本样式**自绘**一个
/// 比按钮小一圈的内缩高亮 + 微缩放(Raycast 效果②:"内部一个比外玻璃小一圈的
/// 灰色形状、按钮像浮起来")。`glassEffectUnion` 会把多颗玻璃并成静态一块、
/// 杀掉 per-button `.interactive()` hover——故改自绘,既得连续胶囊又得逐颗 hover。
/// 高亮用 `Color.primary.opacity` 自适应:Light=压暗、Dark=提亮,夜间自动统一。
///
/// `@State` 必须放在内嵌 `SegmentBody: View` 上,不能直接挂 `ButtonStyle`:
/// `ButtonStyle` 不是 `View`,SwiftUI 不为其安装 `@State` 存储,直接挂会让
/// `isHovered` 变更不回写/不触发重绘(hover 高亮失效)。而 QA 的
/// `forceSegmentHover` 旁路恰好短路了 `isHovered`,自截图永远验不出这个 bug。
struct ClipinFooterSegmentStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SegmentBody(configuration: configuration)
    }

    private struct SegmentBody: View {
        let configuration: Configuration
        @State private var isHovered = false

        var body: some View {
            let pressed = configuration.isPressed
            let highlighted = isHovered || QAFlags.forceSegmentHover
            return configuration.label
                .padding(.horizontal, ClipinChrome.groupGap)
                .padding(.vertical, ClipinChrome.gap)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.primary.opacity(pressed ? 0.16 : (highlighted ? 0.09 : 0)))
                        .padding(ClipinChrome.footerHoverRimInset) // 内缩一圈:高亮比按钮小一圈,露出外层连续玻璃
                )
                .scaleEffect(pressed ? 0.97 : 1)
                .contentShape(Capsule(style: .continuous))
                .onHover { hovering in
                    withAnimation(ClipinMotion.feedback) { isHovered = hovering }
                }
                .animation(ClipinMotion.feedback, value: pressed)
        }
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

