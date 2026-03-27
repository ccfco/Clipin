import Foundation
import SwiftUI

enum VisualTheme: String, CaseIterable {
    case mist = "mist"
    case graphite = "graphite"
    case sunrise = "sunrise"

    var displayName: String {
        switch self {
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
}

enum ClipinMotion {
    static let feedback = Animation.spring(response: 0.22, dampingFraction: 0.82)
    static let selection = Animation.spring(response: 0.26, dampingFraction: 0.84)
    static let panel = Animation.spring(response: 0.32, dampingFraction: 0.84)
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
    let paletteTint: Color
    let paletteHighlight: Color
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
    let separatorLine: Color
    let primaryActionTintTop: Color
    let primaryActionTintBottom: Color
    let primaryActionHighlight: Color
    let primaryActionGlow: Color
    let primaryActionKeycapTint: Color
}

extension ClipinGlassPalette {
    static func make(theme: VisualTheme, colorScheme: ColorScheme) -> Self {
        let isDark = colorScheme == .dark

        switch (theme, isDark) {
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
                paletteTint: Color(red: 0.96, green: 0.97, blue: 1.0, opacity: 0.42),
                paletteHighlight: Color.white.opacity(0.52),
                keycapTint: Color.white.opacity(0.20),
                emphasisInk: Color(red: 0.23, green: 0.48, blue: 0.94),
                emphasisFill: Color(red: 0.23, green: 0.48, blue: 0.94, opacity: 0.12),
                emphasisStrongFill: Color(red: 0.23, green: 0.48, blue: 0.94, opacity: 0.72),
                emphasisOnStrongFill: .white,
                emphasisStroke: Color(red: 0.23, green: 0.48, blue: 0.94, opacity: 0.18),
                hoverFill: Color.white.opacity(0.34),
                hoverStroke: Color.white.opacity(0.22),
                controlFill: Color.white.opacity(0.32),
                controlStroke: Color.white.opacity(0.20),
                separatorLine: Color.primary.opacity(0.06),
                primaryActionTintTop: Color(red: 0.37, green: 0.62, blue: 1.0, opacity: 0.96),
                primaryActionTintBottom: Color(red: 0.23, green: 0.48, blue: 0.96, opacity: 0.90),
                primaryActionHighlight: Color.white.opacity(0.34),
                primaryActionGlow: Color(red: 0.27, green: 0.50, blue: 0.96, opacity: 0.26),
                primaryActionKeycapTint: Color.white.opacity(0.18)
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
                paletteTint: Color(red: 0.24, green: 0.22, blue: 0.34, opacity: 0.28),
                paletteHighlight: Color(red: 0.64, green: 0.60, blue: 0.92, opacity: 0.14),
                keycapTint: Color.white.opacity(0.10),
                emphasisInk: Color(red: 0.63, green: 0.75, blue: 1.0),
                emphasisFill: Color(red: 0.48, green: 0.62, blue: 0.98, opacity: 0.18),
                emphasisStrongFill: Color(red: 0.30, green: 0.42, blue: 0.86, opacity: 0.76),
                emphasisOnStrongFill: .white,
                emphasisStroke: Color(red: 0.54, green: 0.68, blue: 1.0, opacity: 0.26),
                hoverFill: Color.white.opacity(0.06),
                hoverStroke: Color.white.opacity(0.08),
                controlFill: Color.white.opacity(0.07),
                controlStroke: Color.white.opacity(0.09),
                separatorLine: Color.white.opacity(0.05),
                primaryActionTintTop: Color(red: 0.44, green: 0.58, blue: 0.98, opacity: 0.78),
                primaryActionTintBottom: Color(red: 0.26, green: 0.38, blue: 0.84, opacity: 0.72),
                primaryActionHighlight: Color.white.opacity(0.18),
                primaryActionGlow: Color(red: 0.30, green: 0.43, blue: 0.90, opacity: 0.24),
                primaryActionKeycapTint: Color.white.opacity(0.12)
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
                paletteTint: Color.white.opacity(0.36),
                paletteHighlight: Color.white.opacity(0.44),
                keycapTint: Color.white.opacity(0.16),
                emphasisInk: Color(red: 0.34, green: 0.40, blue: 0.50),
                emphasisFill: Color(red: 0.34, green: 0.40, blue: 0.50, opacity: 0.12),
                emphasisStrongFill: Color(red: 0.33, green: 0.39, blue: 0.49, opacity: 0.68),
                emphasisOnStrongFill: .white,
                emphasisStroke: Color(red: 0.34, green: 0.40, blue: 0.50, opacity: 0.16),
                hoverFill: Color.white.opacity(0.28),
                hoverStroke: Color.white.opacity(0.18),
                controlFill: Color.white.opacity(0.26),
                controlStroke: Color.white.opacity(0.18),
                separatorLine: Color.primary.opacity(0.06),
                primaryActionTintTop: Color(red: 0.46, green: 0.54, blue: 0.67, opacity: 0.94),
                primaryActionTintBottom: Color(red: 0.30, green: 0.37, blue: 0.49, opacity: 0.90),
                primaryActionHighlight: Color.white.opacity(0.30),
                primaryActionGlow: Color(red: 0.30, green: 0.37, blue: 0.49, opacity: 0.18),
                primaryActionKeycapTint: Color.white.opacity(0.16)
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
                paletteTint: Color.white.opacity(0.08),
                paletteHighlight: Color.white.opacity(0.10),
                keycapTint: Color.white.opacity(0.10),
                emphasisInk: Color(red: 0.75, green: 0.79, blue: 0.88),
                emphasisFill: Color(red: 0.62, green: 0.68, blue: 0.82, opacity: 0.15),
                emphasisStrongFill: Color(red: 0.34, green: 0.40, blue: 0.52, opacity: 0.72),
                emphasisOnStrongFill: .white,
                emphasisStroke: Color(red: 0.66, green: 0.73, blue: 0.88, opacity: 0.22),
                hoverFill: Color.white.opacity(0.05),
                hoverStroke: Color.white.opacity(0.07),
                controlFill: Color.white.opacity(0.06),
                controlStroke: Color.white.opacity(0.08),
                separatorLine: Color.white.opacity(0.05),
                primaryActionTintTop: Color(red: 0.39, green: 0.45, blue: 0.55, opacity: 0.76),
                primaryActionTintBottom: Color(red: 0.23, green: 0.28, blue: 0.36, opacity: 0.70),
                primaryActionHighlight: Color.white.opacity(0.14),
                primaryActionGlow: Color(red: 0.22, green: 0.26, blue: 0.34, opacity: 0.22),
                primaryActionKeycapTint: Color.white.opacity(0.12)
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
                paletteTint: Color(red: 1.0, green: 0.95, blue: 0.90, opacity: 0.38),
                paletteHighlight: Color.white.opacity(0.48),
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
                controlStroke: Color.white.opacity(0.18),
                separatorLine: Color.primary.opacity(0.06),
                primaryActionTintTop: Color(red: 1.0, green: 0.63, blue: 0.36, opacity: 0.96),
                primaryActionTintBottom: Color(red: 0.96, green: 0.44, blue: 0.28, opacity: 0.92),
                primaryActionHighlight: Color.white.opacity(0.34),
                primaryActionGlow: Color(red: 0.92, green: 0.44, blue: 0.22, opacity: 0.24),
                primaryActionKeycapTint: Color.white.opacity(0.18)
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
                paletteTint: Color(red: 0.31, green: 0.22, blue: 0.17, opacity: 0.22),
                paletteHighlight: Color(red: 1.0, green: 0.88, blue: 0.78, opacity: 0.12),
                keycapTint: Color.white.opacity(0.10),
                emphasisInk: Color(red: 1.0, green: 0.72, blue: 0.58),
                emphasisFill: Color(red: 0.96, green: 0.58, blue: 0.42, opacity: 0.18),
                emphasisStrongFill: Color(red: 0.62, green: 0.31, blue: 0.20, opacity: 0.76),
                emphasisOnStrongFill: .white,
                emphasisStroke: Color(red: 1.0, green: 0.74, blue: 0.58, opacity: 0.24),
                hoverFill: Color.white.opacity(0.05),
                hoverStroke: Color.white.opacity(0.07),
                controlFill: Color.white.opacity(0.06),
                controlStroke: Color.white.opacity(0.08),
                separatorLine: Color.white.opacity(0.05),
                primaryActionTintTop: Color(red: 0.82, green: 0.46, blue: 0.26, opacity: 0.78),
                primaryActionTintBottom: Color(red: 0.58, green: 0.28, blue: 0.18, opacity: 0.74),
                primaryActionHighlight: Color.white.opacity(0.16),
                primaryActionGlow: Color(red: 0.46, green: 0.23, blue: 0.15, opacity: 0.24),
                primaryActionKeycapTint: Color.white.opacity(0.12)
            )
        }
    }
}
