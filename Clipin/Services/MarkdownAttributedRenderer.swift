import AppKit

/// 将 Markdown 文本转为带样式的 NSAttributedString（所见即所得编辑用）。
/// 存储格式仍为纯 Markdown，只是在编辑时视觉上接近渲染效果。
enum MarkdownAttributedRenderer {

    /// 将完整 Markdown 字符串转为带样式的 AttributedString
    static func render(_ markdown: String, appearance: NSAppearance? = nil) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let lines = markdown.components(separatedBy: .newlines)
        var i = 0
        var inCodeBlock = false
        var codeBlockLines: [String] = []

        while i < lines.count {
            let line = lines[i]

            if inCodeBlock {
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    // 结束代码块
                    let block = codeBlockLines.joined(separator: "\n")
                    result.append(styledCodeBlock(block, appearance: appearance))
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

            // 围栏代码块开始
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inCodeBlock = true
                i += 1
                continue
            }

            let styled = styledLine(line, appearance: appearance)
            result.append(styled)
            result.append(NSAttributedString(string: "\n"))
            i += 1
        }

        // 如果文件以未关闭的代码块结尾
        if inCodeBlock && !codeBlockLines.isEmpty {
            result.append(styledCodeBlock(codeBlockLines.joined(separator: "\n"), appearance: appearance))
            result.append(NSAttributedString(string: "\n"))
        }

        // 去掉末尾多余的换行
        if result.length > 1, result.string.hasSuffix("\n") {
            result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1))
        }

        return result
    }

    // MARK: - 块级样式

    private static func styledLine(_ line: String, appearance: NSAppearance?) -> NSAttributedString {
        let stripped = line.trimmingCharacters(in: .whitespaces)

        // 标题
        if let heading = parseHeading(stripped) {
            return styledHeading(text: heading.text, level: heading.level, fullLine: line, appearance: appearance)
        }

        // 引用块
        if line.hasPrefix(">") {
            return styledBlockquote(line, appearance: appearance)
        }

        // 无序列表
        if let item = parseListItem(stripped) {
            return styledListItem(item, marker: itemMarker(of: stripped), appearance: appearance)
        }

        // 分割线
        if isHR(stripped) {
            return styledHR(appearance: appearance)
        }

        // 普通行 — 应用行内样式
        return styledInline(line, appearance: appearance)
    }

    private static func styledCodeBlock(_ content: String, appearance: NSAppearance?) -> NSAttributedString {
        let result = NSMutableAttributedString()
        result.append(NSAttributedString(string: content, attributes: [
            .font: MarkdownStyleProvider.codeFont,
            .foregroundColor: MarkdownStyleProvider.blockquoteColor(for: appearance),
            .backgroundColor: MarkdownStyleProvider.codeBlockBackground(for: appearance),
            .paragraphStyle: MarkdownStyleProvider.codeBlockParagraphStyle(),
        ]))
        return result
    }

    private static func styledBlockquote(_ line: String, appearance: NSAppearance?) -> NSAttributedString {
        let marker: String
        let content: String
        if line.hasPrefix("> ") {
            marker = "> "
            content = String(line.dropFirst(2))
        } else if line.hasPrefix(">") {
            marker = ">"
            content = String(line.dropFirst(1))
        } else {
            marker = ""
            content = line
        }

        let result = NSMutableAttributedString()
        let markerAttr = NSAttributedString(string: marker, attributes: [
            .font: MarkdownStyleProvider.bodyFont,
            .foregroundColor: MarkdownStyleProvider.markerColor(for: appearance),
        ])
        result.append(markerAttr)
        let contentAttr = NSAttributedString(string: content, attributes: [
            .font: MarkdownStyleProvider.bodyFont,
            .foregroundColor: MarkdownStyleProvider.blockquoteColor(for: appearance),
            .paragraphStyle: MarkdownStyleProvider.blockquoteParagraphStyle(),
        ])
        result.append(contentAttr)
        return result
    }

    private static func styledHeading(text: String, level: Int, fullLine: String, appearance: NSAppearance?) -> NSAttributedString {
        let marker = String(repeating: "#", count: level) + " "
        let result = NSMutableAttributedString()
        let markerAttr = NSAttributedString(string: marker, attributes: [
            .font: MarkdownStyleProvider.headingFont(level: level),
            .foregroundColor: MarkdownStyleProvider.markerColor(for: appearance),
        ])
        result.append(markerAttr)
        let contentAttr = NSAttributedString(string: text, attributes: [
            .font: MarkdownStyleProvider.headingFont(level: level),
            .foregroundColor: NSColor.labelColor,
        ])
        result.append(contentAttr)
        return result
    }

    private static func styledListItem(_ content: String, marker: String, appearance: NSAppearance?) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let markerAttr = NSAttributedString(string: marker, attributes: [
            .font: MarkdownStyleProvider.bodyFont,
            .foregroundColor: MarkdownStyleProvider.markerColor(for: appearance),
        ])
        result.append(markerAttr)
        result.append(styledInline(content, appearance: appearance))
        return result
    }

    private static func styledHR(appearance: NSAppearance?) -> NSAttributedString {
        NSAttributedString(string: "───", attributes: [
            .foregroundColor: MarkdownStyleProvider.markerColor(for: appearance),
        ])
    }

    // MARK: - 行内样式

    private static func styledInline(_ text: String, appearance: NSAppearance?) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let segments = tokenizeInline(text)

        for segment in segments {
            switch segment {
            case .marker(let m):
                result.append(NSAttributedString(string: m, attributes: [
                    .font: MarkdownStyleProvider.bodyFont,
                    .foregroundColor: MarkdownStyleProvider.markerColor(for: appearance),
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .strikethroughColor: MarkdownStyleProvider.markerColor(for: appearance),
                ]))
            case .bold(let inner):
                // bold 的标记符号 ** 需要弱化
                result.append(NSAttributedString(string: inner, attributes: [
                    .font: NSFont.systemFont(ofSize: 14, weight: .bold),
                    .foregroundColor: NSColor.labelColor,
                ]))
            case .italic(let inner):
                result.append(NSAttributedString(string: inner, attributes: [
                    .font: NSFont.systemFont(ofSize: 14, weight: .regular).withTraits(italic: true),
                    .foregroundColor: NSColor.labelColor,
                ]))
            case .code(let inner):
                result.append(NSAttributedString(string: inner, attributes: [
                    .font: MarkdownStyleProvider.codeFont,
                    .foregroundColor: NSColor.labelColor,
                    .backgroundColor: MarkdownStyleProvider.codeBackground(for: appearance),
                ]))
            case .link(let text, let url):
                let linkResult = NSMutableAttributedString()
                linkResult.append(NSAttributedString(string: "[", attributes: [
                    .font: MarkdownStyleProvider.bodyFont,
                    .foregroundColor: MarkdownStyleProvider.markerColor(for: appearance),
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .strikethroughColor: MarkdownStyleProvider.markerColor(for: appearance),
                ]))
                linkResult.append(NSAttributedString(string: text, attributes: [
                    .font: MarkdownStyleProvider.bodyFont,
                    .foregroundColor: MarkdownStyleProvider.linkColor(for: appearance),
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                ]))
                linkResult.append(NSAttributedString(string: "](", attributes: [
                    .font: MarkdownStyleProvider.bodyFont,
                    .foregroundColor: MarkdownStyleProvider.markerColor(for: appearance),
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .strikethroughColor: MarkdownStyleProvider.markerColor(for: appearance),
                ]))
                linkResult.append(NSAttributedString(string: url, attributes: [
                    .font: MarkdownStyleProvider.codeFont,
                    .foregroundColor: MarkdownStyleProvider.linkColor(for: appearance),
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                ]))
                linkResult.append(NSAttributedString(string: ")", attributes: [
                    .font: MarkdownStyleProvider.bodyFont,
                    .foregroundColor: MarkdownStyleProvider.markerColor(for: appearance),
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .strikethroughColor: MarkdownStyleProvider.markerColor(for: appearance),
                ]))
                result.append(linkResult)
            case .plain(let p):
                result.append(NSAttributedString(string: p, attributes: [
                    .font: MarkdownStyleProvider.bodyFont,
                    .foregroundColor: NSColor.labelColor,
                ]))
            }
        }

        return result
    }

    /// 行内 token 类型
    private enum InlineSegment {
        case marker(String)     // `**`, `*`, ``` 等被删除的标记
        case bold(String)       // **text** 的 text（已去标记）
        case italic(String)     // *text* 的 text
        case code(String)       // `code` 的 code
        case link(String, String) // link[text], url(url)
        case plain(String)
    }

    /// 将一行文本拆分为 inline 片段
    private static func tokenizeInline(_ text: String) -> [InlineSegment] {
        var segments: [(range: NSRange, type: InlineSegment)] = []

        // 1. 提取行内代码
        let codeRe = try! NSRegularExpression(pattern: #"`([^`]+)`"#)
        for m in codeRe.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let fullRange = m.range
            let innerRange = m.range(at: 1)
            let inner = (text as NSString).substring(with: innerRange)
            segments.append((fullRange, .code(inner)))
        }

        // 2. 提取链接
        let linkRe = try! NSRegularExpression(pattern: #"\[([^\]]+)\]\(([^)]+)\)"#)
        for m in linkRe.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let fullRange = m.range
            let textRange = m.range(at: 1)
            let urlRange = m.range(at: 2)
            let linkText = (text as NSString).substring(with: textRange)
            let url = (text as NSString).substring(with: urlRange)
            segments.append((fullRange, .link(linkText, url)))
        }

        // 3. 提取加粗（必须在斜体之前，避免 `**text` 被斜体吃掉）
        let boldRe = try! NSRegularExpression(pattern: #"\*\*(.+?)\*\*"#)
        for m in boldRe.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let fullRange = m.range
            let innerRange = m.range(at: 1)
            let inner = (text as NSString).substring(with: innerRange)
            segments.append((fullRange, .bold(inner)))
        }

        // 4. 提取斜体（不匹配已经被 bold 覆盖的区域）
        let italicRe = try! NSRegularExpression(pattern: #"(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)"#)
        for m in italicRe.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            // 检查是否与已有的 bold/code/link 重叠
            if !overlapsAny(m.range, with: segments.map(\.range)) {
                let fullRange = m.range
                let innerRange = m.range(at: 1)
                let inner = (text as NSString).substring(with: innerRange)
                segments.append((fullRange, .italic(inner)))
            }
        }

        // 按位置排序，然后补全 plain 片段
        segments.sort { $0.range.location < $1.range.location }

        var result: [InlineSegment] = []
        var pos = 0
        let nsText = text as NSString
        let len = nsText.length

        for seg in segments {
            if seg.range.location > pos {
                let plainRange = NSRange(location: pos, length: seg.range.location - pos)
                result.append(.plain(nsText.substring(with: plainRange)))
            }
            result.append(seg.type)
            pos = seg.range.location + seg.range.length
        }

        if pos < len {
            result.append(.plain(nsText.substring(with: NSRange(location: pos, length: len - pos))))
        }

        return result
    }

    private static func overlapsAny(_ range: NSRange, with ranges: [NSRange]) -> Bool {
        for r in ranges {
            if NSIntersectionRange(range, r).length > 0 { return true }
        }
        return false
    }

    // MARK: - 解析辅助

    private struct Heading { var level: Int; var text: String }

    private static func parseHeading(_ line: String) -> Heading? {
        var level = 0
        var i = line.startIndex
        while i < line.endIndex && line[i] == "#" && level < 6 {
            level += 1
            i = line.index(after: i)
        }
        guard level > 0, i < line.endIndex, line[i] == " " else { return nil }
        return Heading(level: level, text: String(line[line.index(after: i)...]).trimmingCharacters(in: .whitespaces))
    }

    private static func parseListItem(_ line: String) -> String? {
        if line.hasPrefix("- ") { return String(line.dropFirst(2)) }
        if line.hasPrefix("* ") { return String(line.dropFirst(2)) }
        if line.hasPrefix("+ ") { return String(line.dropFirst(2)) }
        let olRe = try! NSRegularExpression(pattern: #"^\d+\.\s+(.+)"#)
        if let m = olRe.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
           let r = Range(m.range(at: 1), in: line) {
            return String(line[r])
        }
        return nil
    }

    private static func itemMarker(of line: String) -> String {
        if line.hasPrefix("- ") { return "- " }
        if line.hasPrefix("* ") { return "* " }
        if line.hasPrefix("+ ") { return "+ " }
        let olRe = try! NSRegularExpression(pattern: #"^(\d+\.\s+)"#)
        if let m = olRe.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
           let r = Range(m.range, in: line) {
            return String(line[r])
        }
        return ""
    }

    private static func isHR(_ s: String) -> Bool {
        let c = s.filter { !$0.isWhitespace }
        return c.count >= 3 && (c.allSatisfy { $0 == "-" } || c.allSatisfy { $0 == "*" } || c.allSatisfy { $0 == "_" })
    }
}

// MARK: - NSFont 扩展

extension NSFont {
    /// 返回添加/移除斜体后的字体副本
    func withTraits(italic: Bool) -> NSFont {
        let descriptor = self.fontDescriptor
        let newDescriptor: NSFontDescriptor
        if italic {
            newDescriptor = descriptor.withSymbolicTraits(.italic)
        } else {
            newDescriptor = descriptor.withSymbolicTraits([])
        }
        return NSFont(descriptor: newDescriptor, size: self.pointSize) ?? self
    }
}
