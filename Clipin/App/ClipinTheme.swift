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
    static let badgeCornerRadius: CGFloat = 10
}

struct ClipinGlassPalette {
    let shellTintTop: Color
    let shellTintBottom: Color
    let shellHighlight: Color
    let shellWash: Color
    let chromeTint: Color
    let sidebarTint: Color
    let detailTint: Color
    let searchInnerTint: Color
    let searchOuterTint: Color
    let infoTint: Color
    let previewCanvasTint: Color
    let paletteTint: Color
    let paletteHighlight: Color
    let keycapTint: Color
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
                searchInnerTint: Color.white.opacity(0.48),
                searchOuterTint: Color(red: 0.90, green: 0.93, blue: 1.0, opacity: 0.18),
                infoTint: Color(red: 0.93, green: 0.95, blue: 1.0, opacity: 0.28),
                previewCanvasTint: Color(red: 0.95, green: 0.96, blue: 1.0, opacity: 0.82),
                paletteTint: Color(red: 0.96, green: 0.97, blue: 1.0, opacity: 0.42),
                paletteHighlight: Color.white.opacity(0.52),
                keycapTint: Color.white.opacity(0.20)
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
                searchInnerTint: Color(red: 0.19, green: 0.18, blue: 0.28, opacity: 0.32),
                searchOuterTint: Color(red: 0.12, green: 0.14, blue: 0.21, opacity: 0.20),
                infoTint: Color(red: 0.22, green: 0.21, blue: 0.31, opacity: 0.18),
                previewCanvasTint: Color(red: 0.24, green: 0.24, blue: 0.32, opacity: 0.24),
                paletteTint: Color(red: 0.24, green: 0.22, blue: 0.34, opacity: 0.28),
                paletteHighlight: Color(red: 0.64, green: 0.60, blue: 0.92, opacity: 0.14),
                keycapTint: Color.white.opacity(0.10)
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
                searchInnerTint: Color.white.opacity(0.44),
                searchOuterTint: Color.white.opacity(0.14),
                infoTint: Color(red: 0.93, green: 0.94, blue: 0.97, opacity: 0.26),
                previewCanvasTint: Color(red: 0.95, green: 0.95, blue: 0.97, opacity: 0.80),
                paletteTint: Color.white.opacity(0.36),
                paletteHighlight: Color.white.opacity(0.44),
                keycapTint: Color.white.opacity(0.16)
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
                searchInnerTint: Color.white.opacity(0.08),
                searchOuterTint: Color.white.opacity(0.04),
                infoTint: Color.white.opacity(0.06),
                previewCanvasTint: Color.white.opacity(0.08),
                paletteTint: Color.white.opacity(0.08),
                paletteHighlight: Color.white.opacity(0.10),
                keycapTint: Color.white.opacity(0.10)
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
                searchInnerTint: Color.white.opacity(0.46),
                searchOuterTint: Color(red: 1.0, green: 0.94, blue: 0.88, opacity: 0.16),
                infoTint: Color(red: 1.0, green: 0.94, blue: 0.90, opacity: 0.24),
                previewCanvasTint: Color(red: 1.0, green: 0.96, blue: 0.92, opacity: 0.80),
                paletteTint: Color(red: 1.0, green: 0.95, blue: 0.90, opacity: 0.38),
                paletteHighlight: Color.white.opacity(0.48),
                keycapTint: Color.white.opacity(0.20)
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
                searchInnerTint: Color(red: 0.28, green: 0.20, blue: 0.15, opacity: 0.20),
                searchOuterTint: Color(red: 0.18, green: 0.13, blue: 0.10, opacity: 0.16),
                infoTint: Color(red: 0.29, green: 0.20, blue: 0.15, opacity: 0.14),
                previewCanvasTint: Color(red: 0.30, green: 0.22, blue: 0.17, opacity: 0.18),
                paletteTint: Color(red: 0.31, green: 0.22, blue: 0.17, opacity: 0.22),
                paletteHighlight: Color(red: 1.0, green: 0.88, blue: 0.78, opacity: 0.12),
                keycapTint: Color.white.opacity(0.10)
            )
        }
    }
}
