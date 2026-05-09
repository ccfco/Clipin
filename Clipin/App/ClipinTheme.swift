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
    // 圆角层级：shell 24 → section 16 → contentStage/search 14 → metadata 12 → row 12 → badge 10/7
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

    var stripAccentOpacity: Double {
        if isContinuousPasteEnabled { return 0.94 }
        if isShowingActions { return 0.66 }
        if hasSelection { return 0.34 }
        return 0.14
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

struct ClipinRoundedSurface: View {
    let cornerRadius: CGFloat
    let material: Material
    let tint: Color
    let stroke: Color
    let highlight: Color
    let shadowColor: Color
    let shadowRadius: CGFloat
    let shadowYOffset: CGFloat

    init(
        cornerRadius: CGFloat,
        material: Material,
        tint: Color,
        stroke: Color,
        highlight: Color = .clear,
        shadowColor: Color = .clear,
        shadowRadius: CGFloat = 0,
        shadowYOffset: CGFloat = 0
    ) {
        self.cornerRadius = cornerRadius
        self.material = material
        self.tint = tint
        self.stroke = stroke
        self.highlight = highlight
        self.shadowColor = shadowColor
        self.shadowRadius = shadowRadius
        self.shadowYOffset = shadowYOffset
    }

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(material)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(tint)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [highlight, Color.clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(stroke, lineWidth: 0.5)
            )
            .shadow(color: shadowColor, radius: shadowRadius, y: shadowYOffset)
    }
}

struct ClipinKeycap: View {
    let key: String
    let foreground: Color
    let background: Color

    var body: some View {
        Text(key)
            .font(.system(size: 10.5, weight: .medium, design: .rounded))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(background)
            )
    }
}

struct ClipinShellBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isBreathing = false

    let glass: ClipinGlassPalette
    let cornerRadius: CGFloat
    let sceneState: ClipinSceneState

    init(
        glass: ClipinGlassPalette,
        cornerRadius: CGFloat = ClipinChrome.shellCornerRadius,
        sceneState: ClipinSceneState = .idle
    ) {
        self.glass = glass
        self.cornerRadius = cornerRadius
        self.sceneState = sceneState
    }

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(colorScheme == .dark ? Material.regularMaterial : Material.thickMaterial)
            .overlay(
                LinearGradient(
                    colors: [glass.shellTintTop, glass.shellTintBottom],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                LinearGradient(
                    colors: [glass.shellWash.opacity(colorScheme == .dark ? 0.82 + (sceneState.ambientStrength * 0.22) : 0.04 + (sceneState.ambientStrength * 0.015)), Color.clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(
                LinearGradient(
                    colors: [glass.shellHighlight.opacity((colorScheme == .dark ? 0.84 : 0.06) + (sceneState.ambientStrength * (colorScheme == .dark ? 0.12 : 0.015))), Color.clear],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(alignment: .topLeading) {
                if colorScheme == .dark {
                    Circle()
                        .fill(glass.emphasisStrongFill.opacity(0.12 + (sceneState.ambientStrength * 0.12)))
                        .frame(width: 260, height: 260)
                        .blur(radius: 56)
                        .scaleEffect(reduceMotion ? 1 : (isBreathing ? 1.06 : 0.96))
                        .offset(
                            x: reduceMotion ? -84 : (isBreathing ? -72 : -92),
                            y: reduceMotion ? -108 : (isBreathing ? -96 : -116)
                        )
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if colorScheme == .dark {
                    Circle()
                        .fill(glass.emphasisFill.opacity(0.20 + (sceneState.ambientStrength * 0.14)))
                        .frame(width: 230, height: 230)
                        .blur(radius: 48)
                        .scaleEffect(reduceMotion ? 1 : (isBreathing ? 0.98 : 1.06))
                        .offset(
                            x: reduceMotion ? 88 : (isBreathing ? 80 : 96),
                            y: reduceMotion ? 104 : (isBreathing ? 96 : 110)
                        )
                }
            }
            // Accent 底部渐变：赋予面板色彩身份感，同时在浅色背景下提供额外对比
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.clear,
                                Color.accentColor.opacity(colorScheme == .dark ? 0.12 : 0.07)
                            ],
                            startPoint: UnitPoint(x: 0.5, y: 0.55),
                            endPoint: .bottom
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.0 : 0.08), lineWidth: 0.5)
                    .mask(
                        LinearGradient(
                            colors: [Color.white, Color.white.opacity(0.16), Color.clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.22), lineWidth: 0.5)
            )
            .onAppear {
                guard !reduceMotion else { return }
                isBreathing = false
                withAnimation(ClipinMotion.ambient.repeatForever(autoreverses: true)) {
                    isBreathing = true
                }
            }
    }
}

struct ClipinSymbolOrb: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isFloating = false

    let systemImage: String
    let glass: ClipinGlassPalette
    let hierarchy: ClipinPanelHierarchy
    var size: CGFloat = 64
    var iconSize: CGFloat = 22
    var emphasis: Double = 1.0

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: ClipinChrome.heroOrbCornerRadius, style: .continuous)
                .fill(glass.emphasisStrongFill.opacity(0.08 + (0.04 * emphasis)))
                .frame(width: size + 14, height: size + 14)
                .blur(radius: 18)
                .scaleEffect(reduceMotion ? 1 : (isFloating ? 1.04 : 0.98))

            RoundedRectangle(cornerRadius: ClipinChrome.heroOrbCornerRadius, style: .continuous)
                .fill(glass.emphasisFill)
                .overlay(
                    RoundedRectangle(cornerRadius: ClipinChrome.heroOrbCornerRadius, style: .continuous)
                        .strokeBorder(glass.emphasisStroke.opacity(0.82), lineWidth: 0.75)
                )
                .frame(width: size, height: size)
                .scaleEffect(reduceMotion ? 1 : (isFloating ? 1.01 : 0.99))

            Image(systemName: systemImage)
                .font(.system(size: iconSize, weight: .medium))
                .foregroundStyle(hierarchy.selection.ink)
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
    let hierarchy: ClipinPanelHierarchy
    var eyebrow: LocalizedStringKey? = nil
    var titleFontSize: CGFloat = 24
    var subtitleFontSize: CGFloat = 13

    var body: some View {
        VStack(alignment: .leading, spacing: ClipinChrome.sectionIntroSpacing) {
            if let eyebrow {
                Text(eyebrow)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(hierarchy.support.smallLabelInk)
                    .tracking(0.45)
            }

            Text(title)
                .font(.system(size: titleFontSize, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)

            Text(subtitle)
                .font(.system(size: subtitleFontSize))
                .foregroundStyle(hierarchy.support.subduedInk)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

enum ClipinSurfaceRole {
    case sidebar
    case column
    case floating
    case control
    case strip
    case grouped
    case contentStage
    case metadata
}

/// 共享 surface 语义，避免主面板、动作面板、设置页各自手搓一套玻璃参数。
struct ClipinSurfaceStyle {
    let material: Material
    let tint: Color
    let stroke: Color
    let highlight: Color
    let shadowColor: Color
    let shadowRadius: CGFloat
    let shadowYOffset: CGFloat
}

/// 统一把 surface 角色映射到具体 material / tint / stroke / shadow。
struct ClipinSurfaceBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    let role: ClipinSurfaceRole
    let cornerRadius: CGFloat
    let glass: ClipinGlassPalette

    var body: some View {
        let style = glass.surfaceStyle(for: role, colorScheme: colorScheme)
        ClipinRoundedSurface(
            cornerRadius: cornerRadius,
            material: style.material,
            tint: style.tint,
            stroke: style.stroke,
            highlight: style.highlight,
            shadowColor: style.shadowColor,
            shadowRadius: style.shadowRadius,
            shadowYOffset: style.shadowYOffset
        )
    }
}

/// 所有列表型界面的选中/悬停底板，主列表、动作面板、设置侧栏共用。
struct ClipinSelectableRowBackground: View {
    let isSelected: Bool
    let isHovered: Bool
    let selectionFill: Color
    let selectionStroke: Color
    let hoverFill: Color
    let hoverStroke: Color

    var body: some View {
        RoundedRectangle(cornerRadius: ClipinChrome.rowCornerRadius, style: .continuous)
            .fill(
                isSelected
                    ? selectionFill
                    : isHovered
                        ? hoverFill
                        : Color.clear
            )
            .overlay(
                RoundedRectangle(cornerRadius: ClipinChrome.rowCornerRadius, style: .continuous)
                    .strokeBorder(
                        isSelected
                            ? selectionStroke
                            : isHovered
                                ? hoverStroke
                                : Color.clear,
                        lineWidth: 0.5
                    )
            )
    }
}

struct ClipinGlassPalette {
    let shellTintTop: Color
    let shellTintBottom: Color
    let shellHighlight: Color
    let shellWash: Color
    let chromeTint: Color
    let sidebarTint: Color
    let detailTint: Color
    let previewCanvasTint: Color
    let keycapTint: Color
    let emphasisInk: Color
    let emphasisFill: Color
    let emphasisStrongFill: Color
    /// 在 emphasisStrongFill 背景上使用的前景色，保证对比度
    let emphasisOnStrongFill: Color
    let emphasisStroke: Color
    let hoverFill: Color
    let hoverStroke: Color
    let controlFill: Color
    let controlStroke: Color
}

/// 主面板的任务层级语义：
/// - scope: 搜索与筛选，只负责限定范围
/// - selection: 左侧当前对象，负责建立列表到预览的映射
/// - command: 底部命令提示，说明回车会发生什么，但不与内容争主角
struct ClipinPanelHierarchy {
    struct Scope {
        let fill: Color
        let stroke: Color
        let ink: Color
        let shortcutInk: Color
    }

    struct Selection {
        let fill: Color
        let stroke: Color
        let ink: Color
        let secondaryInk: Color
        let dimInk: Color
        let badgeFill: Color
        let highlight: Color
    }

    struct Command {
        let fill: Color
        let stroke: Color
        let ink: Color
        let iconFill: Color
        let iconInk: Color
        let keycapFill: Color
    }

    struct Support {
        let subduedInk: Color
        let smallLabelInk: Color
        let hintInk: Color
        let placeholderInk: Color
    }

    let scope: Scope
    let selection: Selection
    let command: Command
    let support: Support
}

extension ClipinPanelHierarchy {
    static func make(glass: ClipinGlassPalette, colorScheme: ColorScheme) -> Self {
        let isDark = colorScheme == .dark

        return Self(
            scope: Scope(
                fill: glass.emphasisFill.opacity(isDark ? 0.96 : 0.90),
                stroke: glass.emphasisStroke.opacity(isDark ? 0.96 : 0.78),
                ink: glass.emphasisInk.opacity(isDark ? 0.92 : 0.82),
                shortcutInk: glass.emphasisInk.opacity(isDark ? 0.62 : 0.52)
            ),
            selection: Selection(
                fill: glass.emphasisFill,
                stroke: glass.emphasisStroke,
                ink: glass.emphasisInk.opacity(isDark ? 0.98 : 0.92),
                secondaryInk: glass.emphasisInk.opacity(isDark ? 0.64 : 0.58),
                dimInk: glass.emphasisInk.opacity(isDark ? 0.72 : 0.64),
                badgeFill: glass.keycapTint.opacity(isDark ? 1.0 : 0.92),
                highlight: glass.emphasisFill.opacity(isDark ? 1.0 : 0.85)
            ),
            command: Command(
                fill: glass.controlFill.opacity(isDark ? 0.98 : 1.04),
                stroke: glass.controlStroke.opacity(isDark ? 0.98 : 0.94),
                ink: Color.primary.opacity(isDark ? 0.96 : 0.84),
                iconFill: glass.emphasisStrongFill.opacity(isDark ? 0.92 : 0.82),
                iconInk: glass.emphasisOnStrongFill.opacity(isDark ? 0.96 : 0.90),
                keycapFill: glass.keycapTint.opacity(isDark ? 1.0 : 0.88)
            ),
            support: Support(
                subduedInk: Color.primary.opacity(isDark ? 0.78 : 0.72),
                smallLabelInk: Color.primary.opacity(isDark ? 0.72 : 0.66),
                hintInk: Color.primary.opacity(isDark ? 0.58 : 0.54),
                placeholderInk: Color.primary.opacity(isDark ? 0.46 : 0.34)
            )
        )
    }
}

extension ClipinGlassPalette {
    func surfaceStyle(for role: ClipinSurfaceRole, colorScheme: ColorScheme) -> ClipinSurfaceStyle {
        let isDark = colorScheme == .dark

        switch role {
        // ── 主 UI 三区：统一 accent tint 语言，shadow 用 diffuse（大 radius 小 opacity）创造呼吸感 ──

        case .sidebar:
            // 主角：accent 最重，shadow 最大，列表区浮在 shell 上
            return ClipinSurfaceStyle(
                material: isDark ? .thinMaterial : .thickMaterial,
                tint: isDark ? sidebarTint.opacity(1.0) : Color.accentColor.opacity(0.05),
                stroke: controlStroke.opacity(isDark ? 0.96 : 1.10),
                highlight: shellHighlight.opacity(isDark ? 0.08 : 0.015),
                shadowColor: .black.opacity(isDark ? 0.14 : 0.12),
                shadowRadius: isDark ? 5 : 16,
                shadowYOffset: isDark ? 2 : 4
            )

        case .control:
            // 搜索框：accent 同色系但更轻，shadow diffuse，和 sidebar 呼应
            return ClipinSurfaceStyle(
                material: isDark ? .regularMaterial : .thickMaterial,
                tint: isDark ? controlFill.opacity(0.96) : Color.accentColor.opacity(0.04),
                stroke: controlStroke.opacity(isDark ? 0.96 : 1.08),
                highlight: shellHighlight.opacity(isDark ? 0.12 : 0.010),
                shadowColor: .black.opacity(isDark ? 0.0 : 0.06),
                shadowRadius: isDark ? 0 : 12,
                shadowYOffset: isDark ? 0 : 3
            )

        case .strip:
            // 命令条：accent 同 control，shadow 对称，底部收尾
            return ClipinSurfaceStyle(
                material: isDark ? .ultraThinMaterial : .thickMaterial,
                tint: isDark ? controlFill.opacity(0.92) : Color.accentColor.opacity(0.04),
                stroke: controlStroke.opacity(isDark ? 0.92 : 1.08),
                highlight: shellHighlight.opacity(isDark ? 0.08 : 0.010),
                shadowColor: .black.opacity(isDark ? 0.12 : 0.07),
                shadowRadius: isDark ? 4 : 12,
                shadowYOffset: isDark ? 2 : 3
            )

        // ── 内容区：neutral，让内容自己说话 ──

        case .column:
            // 预览右栏：安静 neutral，shadow 很轻
            return ClipinSurfaceStyle(
                material: isDark ? .regularMaterial : .thickMaterial,
                tint: detailTint.opacity(isDark ? 1.0 : 0.96),
                stroke: controlStroke.opacity(isDark ? 1.0 : 1.06),
                highlight: shellHighlight.opacity(isDark ? 0.10 : 0.014),
                shadowColor: .black.opacity(isDark ? 0.16 : 0.04),
                shadowRadius: isDark ? 6 : 10,
                shadowYOffset: isDark ? 3 : 2
            )

        case .contentStage:
            // 内容卡片：最亮（white tint），大 shadow 让它"浮"起来
            return ClipinSurfaceStyle(
                material: isDark ? .thinMaterial : .regularMaterial,
                tint: previewCanvasTint.opacity(isDark ? 0.68 : 1.0),
                stroke: controlStroke.opacity(isDark ? 0.54 : 1.10),
                highlight: shellHighlight.opacity(isDark ? 0.03 : 0.02),
                shadowColor: .black.opacity(isDark ? 0.18 : 0.07),
                shadowRadius: isDark ? 5 : 14,
                shadowYOffset: isDark ? 2 : 5
            )

        case .metadata:
            // 元数据块：flat，不抢内容
            return ClipinSurfaceStyle(
                material: isDark ? .thinMaterial : .regularMaterial,
                tint: controlFill.opacity(isDark ? 0.86 : 0.88),
                stroke: hoverStroke.opacity(isDark ? 0.92 : 0.82),
                highlight: shellHighlight.opacity(isDark ? 0.03 : 0.01),
                shadowColor: .black.opacity(isDark ? 0.08 : 0.0),
                shadowRadius: isDark ? 4 : 0,
                shadowYOffset: 1
            )

        case .floating:
            // 动作面板：accent 最强（覆盖在最顶层），shadow 最重
            return ClipinSurfaceStyle(
                material: isDark ? .regularMaterial : .thickMaterial,
                tint: isDark ? detailTint.opacity(1.0) : Color.accentColor.opacity(0.06),
                stroke: controlStroke.opacity(isDark ? 1.0 : 1.10),
                highlight: shellHighlight.opacity(isDark ? 0.12 : 0.04),
                shadowColor: .black.opacity(isDark ? 0.18 : 0.12),
                shadowRadius: isDark ? 18 : 20,
                shadowYOffset: isDark ? 10 : 8
            )

        case .grouped:
            // keycap 小徽标：白色轻薄，tiny shadow
            return ClipinSurfaceStyle(
                material: isDark ? .thinMaterial : .thickMaterial,
                tint: keycapTint.opacity(isDark ? 0.86 : 0.96),
                stroke: controlStroke.opacity(isDark ? 0.90 : 0.88),
                highlight: shellHighlight.opacity(isDark ? 0.04 : 0.008),
                shadowColor: .black.opacity(isDark ? 0.10 : 0.03),
                shadowRadius: isDark ? 4 : 5,
                shadowYOffset: 1
            )
        }
    }
}

extension ClipinGlassPalette {
    static func make(theme: VisualTheme, colorScheme: ColorScheme) -> Self {
        let isDark = colorScheme == .dark

        let accent = Color.accentColor

        switch (theme, isDark) {
        case (.native, false):
            return Self(
                // 降低 shellTint 覆盖率，让 thickMaterial 固有色透出，整体更轻盈
                shellTintTop: Color(nsColor: .windowBackgroundColor).opacity(0.44),
                shellTintBottom: Color(nsColor: .windowBackgroundColor).opacity(0.26),
                shellHighlight: Color.white.opacity(0.028),
                shellWash: Color.white.opacity(0.014),
                chromeTint: Color.clear,
                sidebarTint: Color(nsColor: .windowBackgroundColor).opacity(0.38),
                detailTint: Color(nsColor: .windowBackgroundColor).opacity(0.30),
                previewCanvasTint: Color.white.opacity(0.30),
                keycapTint: Color.white.opacity(0.46),
                emphasisInk: Color.primary,
                emphasisFill: Color.primary.opacity(0.14),
                emphasisStrongFill: accent.opacity(0.68),
                emphasisOnStrongFill: .white,
                emphasisStroke: Color.primary.opacity(0.18),
                hoverFill: Color.primary.opacity(0.034),
                hoverStroke: Color.primary.opacity(0.102),
                controlFill: Color(nsColor: .windowBackgroundColor).opacity(0.34),
                controlStroke: Color.primary.opacity(0.128)
            )
        case (.native, true):
            return Self(
                shellTintTop: Color.clear,
                shellTintBottom: Color.clear,
                shellHighlight: Color.white.opacity(0.08),
                shellWash: Color.white.opacity(0.05),
                chromeTint: Color.clear,
                sidebarTint: Color.white.opacity(0.015),
                detailTint: Color.white.opacity(0.03),
                previewCanvasTint: Color.white.opacity(0.03),
                keycapTint: Color.white.opacity(0.06),
                emphasisInk: Color.primary,
                emphasisFill: Color.white.opacity(0.15),
                emphasisStrongFill: accent.opacity(0.70),
                emphasisOnStrongFill: .white,
                emphasisStroke: Color.white.opacity(0.18),
                hoverFill: Color.white.opacity(0.04),
                hoverStroke: Color.white.opacity(0.06),
                controlFill: Color.white.opacity(0.04),
                controlStroke: Color.white.opacity(0.06)
            )
        case (.mist, false):
            return Self(
                shellTintTop: Color(red: 0.93, green: 0.95, blue: 1.0, opacity: 0.52),
                shellTintBottom: Color(red: 0.89, green: 0.91, blue: 0.99, opacity: 0.30),
                shellHighlight: Color.white.opacity(0.42),
                shellWash: Color.white.opacity(0.18),
                chromeTint: Color(red: 0.95, green: 0.97, blue: 1.0, opacity: 0.28),
                sidebarTint: Color(red: 0.89, green: 0.91, blue: 0.99, opacity: 0.24),
                detailTint: Color.white.opacity(0.34),
                previewCanvasTint: Color(red: 0.95, green: 0.96, blue: 1.0, opacity: 0.82),
                keycapTint: Color.white.opacity(0.20),
                emphasisInk: Color(red: 0.23, green: 0.48, blue: 0.94),
                emphasisFill: Color(red: 0.23, green: 0.48, blue: 0.94, opacity: 0.12),
                emphasisStrongFill: Color(red: 0.23, green: 0.48, blue: 0.94, opacity: 0.72),
                emphasisOnStrongFill: .white,
                emphasisStroke: Color(red: 0.23, green: 0.48, blue: 0.94, opacity: 0.18),
                hoverFill: Color.white.opacity(0.34),
                hoverStroke: Color.white.opacity(0.22),
                controlFill: Color.white.opacity(0.32),
                controlStroke: Color.white.opacity(0.20)
            )
        case (.mist, true):
            return Self(
                shellTintTop: Color(red: 0.23, green: 0.21, blue: 0.33, opacity: 0.36),
                shellTintBottom: Color(red: 0.12, green: 0.13, blue: 0.18, opacity: 0.30),
                shellHighlight: Color.white.opacity(0.14),
                shellWash: Color.white.opacity(0.08),
                chromeTint: Color(red: 0.14, green: 0.16, blue: 0.23, opacity: 0.24),
                sidebarTint: Color(red: 0.20, green: 0.20, blue: 0.28, opacity: 0.22),
                detailTint: Color(red: 0.18, green: 0.19, blue: 0.27, opacity: 0.30),
                previewCanvasTint: Color(red: 0.24, green: 0.24, blue: 0.32, opacity: 0.24),
                keycapTint: Color.white.opacity(0.10),
                emphasisInk: Color(red: 0.63, green: 0.75, blue: 1.0),
                emphasisFill: Color(red: 0.48, green: 0.62, blue: 0.98, opacity: 0.18),
                emphasisStrongFill: Color(red: 0.30, green: 0.42, blue: 0.86, opacity: 0.76),
                emphasisOnStrongFill: .white,
                emphasisStroke: Color(red: 0.54, green: 0.68, blue: 1.0, opacity: 0.26),
                hoverFill: Color.white.opacity(0.06),
                hoverStroke: Color.white.opacity(0.08),
                controlFill: Color.white.opacity(0.07),
                controlStroke: Color.white.opacity(0.09)
            )
        case (.graphite, false):
            return Self(
                shellTintTop: Color(red: 0.95, green: 0.96, blue: 0.98, opacity: 0.48),
                shellTintBottom: Color(red: 0.90, green: 0.92, blue: 0.95, opacity: 0.28),
                shellHighlight: Color.white.opacity(0.38),
                shellWash: Color.white.opacity(0.16),
                chromeTint: Color.white.opacity(0.24),
                sidebarTint: Color(red: 0.91, green: 0.92, blue: 0.95, opacity: 0.20),
                detailTint: Color.white.opacity(0.30),
                previewCanvasTint: Color(red: 0.95, green: 0.95, blue: 0.97, opacity: 0.80),
                keycapTint: Color.white.opacity(0.16),
                emphasisInk: Color(red: 0.34, green: 0.40, blue: 0.50),
                emphasisFill: Color(red: 0.34, green: 0.40, blue: 0.50, opacity: 0.12),
                emphasisStrongFill: Color(red: 0.33, green: 0.39, blue: 0.49, opacity: 0.68),
                emphasisOnStrongFill: .white,
                emphasisStroke: Color(red: 0.34, green: 0.40, blue: 0.50, opacity: 0.16),
                hoverFill: Color.white.opacity(0.28),
                hoverStroke: Color.white.opacity(0.18),
                controlFill: Color.white.opacity(0.26),
                controlStroke: Color.white.opacity(0.18)
            )
        case (.graphite, true):
            return Self(
                shellTintTop: Color(red: 0.20, green: 0.21, blue: 0.24, opacity: 0.34),
                shellTintBottom: Color(red: 0.10, green: 0.11, blue: 0.13, opacity: 0.28),
                shellHighlight: Color.white.opacity(0.12),
                shellWash: Color.white.opacity(0.07),
                chromeTint: Color.white.opacity(0.06),
                sidebarTint: Color.white.opacity(0.05),
                detailTint: Color.white.opacity(0.08),
                previewCanvasTint: Color.white.opacity(0.08),
                keycapTint: Color.white.opacity(0.10),
                emphasisInk: Color(red: 0.75, green: 0.79, blue: 0.88),
                emphasisFill: Color(red: 0.62, green: 0.68, blue: 0.82, opacity: 0.15),
                emphasisStrongFill: Color(red: 0.34, green: 0.40, blue: 0.52, opacity: 0.72),
                emphasisOnStrongFill: .white,
                emphasisStroke: Color(red: 0.66, green: 0.73, blue: 0.88, opacity: 0.22),
                hoverFill: Color.white.opacity(0.05),
                hoverStroke: Color.white.opacity(0.07),
                controlFill: Color.white.opacity(0.06),
                controlStroke: Color.white.opacity(0.08)
            )
        case (.sunrise, false):
            return Self(
                shellTintTop: Color(red: 1.0, green: 0.95, blue: 0.90, opacity: 0.46),
                shellTintBottom: Color(red: 0.99, green: 0.90, blue: 0.84, opacity: 0.28),
                shellHighlight: Color.white.opacity(0.38),
                shellWash: Color.white.opacity(0.16),
                chromeTint: Color(red: 1.0, green: 0.95, blue: 0.90, opacity: 0.20),
                sidebarTint: Color(red: 0.99, green: 0.92, blue: 0.86, opacity: 0.22),
                detailTint: Color.white.opacity(0.32),
                previewCanvasTint: Color(red: 1.0, green: 0.96, blue: 0.92, opacity: 0.80),
                keycapTint: Color.white.opacity(0.20),
                emphasisInk: Color(red: 0.90, green: 0.42, blue: 0.20),
                emphasisFill: Color(red: 0.90, green: 0.42, blue: 0.20, opacity: 0.13),
                emphasisStrongFill: Color(red: 0.90, green: 0.42, blue: 0.20, opacity: 0.72),
                // sunrise 亮色底：橙色半透明背景叠白色面板后偏浅，白字对比度不足，改用深暖棕
                emphasisOnStrongFill: Color(red: 0.22, green: 0.08, blue: 0.02),
                emphasisStroke: Color(red: 0.90, green: 0.42, blue: 0.20, opacity: 0.18),
                hoverFill: Color.white.opacity(0.30),
                hoverStroke: Color.white.opacity(0.18),
                controlFill: Color.white.opacity(0.28),
                controlStroke: Color.white.opacity(0.18)
            )
        case (.sunrise, true):
            return Self(
                shellTintTop: Color(red: 0.33, green: 0.24, blue: 0.18, opacity: 0.34),
                shellTintBottom: Color(red: 0.17, green: 0.13, blue: 0.11, opacity: 0.30),
                shellHighlight: Color.white.opacity(0.12),
                shellWash: Color.white.opacity(0.07),
                chromeTint: Color(red: 0.30, green: 0.20, blue: 0.16, opacity: 0.18),
                sidebarTint: Color(red: 0.28, green: 0.20, blue: 0.16, opacity: 0.18),
                detailTint: Color(red: 0.26, green: 0.19, blue: 0.14, opacity: 0.22),
                previewCanvasTint: Color(red: 0.30, green: 0.22, blue: 0.17, opacity: 0.18),
                keycapTint: Color.white.opacity(0.10),
                emphasisInk: Color(red: 1.0, green: 0.72, blue: 0.58),
                emphasisFill: Color(red: 0.96, green: 0.58, blue: 0.42, opacity: 0.18),
                emphasisStrongFill: Color(red: 0.62, green: 0.31, blue: 0.20, opacity: 0.76),
                emphasisOnStrongFill: .white,
                emphasisStroke: Color(red: 1.0, green: 0.74, blue: 0.58, opacity: 0.24),
                hoverFill: Color.white.opacity(0.05),
                hoverStroke: Color.white.opacity(0.07),
                controlFill: Color.white.opacity(0.06),
                controlStroke: Color.white.opacity(0.08)
            )
        }
    }
}
