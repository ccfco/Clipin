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

        // 清除旧高亮
        layoutManager.setTemporaryAttributes([:], forCharacterRange: fullRange)

        // 逐行高亮
        let text = textStorage.string
        let lines = text.components(separatedBy: .newlines)
        var charOffset = 0

        for line in lines {
            let lineRange = NSRange(location: charOffset, length: line.utf16.count)
            highlightLine(line, range: lineRange, layoutManager: layoutManager)
            charOffset += line.utf16.count + 1
        }
    }

    private func highlightLine(_ line: String, range: NSRange, layoutManager: NSLayoutManager) {
        let stripped = line.trimmingCharacters(in: .whitespaces)

        // 标题
        if let heading = parseHeading(stripped) {
            let markerLen = heading.level + 1
            if markerLen <= range.length {
                let markerRange = NSRange(location: range.location, length: markerLen)
                layoutManager.setTemporaryAttributes([.foregroundColor: markerColor()], forCharacterRange: markerRange)
                let textRange = NSRange(location: range.location + markerLen, length: range.length - markerLen)
                if textRange.length > 0 {
                    layoutManager.setTemporaryAttributes([.font: headingFont(level: heading.level)], forCharacterRange: textRange)
                }
            }
            return
        }

        // 引用
        if line.hasPrefix("> ") || line.hasPrefix(">") {
            let markerLen = line.hasPrefix("> ") ? 2 : 1
            if markerLen <= range.length {
                layoutManager.setTemporaryAttributes([.foregroundColor: markerColor()], forCharacterRange: NSRange(location: range.location, length: markerLen))
                let textRange = NSRange(location: range.location + markerLen, length: max(0, range.length - markerLen))
                if textRange.length > 0 {
                    layoutManager.setTemporaryAttributes([.foregroundColor: blockquoteColor()], forCharacterRange: textRange)
                }
            }
            return
        }

        // 列表标记
        if let (_, markerLen) = listMarkerLength(of: stripped) {
            if markerLen <= range.length {
                layoutManager.setTemporaryAttributes([.foregroundColor: markerColor()], forCharacterRange: NSRange(location: range.location, length: markerLen))
            }
        }

        // 行内样式
        highlightInline(line, baseOffset: range.location, layoutManager: layoutManager, range: range)
    }

    private func highlightInline(_ line: String, baseOffset: Int, layoutManager: NSLayoutManager, range: NSRange) {
        // 行内代码 ``
        let codeRe = try! NSRegularExpression(pattern: #"`([^`]+)`"#)
        for m in codeRe.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
            let innerRange = m.range(at: 1)
            let absRange = NSRange(location: baseOffset + innerRange.location, length: innerRange.length)
            let clipped = NSIntersectionRange(absRange, range)
            if clipped.length > 0 {
                layoutManager.setTemporaryAttributes([
                    .font: codeFont(),
                    .backgroundColor: codeBackground(),
                ], forCharacterRange: clipped)
            }
        }

        // 粗体 **text**
        let boldRe = try! NSRegularExpression(pattern: #"\*\*(.+?)\*\*"#)
        for m in boldRe.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
            let innerRange = m.range(at: 1)
            let absRange = NSRange(location: baseOffset + innerRange.location, length: innerRange.length)
            let clipped = NSIntersectionRange(absRange, range)
            if clipped.length > 0 {
                layoutManager.setTemporaryAttributes([.font: NSFont.systemFont(ofSize: 14, weight: .bold)], forCharacterRange: clipped)
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

    // MARK: - 样式

    private func markerColor() -> NSColor { NSColor(white: 0.4, alpha: 0.4) }
    private func codeBackground() -> NSColor { NSColor(white: 0.0, alpha: 0.06) }
    private func blockquoteColor() -> NSColor { NSColor(white: 0.0, alpha: 0.5) }
    private func codeFont() -> NSFont { NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) }
    private func headingFont(level: Int) -> NSFont {
        let sizes: [Int: CGFloat] = [1: 22, 2: 18, 3: 16, 4: 15, 5: 14, 6: 13]
        return NSFont.systemFont(ofSize: sizes[level] ?? 14, weight: .semibold)
    }
}
