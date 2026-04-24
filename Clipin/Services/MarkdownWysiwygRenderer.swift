import AppKit

/// Markdown WYSIWYM 双向转换器。
/// render: Markdown → NSAttributedString（不含语法标记，带块级属性）
/// reconstructMarkdown: NSAttributedString → Markdown（从属性和块标记还原）
enum MarkdownWysiwygRenderer {

    // MARK: - 自定义 Attribute Key

    /// 附加到每行字符上的块级标记（用于保存时还原 Markdown 语法）
    static let blockTypeKey = NSAttributedString.Key("markdown.blockType")
    /// 行内类型标记（code, link）
    static let inlineTypeKey = NSAttributedString.Key("markdown.inlineType")

    enum BlockType: String {
        case heading1, heading2, heading3, heading4, heading5, heading6
        case blockquote
        case unorderedList
        case orderedList
        case codeBlock
        case hr
        case paragraph
    }

    enum InlineType: String {
        case code, link
    }

    // MARK: - 样式常量

    private static func bodyFont() -> NSFont { NSFont.systemFont(ofSize: 14, weight: .regular) }
    private static func codeFont() -> NSFont { NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) }
    private static func headingFont(level: Int) -> NSFont {
        let sizes: [Int: CGFloat] = [1: 22, 2: 18, 3: 16, 4: 15, 5: 14, 6: 13]
        return NSFont.systemFont(ofSize: sizes[level] ?? 14, weight: .semibold)
    }
    private static func markerColor(_ appearance: NSAppearance? = nil) -> NSColor {
        appearance?.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.65, alpha: 0.45) : NSColor(white: 0.25, alpha: 0.45)
    }
    private static func codeBackground(_ appearance: NSAppearance? = nil) -> NSColor {
        appearance?.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1.0, alpha: 0.12) : NSColor(white: 0.0, alpha: 0.08)
    }
    private static func codeBlockBackground(_ appearance: NSAppearance? = nil) -> NSColor {
        appearance?.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1.0, alpha: 0.08) : NSColor(white: 0.0, alpha: 0.04)
    }
    private static func blockquoteColor(_ appearance: NSAppearance? = nil) -> NSColor {
        appearance?.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.7, alpha: 0.75) : NSColor(white: 0.0, alpha: 0.55)
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
            let typeKey = blockTypeKey
            let blockType: BlockType
            switch heading.level {
            case 1: blockType = .heading1
            case 2: blockType = .heading2
            case 3: blockType = .heading3
            case 4: blockType = .heading4
            case 5: blockType = .heading5
            default: blockType = .heading6
            }
            return NSAttributedString(string: heading.text, attributes: [
                .font: headingFont(level: heading.level),
                .foregroundColor: NSColor.labelColor,
                typeKey: blockType.rawValue,
            ])
        }

        if line.hasPrefix(">") {
            let content = line.hasPrefix("> ") ? String(line.dropFirst(2)) : String(line.dropFirst(1))
            return NSAttributedString(string: content, attributes: [
                .font: bodyFont(),
                .foregroundColor: blockquoteColor(appearance),
                blockTypeKey: BlockType.blockquote.rawValue,
            ])
        }

        if let (type, item) = parseListItem(stripped) {
            return styledInline(item, appearance: appearance, extraAttrs: [
                blockTypeKey: type == "ul" ? BlockType.unorderedList.rawValue : BlockType.orderedList.rawValue
            ])
        }

        if isHR(stripped) {
            return NSAttributedString(string: "───", attributes: [
                .foregroundColor: markerColor(appearance),
                blockTypeKey: BlockType.hr.rawValue,
            ])
        }

        // 普通段落
        return styledInline(line, appearance: appearance, extraAttrs: [
            blockTypeKey: BlockType.paragraph.rawValue,
        ])
    }

    private static func styledCodeBlock(_ content: String, appearance: NSAppearance?) -> NSAttributedString {
        NSAttributedString(string: content, attributes: [
            .font: codeFont(),
            .foregroundColor: blockquoteColor(appearance),
            .backgroundColor: codeBlockBackground(appearance),
            blockTypeKey: BlockType.codeBlock.rawValue,
        ])
    }

    // MARK: - 行内样式

    private static func styledInline(_ text: String, appearance: NSAppearance?, extraAttrs: [NSAttributedString.Key: Any] = [:]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for segment in tokenizeInline(text) {
            var attrs: [NSAttributedString.Key: Any] = [:]
            switch segment {
            case .bold(let inner):
                attrs[.font] = NSFont.systemFont(ofSize: 14, weight: .bold)
                attrs[.foregroundColor] = NSColor.labelColor
                result.append(NSAttributedString(string: inner, attributes: attrs))
            case .italic(let inner):
                attrs[.font] = NSFont.systemFont(ofSize: 14, weight: .regular).withTraits(italic: true)
                attrs[.foregroundColor] = NSColor.labelColor
                result.append(NSAttributedString(string: inner, attributes: attrs))
            case .boldItalic(let inner):
                attrs[.font] = NSFont.systemFont(ofSize: 14, weight: .bold).withTraits(italic: true)
                attrs[.foregroundColor] = NSColor.labelColor
                result.append(NSAttributedString(string: inner, attributes: attrs))
            case .code(let inner):
                attrs[.font] = codeFont()
                attrs[.foregroundColor] = NSColor.labelColor
                attrs[.backgroundColor] = codeBackground(appearance)
                attrs[inlineTypeKey] = InlineType.code.rawValue
                result.append(NSAttributedString(string: inner, attributes: attrs))
            case .link(let linkText, let url):
                attrs[.font] = bodyFont()
                attrs[.foregroundColor] = NSColor.systemBlue
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                attrs[.link] = url
                attrs[inlineTypeKey] = InlineType.link.rawValue
                result.append(NSAttributedString(string: linkText, attributes: attrs))
            case .plain(let p):
                attrs[.font] = bodyFont()
                attrs[.foregroundColor] = NSColor.labelColor
                result.append(NSAttributedString(string: p, attributes: attrs))
            }
        }
        // 对整个行应用块级标记
        if result.length > 0 {
            for (k, v) in extraAttrs {
                result.addAttribute(k, value: v, range: NSRange(location: 0, length: result.length))
            }
        }
        return result
    }

    // MARK: - 解析

    private enum InlineSegment {
        case bold(String), italic(String), boldItalic(String), code(String), link(String, String), plain(String)
        var string: String? {
            switch self {
            case .bold(let s), .italic(let s), .boldItalic(let s), .code(let s), .link(let s, _): return s
            case .plain(let s): return s
            }
        }
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
    private static func parseListItem(_ line: String) -> (type: String, text: String)? {
        if line.hasPrefix("- ") { return ("ul", String(line.dropFirst(2))) }
        if line.hasPrefix("* ") { return ("ul", String(line.dropFirst(2))) }
        if line.hasPrefix("+ ") { return ("ul", String(line.dropFirst(2))) }
        let olRe = try! NSRegularExpression(pattern: #"^(\d+)\.\s+(.+)"#)
        if let m = olRe.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
           let r = Range(m.range(at: 2), in: line) {
            return ("ol", String(line[r]))
        }
        return nil
    }
    private static func isHR(_ s: String) -> Bool {
        let c = s.filter { !$0.isWhitespace }
        return c.count >= 3 && (c.allSatisfy { $0 == "-" } || c.allSatisfy { $0 == "*" } || c.allSatisfy { $0 == "_" })
    }

    // MARK: - 反向还原：NSAttributedString → Markdown

    static func reconstructMarkdown(from attributedString: NSAttributedString) -> String {
        guard attributedString.length > 0 else { return "" }

        let fullString = attributedString.string
        var lines: [NSAttributedString] = []
        var lineStart = 0

        // 用 String 的 UTF-16 索引找到换行位置
        let utf16 = fullString.utf16
        var utf16Index = 0
        for char in utf16 {
            if char == 0x0A {
                // 找到换行，提取这一行的 attributed substring
                let range = NSRange(location: lineStart, length: utf16Index - lineStart)
                if range.length > 0 {
                    lines.append(attributedString.attributedSubstring(from: range))
                }
                lineStart = utf16Index + 1
            }
            utf16Index += 1
        }
        // 最后一行（如果没有尾随换行）
        if lineStart < attributedString.length {
            lines.append(attributedString.attributedSubstring(from: NSRange(location: lineStart, length: attributedString.length - lineStart)))
        }

        var output: [String] = []
        for line in lines {
            let text = line.string
            if text.isEmpty { output.append(""); continue }

            let blockTypeRaw = line.attribute(blockTypeKey, at: 0, effectiveRange: nil) as? String
            let blockType = BlockType(rawValue: blockTypeRaw ?? "")

            var prefix = ""
            switch blockType {
            case .heading1: prefix = "# "
            case .heading2: prefix = "## "
            case .heading3: prefix = "### "
            case .heading4: prefix = "#### "
            case .heading5: prefix = "##### "
            case .heading6: prefix = "###### "
            case .blockquote: prefix = "> "
            case .unorderedList: prefix = "- "
            case .orderedList: prefix = "1. "
            case .hr:
                output.append("---")
                continue
            case .codeBlock:
                output.append(text)
                continue
            case .paragraph, nil:
                break
            }

            let body = reconstructInline(from: line)
            output.append(prefix + body)
        }

        return output.joined(separator: "\n")
    }

    private static func reconstructInline(from line: NSAttributedString) -> String {
        var output = ""
        var i = 0
        var effectiveRange = NSRange()

        while i < line.length {
            let attrs = line.attributes(at: i, effectiveRange: &effectiveRange)
            let segRange = NSIntersectionRange(effectiveRange, NSRange(location: 0, length: line.length))
            let text = line.attributedSubstring(from: segRange).string
            i = segRange.location + segRange.length

            let isBold = isBoldAttribute(attrs)
            let isItalic = isItalicAttribute(attrs)
            let isCode = attrs[inlineTypeKey] as? String == InlineType.code.rawValue
            let isLink = attrs[inlineTypeKey] as? String == InlineType.link.rawValue

            if isCode && !text.isEmpty {
                output += "`\(text)`"
            } else if isBold && isItalic && !text.isEmpty {
                output += "***\(text)***"
            } else if isBold && !text.isEmpty {
                output += "**\(text)**"
            } else if isItalic && !text.isEmpty {
                output += "*\(text)*"
            } else if isLink && !text.isEmpty {
                if let url = attrs[.link] as? String {
                    output += "[\(text)](\(url))"
                } else if let url = attrs[.link] as? URL {
                    output += "[\(text)](\(url.absoluteString))"
                } else {
                    output += text
                }
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
}

// MARK: - NSFont 扩展

extension NSFont {
    func withTraits(italic: Bool) -> NSFont {
        let descriptor = fontDescriptor.withSymbolicTraits(italic ? .italic : [])
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}
