import AppKit

/// WYSIWYM Markdown → NSAttributedString 转换器。
/// 将 Markdown 转为可编辑的富文本，不含语法标记。
/// 用户只看到渲染后的效果（粗体、斜体等），保存时从属性还原 Markdown。
enum MarkdownWysiwygRenderer {

    // MARK: - 样式常量

    private static func bodyFont() -> NSFont { NSFont.systemFont(ofSize: 14, weight: .regular) }
    private static func codeFont() -> NSFont { NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) }
    private static func headingFont(level: Int) -> NSFont {
        let sizes: [Int: CGFloat] = [1: 22, 2: 18, 3: 16, 4: 15, 5: 14, 6: 13]
        return NSFont.systemFont(ofSize: sizes[level] ?? 14, weight: .semibold)
    }
    private static func markerColor(_ appearance: NSAppearance? = nil) -> NSColor {
        appearance?.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.65, alpha: 0.45)
            : NSColor(white: 0.25, alpha: 0.45)
    }
    private static func codeBackground(_ appearance: NSAppearance? = nil) -> NSColor {
        appearance?.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1.0, alpha: 0.12)
            : NSColor(white: 0.0, alpha: 0.08)
    }
    private static func codeBlockBackground(_ appearance: NSAppearance? = nil) -> NSColor {
        appearance?.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1.0, alpha: 0.08)
            : NSColor(white: 0.0, alpha: 0.04)
    }
    private static func blockquoteColor(_ appearance: NSAppearance? = nil) -> NSColor {
        appearance?.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.7, alpha: 0.75)
            : NSColor(white: 0.0, alpha: 0.55)
    }

    // MARK: - 渲染：Markdown → NSAttributedString

    static func render(from markdown: String, appearance: NSAppearance? = nil) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let lines = markdown.components(separatedBy: .newlines)
        var i = 0
        var inCodeBlock = false
        var codeBlockLines: [String] = []

        while i < lines.count {
            let line = lines[i]
            if inCodeBlock {
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    result.append(styledCodeBlock(codeBlockLines.joined(separator: "\n"), appearance: appearance))
                    result.append(NSAttributedString(string: "\n"))
                    codeBlockLines.removeAll()
                    inCodeBlock = false
                    i += 1
                    continue
                }
                codeBlockLines.append(line)
                i += 1
                continue
            }
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inCodeBlock = true
                i += 1
                continue
            }
            result.append(styledLine(line, appearance: appearance))
            result.append(NSAttributedString(string: "\n"))
            i += 1
        }
        if inCodeBlock && !codeBlockLines.isEmpty {
            result.append(styledCodeBlock(codeBlockLines.joined(separator: "\n"), appearance: appearance))
            result.append(NSAttributedString(string: "\n"))
        }
        if result.length > 1, result.string.hasSuffix("\n") {
            result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1))
        }
        return result
    }

    // MARK: - 块级样式

    private static func styledLine(_ line: String, appearance: NSAppearance?) -> NSAttributedString {
        let stripped = line.trimmingCharacters(in: .whitespaces)
        if let heading = parseHeading(stripped) {
            return NSAttributedString(string: heading.text, attributes: [
                .font: headingFont(level: heading.level),
                .foregroundColor: NSColor.labelColor,
            ])
        }
        if line.hasPrefix(">") {
            let content = line.hasPrefix("> ") ? String(line.dropFirst(2)) : String(line.dropFirst(1))
            return NSAttributedString(string: content, attributes: [
                .font: bodyFont(),
                .foregroundColor: blockquoteColor(appearance),
            ])
        }
        if let item = parseListItem(stripped) {
            return styledInline(item, appearance: appearance)
        }
        if isHR(stripped) {
            return NSAttributedString(string: "───", attributes: [
                .foregroundColor: markerColor(appearance),
            ])
        }
        return styledInline(line, appearance: appearance)
    }

    private static func styledCodeBlock(_ content: String, appearance: NSAppearance?) -> NSAttributedString {
        NSAttributedString(string: content, attributes: [
            .font: codeFont(),
            .foregroundColor: blockquoteColor(appearance),
            .backgroundColor: codeBlockBackground(appearance),
        ])
    }

    // MARK: - 行内样式

    private static func styledInline(_ text: String, appearance: NSAppearance?) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for segment in tokenizeInline(text) {
            switch segment {
            case .bold(let inner):
                result.append(NSAttributedString(string: inner, attributes: [
                    .font: NSFont.systemFont(ofSize: 14, weight: .bold),
                    .foregroundColor: NSColor.labelColor,
                ]))
            case .italic(let inner):
                result.append(NSAttributedString(string: inner, attributes: [
                    .font: NSFont.systemFont(ofSize: 14, weight: .regular).withTraits(italic: true),
                    .foregroundColor: NSColor.labelColor,
                ]))
            case .boldItalic(let inner):
                result.append(NSAttributedString(string: inner, attributes: [
                    .font: NSFont.systemFont(ofSize: 14, weight: .bold).withTraits(italic: true),
                    .foregroundColor: NSColor.labelColor,
                ]))
            case .code(let inner):
                result.append(NSAttributedString(string: inner, attributes: [
                    .font: codeFont(),
                    .foregroundColor: NSColor.labelColor,
                    .backgroundColor: codeBackground(appearance),
                ]))
            case .link(let linkText, _):
                result.append(NSAttributedString(string: linkText, attributes: [
                    .font: bodyFont(),
                    .foregroundColor: NSColor.systemBlue,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                ]))
            case .plain(let p):
                result.append(NSAttributedString(string: p, attributes: [
                    .font: bodyFont(),
                    .foregroundColor: NSColor.labelColor,
                ]))
            }
        }
        return result
    }

    // MARK: - 解析

    private enum InlineSegment {
        case bold(String), italic(String), boldItalic(String), code(String), link(String, String), plain(String)
    }

    private static func tokenizeInline(_ text: String) -> [InlineSegment] {
        var segments: [(range: NSRange, type: InlineSegment)] = []

        let codeRe = try! NSRegularExpression(pattern: #"`([^`]+)`"#)
        for m in codeRe.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            segments.append((m.range, .code((text as NSString).substring(with: m.range(at: 1)))))
        }
        let linkRe = try! NSRegularExpression(pattern: #"\[([^\]]+)\]\(([^)]+)\)"#)
        for m in linkRe.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let t = (text as NSString).substring(with: m.range(at: 1))
            let u = (text as NSString).substring(with: m.range(at: 2))
            segments.append((m.range, .link(t, u)))
        }
        let boldItalicRe = try! NSRegularExpression(pattern: #"\*\*\*(.+?)\*\*\*"#)
        for m in boldItalicRe.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            if !overlapsAny(m.range, with: segments.map(\.range)) {
                segments.append((m.range, .boldItalic((text as NSString).substring(with: m.range(at: 1)))))
            }
        }
        let boldRe = try! NSRegularExpression(pattern: #"\*\*(.+?)\*\*"#)
        for m in boldRe.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            if !overlapsAny(m.range, with: segments.map(\.range)) {
                segments.append((m.range, .bold((text as NSString).substring(with: m.range(at: 1)))))
            }
        }
        let italicRe = try! NSRegularExpression(pattern: #"(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)"#)
        for m in italicRe.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            if !overlapsAny(m.range, with: segments.map(\.range)) {
                segments.append((m.range, .italic((text as NSString).substring(with: m.range(at: 1)))))
            }
        }

        segments.sort { $0.range.location < $1.range.location }
        var result: [InlineSegment] = []
        var pos = 0
        let nsText = text as NSString
        for seg in segments {
            if seg.range.location > pos {
                result.append(.plain(nsText.substring(with: NSRange(location: pos, length: seg.range.location - pos))))
            }
            result.append(seg.type)
            pos = seg.range.location + seg.range.length
        }
        if pos < nsText.length {
            result.append(.plain(nsText.substring(with: NSRange(location: pos, length: nsText.length - pos))))
        }
        return result
    }

    private static func overlapsAny(_ range: NSRange, with ranges: [NSRange]) -> Bool {
        ranges.contains { NSIntersectionRange(range, $0).length > 0 }
    }

    private struct Heading { var level: Int; var text: String }
    private static func parseHeading(_ line: String) -> Heading? {
        var level = 0, i = line.startIndex
        while i < line.endIndex && line[i] == "#" && level < 6 { level += 1; i = line.index(after: i) }
        guard level > 0, i < line.endIndex, line[i] == " " else { return nil }
        return Heading(level: level, text: String(line[line.index(after: i)...]).trimmingCharacters(in: .whitespaces))
    }
    private static func parseListItem(_ line: String) -> String? {
        if line.hasPrefix("- ") { return String(line.dropFirst(2)) }
        if line.hasPrefix("* ") { return String(line.dropFirst(2)) }
        if line.hasPrefix("+ ") { return String(line.dropFirst(2)) }
        let olRe = try! NSRegularExpression(pattern: #"^\d+\.\s+(.+)"#)
        if let m = olRe.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
           let r = Range(m.range(at: 1), in: line) { return String(line[r]) }
        return nil
    }
    private static func isHR(_ s: String) -> Bool {
        let c = s.filter { !$0.isWhitespace }
        return c.count >= 3 && (c.allSatisfy { $0 == "-" } || c.allSatisfy { $0 == "*" } || c.allSatisfy { $0 == "_" })
    }

    // MARK: - 反向还原：NSAttributedString → Markdown

    static func reconstructMarkdown(from attributedString: NSAttributedString) -> String {
        guard attributedString.length > 0 else { return "" }
        var output = ""
        var i = 0
        let fullRange = NSRange(location: 0, length: attributedString.length)
        var effectiveRange = NSRange()
        while i < attributedString.length {
            let attrs = attributedString.attributes(at: i, effectiveRange: &effectiveRange)
            let charRange = NSIntersectionRange(effectiveRange, fullRange)
            let text = attributedString.attributedSubstring(from: charRange).string
            i = charRange.location + charRange.length

            let isBold = isBoldAttribute(attrs)
            let isItalic = isItalicAttribute(attrs)
            let isCode = isCodeAttribute(attrs)
            let isLink = attrs[.link] != nil

            if isCode && !text.isEmpty {
                output += "`\(text)`"
            } else if isBold && isItalic && !text.isEmpty {
                output += "***\(text)***"
            } else if isBold && !text.isEmpty {
                output += "**\(text)**"
            } else if isItalic && !text.isEmpty {
                output += "*\(text)*"
            } else if isLink && !text.isEmpty {
                output += "[\(text)](\(urlFromAttrs(attrs) ?? "#"))"
            } else {
                output += text
            }
        }
        return output
    }

    private static func isBoldAttribute(_ attrs: [NSAttributedString.Key: Any]) -> Bool {
        guard let font = attrs[.font] as? NSFont else { return false }
        return font.fontDescriptor.symbolicTraits.contains(.bold)
    }
    private static func isItalicAttribute(_ attrs: [NSAttributedString.Key: Any]) -> Bool {
        guard let font = attrs[.font] as? NSFont else { return false }
        return font.fontDescriptor.symbolicTraits.contains(.italic)
    }
    private static func isCodeAttribute(_ attrs: [NSAttributedString.Key: Any]) -> Bool {
        guard let font = attrs[.font] as? NSFont else { return false }
        return font.fontDescriptor.object(forKey: .family) as? String == "SF Mono"
    }
    private static func urlFromAttrs(_ attrs: [NSAttributedString.Key: Any]) -> String? {
        if let url = attrs[.link] as? String { return url }
        if let url = attrs[.link] as? URL { return url.absoluteString }
        return nil
    }
}

// MARK: - NSFont 扩展

extension NSFont {
    func withTraits(italic: Bool) -> NSFont {
        let descriptor = fontDescriptor.withSymbolicTraits(italic ? .italic : [])
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}
