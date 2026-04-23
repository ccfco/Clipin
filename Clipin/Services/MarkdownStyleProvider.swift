import AppKit

/// Markdown WYSIWYM 样式常量与颜色提供者。
/// 所有样式集中管理，方便统一调整和暗色模式适配。
enum MarkdownStyleProvider {

    // MARK: - 字体

    static var bodyFont: NSFont { NSFont.systemFont(ofSize: 14, weight: .regular) }
    static var codeFont: NSFont { NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) }

    static func headingFont(level: Int) -> NSFont {
        let sizes: [Int: CGFloat] = [1: 22, 2: 18, 3: 16, 4: 15, 5: 14, 6: 13]
        let size = sizes[level] ?? 14
        return NSFont.systemFont(ofSize: size, weight: .semibold)
    }

    // MARK: - 标记颜色（暗色/亮色自动适配）

    /// Markdown 标记符号（`#`, `**`, `` ` `` 等）的颜色 —— 低透明度
    static func markerColor(for appearance: NSAppearance? = nil) -> NSColor {
        if appearance?.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(white: 0.65, alpha: 0.45)
        }
        return NSColor(white: 0.25, alpha: 0.45)
    }

    /// 行内代码背景色
    static func codeBackground(for appearance: NSAppearance? = nil) -> NSColor {
        if appearance?.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(white: 1.0, alpha: 0.12)
        }
        return NSColor(white: 0.0, alpha: 0.08)
    }

    /// 围栏代码块背景色
    static func codeBlockBackground(for appearance: NSAppearance? = nil) -> NSColor {
        if appearance?.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(white: 1.0, alpha: 0.08)
        }
        return NSColor(white: 0.0, alpha: 0.04)
    }

    /// 链接颜色
    static func linkColor(for appearance: NSAppearance? = nil) -> NSColor {
        if appearance?.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor.systemBlue
        }
        return NSColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 1.0)
    }

    /// 引用块文字颜色
    static func blockquoteColor(for appearance: NSAppearance? = nil) -> NSColor {
        if appearance?.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(white: 0.7, alpha: 0.75)
        }
        return NSColor(white: 0.0, alpha: 0.55)
    }

    // MARK: - 段落样式

    /// 代码块段落样式（左右缩进）
    static func codeBlockParagraphStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = 8
        style.headIndent = 8
        style.lineSpacing = 2
        return style
    }

    /// 引用块段落样式
    static func blockquoteParagraphStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = 12
        style.headIndent = 12
        return style
    }
}
