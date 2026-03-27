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
    static let shellCornerRadius: CGFloat = 24
    static let sectionCornerRadius: CGFloat = 20
    static let cardCornerRadius: CGFloat = 18
    static let searchCornerRadius: CGFloat = 16
    static let rowCornerRadius: CGFloat = 12
    static let paletteCornerRadius: CGFloat = 26
    static let primaryBadgeCornerRadius: CGFloat = 14
    static let badgeCornerRadius: CGFloat = 10
    static let listRowInset: CGFloat = 12
}

enum ClipinMotion {
    static let feedback = Animation.spring(response: 0.22, dampingFraction: 0.82)
    static let selection = Animation.spring(response: 0.26, dampingFraction: 0.84)
    static let panel = Animation.spring(response: 0.32, dampingFraction: 0.84)
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
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(background)
            )
    }
}

enum ClipinSurfaceRole {
    case sidebar
    case detail
    case floating
    case control
    case strip
    case grouped
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

    let scope: Scope
    let selection: Selection
    let command: Command
}

extension ClipinPanelHierarchy {
    static func make(glass: ClipinGlassPalette, colorScheme: ColorScheme) -> Self {
        let isDark = colorScheme == .dark

        return Self(
            scope: Scope(
                fill: glass.controlFill.opacity(isDark ? 0.96 : 0.90),
                stroke: glass.controlStroke.opacity(isDark ? 0.96 : 0.78),
                ink: Color.primary.opacity(isDark ? 0.92 : 0.78),
                shortcutInk: Color.secondary.opacity(isDark ? 0.58 : 0.48)
            ),
            selection: Selection(
                fill: glass.emphasisFill,
                stroke: glass.emphasisStroke,
                ink: glass.emphasisInk.opacity(isDark ? 0.98 : 0.92),
                secondaryInk: glass.emphasisInk.opacity(isDark ? 0.64 : 0.58),
                badgeFill: glass.keycapTint.opacity(isDark ? 1.0 : 0.92),
                highlight: glass.emphasisFill.opacity(isDark ? 1.0 : 0.85)
            ),
            command: Command(
                fill: glass.controlFill.opacity(isDark ? 0.98 : 0.92),
                stroke: glass.controlStroke.opacity(isDark ? 0.98 : 0.82),
                ink: Color.primary.opacity(isDark ? 0.96 : 0.84),
                iconFill: glass.emphasisStrongFill.opacity(isDark ? 0.92 : 0.82),
                iconInk: glass.emphasisOnStrongFill.opacity(isDark ? 0.96 : 0.90),
                keycapFill: glass.keycapTint.opacity(isDark ? 1.0 : 0.88)
            )
        )
    }
}

extension ClipinGlassPalette {
    func surfaceStyle(for role: ClipinSurfaceRole, colorScheme: ColorScheme) -> ClipinSurfaceStyle {
        let isDark = colorScheme == .dark

        switch role {
        case .sidebar:
            return ClipinSurfaceStyle(
                material: .thinMaterial,
                tint: sidebarTint,
                stroke: controlStroke,
                highlight: shellHighlight.opacity(isDark ? 0.08 : 0.22),
                shadowColor: .black.opacity(0.10),
                shadowRadius: 20,
                shadowYOffset: 10
            )

        case .detail:
            return ClipinSurfaceStyle(
                material: .regularMaterial,
                tint: detailTint,
                stroke: controlStroke,
                highlight: shellHighlight.opacity(isDark ? 0.10 : 0.24),
                shadowColor: .black.opacity(0.12),
                shadowRadius: 24,
                shadowYOffset: 12
            )

        case .floating:
            return ClipinSurfaceStyle(
                material: .regularMaterial,
                tint: detailTint,
                stroke: controlStroke,
                highlight: shellHighlight.opacity(isDark ? 0.12 : 0.28),
                shadowColor: .black.opacity(0.12),
                shadowRadius: 34,
                shadowYOffset: 18
            )

        case .control:
            return ClipinSurfaceStyle(
                material: .regularMaterial,
                tint: controlFill,
                stroke: controlStroke,
                highlight: shellHighlight.opacity(isDark ? 0.14 : 0.28),
                shadowColor: .clear,
                shadowRadius: 0,
                shadowYOffset: 0
            )

        case .strip:
            return ClipinSurfaceStyle(
                material: .ultraThinMaterial,
                tint: controlFill.opacity(isDark ? 0.94 : 0.88),
                stroke: controlStroke.opacity(isDark ? 0.92 : 0.84),
                highlight: shellHighlight.opacity(isDark ? 0.08 : 0.18),
                shadowColor: .clear,
                shadowRadius: 0,
                shadowYOffset: 0
            )

        case .grouped:
            return ClipinSurfaceStyle(
                material: .thinMaterial,
                tint: controlFill.opacity(isDark ? 0.92 : 0.84),
                stroke: hoverStroke,
                highlight: shellHighlight.opacity(isDark ? 0.04 : 0.12),
                shadowColor: .clear,
                shadowRadius: 0,
                shadowYOffset: 0
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
                shellTintTop: Color.clear,
                shellTintBottom: Color.clear,
                shellHighlight: Color.white.opacity(0.20),
                shellWash: Color.white.opacity(0.06),
                chromeTint: Color.clear,
                sidebarTint: Color.primary.opacity(0.015),
                detailTint: Color.white.opacity(0.12),
                previewCanvasTint: Color.primary.opacity(0.02),
                keycapTint: Color.primary.opacity(0.04),
                emphasisInk: Color.primary,
                emphasisFill: Color.primary.opacity(0.11),
                emphasisStrongFill: accent.opacity(0.68),
                emphasisOnStrongFill: .white,
                emphasisStroke: Color.primary.opacity(0.15),
                hoverFill: Color.primary.opacity(0.03),
                hoverStroke: Color.primary.opacity(0.05),
                controlFill: Color.primary.opacity(0.03),
                controlStroke: Color.primary.opacity(0.05)
            )
        case (.native, true):
            return Self(
                shellTintTop: Color.clear,
                shellTintBottom: Color.clear,
                shellHighlight: Color.white.opacity(0.06),
                shellWash: Color.white.opacity(0.03),
                chromeTint: Color.clear,
                sidebarTint: Color.white.opacity(0.015),
                detailTint: Color.white.opacity(0.03),
                previewCanvasTint: Color.white.opacity(0.03),
                keycapTint: Color.white.opacity(0.05),
                emphasisInk: Color.primary,
                emphasisFill: Color.white.opacity(0.13),
                emphasisStrongFill: accent.opacity(0.70),
                emphasisOnStrongFill: .white,
                emphasisStroke: Color.white.opacity(0.14),
                hoverFill: Color.white.opacity(0.03),
                hoverStroke: Color.white.opacity(0.05),
                controlFill: Color.white.opacity(0.03),
                controlStroke: Color.white.opacity(0.05)
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
