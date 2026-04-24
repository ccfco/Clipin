import AppKit

/// Markdown 语法高亮器：用 NSLayoutManager 临时属性实现，不修改 NSTextStorage。
/// 150ms debounce 触发，零副作用。
final class MarkdownSyntaxHighlighter {

    private weak var layoutManager: NSLayoutManager?
    private var highlightTimer: DispatchSourceTimer?

    init(layoutManager: NSLayoutManager) {
        self.layoutManager = layoutManager
    }

    func contentDidChange() {
        scheduleHighlight()
    }

    private func scheduleHighlight() {
        highlightTimer?.cancel()
        highlightTimer = nil

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(deadline: .now() + .milliseconds(150))
        timer.setEventHandler { [weak self] in
            self?.applyHighlight()
        }
        timer.resume()
        highlightTimer = timer
    }

    private func applyHighlight() {
        highlightTimer = nil
        guard let layoutManager,
              let textStorage = layoutManager.textStorage,
              textStorage.length > 0 else { return }

        let fullRange = NSRange(location: 0, length: textStorage.length)
        layoutManager.setTemporaryAttributes([:], forCharacterRange: fullRange)

        let lines = textStorage.string.components(separatedBy: .newlines)
        var charOffset = 0
        for line in lines {
            highlightLine(line, range: NSRange(location: charOffset, length: line.utf16.count), layoutManager: layoutManager)
            charOffset += line.utf16.count + 1
        }
    }

    private func highlightLine(_ line: String, range: NSRange, layoutManager: NSLayoutManager) {
        let stripped = line.trimmingCharacters(in: .whitespaces)

        if let heading = parseHeading(stripped), heading.level + 1 <= range.length {
            let markerLen = heading.level + 1
            layoutManager.setTemporaryAttributes([.foregroundColor: Self.markerColor], forCharacterRange: NSRange(location: range.location, length: markerLen))
            let textRange = NSRange(location: range.location + markerLen, length: range.length - markerLen)
            if textRange.length > 0 {
                layoutManager.setTemporaryAttributes([.font: Self.headingFonts[heading.level]], forCharacterRange: textRange)
            }
            return
        }

        if line.hasPrefix("> ") || line.hasPrefix(">") {
            let markerLen = line.hasPrefix("> ") ? 2 : 1
            if markerLen <= range.length {
                layoutManager.setTemporaryAttributes([.foregroundColor: Self.markerColor], forCharacterRange: NSRange(location: range.location, length: markerLen))
                let textRange = NSRange(location: range.location + markerLen, length: max(0, range.length - markerLen))
                if textRange.length > 0 {
                    layoutManager.setTemporaryAttributes([.foregroundColor: Self.blockquoteColor], forCharacterRange: textRange)
                }
            }
            return
        }

        if let (_, markerLen) = listMarkerLength(of: stripped), markerLen <= range.length {
            layoutManager.setTemporaryAttributes([.foregroundColor: Self.markerColor], forCharacterRange: NSRange(location: range.location, length: markerLen))
        }

        highlightInline(line, baseOffset: range.location, layoutManager: layoutManager, range: range)
    }

    private func highlightInline(_ line: String, baseOffset: Int, layoutManager: NSLayoutManager, range: NSRange) {
        for m in Self.codeRe.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
            let clipped = NSIntersectionRange(NSRange(location: baseOffset + m.range(at: 1).location, length: m.range(at: 1).length), range)
            if clipped.length > 0 {
                layoutManager.setTemporaryAttributes([.font: Self.codeFont, .backgroundColor: Self.codeBackground], forCharacterRange: clipped)
            }
        }
        for m in Self.boldRe.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
            let clipped = NSIntersectionRange(NSRange(location: baseOffset + m.range(at: 1).location, length: m.range(at: 1).length), range)
            if clipped.length > 0 {
                layoutManager.setTemporaryAttributes([.font: Self.boldFont], forCharacterRange: clipped)
            }
        }
    }

    // MARK: - Helpers

    private struct Heading { var level: Int }
    private func parseHeading(_ line: String) -> Heading? {
        var level = 0, i = line.startIndex
        while i < line.endIndex && line[i] == "#" && level < 6 { level += 1; i = line.index(after: i) }
        guard level > 0, i < line.endIndex, line[i] == " " else { return nil }
        return Heading(level: level)
    }

    private func listMarkerLength(of line: String) -> (type: String, length: Int)? {
        if line.hasPrefix("- ") { return ("ul", 2) }
        if line.hasPrefix("* ") { return ("ul", 2) }
        if line.hasPrefix("+ ") { return ("ul", 2) }
        let olRe = try! NSRegularExpression(pattern: #"^\d+\.\s"#)
        if let m = olRe.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
            return ("ol", m.range.length)
        }
        return nil
    }

    // MARK: - 缓存样式

    private static var markerColor: NSColor { NSColor(white: 0.4, alpha: 0.4) }
    private static var codeBackground: NSColor { NSColor(white: 0.0, alpha: 0.06) }
    private static var blockquoteColor: NSColor { NSColor(white: 0.0, alpha: 0.5) }
    private static var codeFont: NSFont { NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) }
    private static var boldFont: NSFont { NSFont.systemFont(ofSize: 14, weight: .bold) }
    private static var headingFonts: [Int: NSFont] { [
        1: .systemFont(ofSize: 22, weight: .semibold),
        2: .systemFont(ofSize: 18, weight: .semibold),
        3: .systemFont(ofSize: 16, weight: .semibold),
        4: .systemFont(ofSize: 15, weight: .semibold),
        5: .systemFont(ofSize: 14, weight: .semibold),
        6: .systemFont(ofSize: 13, weight: .semibold),
    ] }

    private static let codeRe = try! NSRegularExpression(pattern: #"`([^`]+)`"#)
    private static let boldRe = try! NSRegularExpression(pattern: #"\*\*(.+?)\*\*"#)
}
