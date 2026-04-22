import Foundation

/// 轻量 Markdown → HTML 转换器（浮动笔记预览专用）。
/// 支持：标题、加粗/斜体、删除线、行内代码、围栏代码块、
///       有/无序列表、任务清单、引用块、链接、分割线。
/// 零外部依赖，不追求 100% CommonMark 规范，优先覆盖日记/笔记常用语法。
final class MarkdownRenderer: @unchecked Sendable {
    static let shared = MarkdownRenderer()
    private init() {}

    func renderHTML(from markdown: String) -> String {
        previewShellHTML(body: renderBodyHTML(from: markdown))
    }

    func renderBodyHTML(from markdown: String) -> String {
        processBlocks(markdown.components(separatedBy: "\n"), index: 0).html
    }

    func previewShellHTML(body: String = "") -> String {
        htmlPage(body)
    }

    // MARK: - Block Processing

    private struct BlockResult { var html: String; var nextIndex: Int }

    private func processBlocks(_ lines: [String], index: Int) -> BlockResult {
        var i = index
        var out = ""

        while i < lines.count {
            let line = lines[i]
            let stripped = line.trimmingCharacters(in: .whitespaces)

            // 围栏代码块
            if stripped.hasPrefix("```") {
                let lang = String(stripped.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                i += 1
                var codeLines: [String] = []
                while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    codeLines.append(lines[i])
                    i += 1
                }
                i += 1  // 跳过结束 ```
                let code = escape(codeLines.joined(separator: "\n"))
                let cls = lang.isEmpty ? "" : " class=\"language-\(lang)\""
                out += "<pre><code\(cls)>\(code)</code></pre>\n"
                continue
            }

            // 标题
            if let h = parseHeading(line) {
                out += "<h\(h.level)>\(inline(h.text))</h\(h.level)>\n"
                i += 1; continue
            }

            // 分割线
            if isHR(stripped) {
                out += "<hr>\n"; i += 1; continue
            }

            // 引用块
            if line.hasPrefix(">") {
                var bqLines: [String] = []
                while i < lines.count && lines[i].hasPrefix(">") {
                    let l = lines[i]
                    bqLines.append(l.hasPrefix("> ") ? String(l.dropFirst(2)) : String(l.dropFirst(1)))
                    i += 1
                }
                let inner = processBlocks(bqLines, index: 0).html
                out += "<blockquote>\(inner)</blockquote>\n"
                continue
            }

            // 列表
            if let curListType = listType(of: line) {
                var items: [String] = []
                while i < lines.count, let t = listType(of: lines[i]), t == curListType {
                    items.append(listItemHTML(lines[i], type: curListType))
                    i += 1
                }
                let tag = curListType == "ul" ? "ul" : "ol"
                out += "<\(tag)>\n\(items.joined(separator: "\n"))\n</\(tag)>\n"
                continue
            }

            // 空行
            if stripped.isEmpty { i += 1; continue }

            // 段落（连续非空、非块级）
            var para: [String] = []
            while i < lines.count {
                let l = lines[i]; let s = l.trimmingCharacters(in: .whitespaces)
                if s.isEmpty || l.hasPrefix(">") || l.hasPrefix("```")
                    || parseHeading(l) != nil || isHR(s)
                    || listType(of: l) != nil { break }
                para.append(l)
                i += 1
            }
            if !para.isEmpty {
                out += "<p>\(inline(para.joined(separator: " ")))</p>\n"
            }
        }

        return BlockResult(html: out, nextIndex: i)
    }

    // MARK: - Inline Processing

    private func inline(_ raw: String) -> String {
        // 1. 提取行内代码（占位符保护，避免被后续正则替换）
        var text = raw
        var codeSlots: [String: String] = [:]
        let codeRE = try! NSRegularExpression(pattern: "`([^`]+)`")
        let codeMatches = codeRE.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for m in codeMatches.reversed() {
            guard let full = Range(m.range, in: text), let inner = Range(m.range(at: 1), in: text) else { continue }
            let key = "§\(codeSlots.count)§"
            codeSlots[key] = "<code>\(escape(String(text[inner])))</code>"
            text.replaceSubrange(full, with: key)
        }

        // 2. HTML 转义
        text = escape(text)

        // 3. 行内格式（顺序不可颠倒）
        let re = { (pat: String, rep: String) in
            text = text.replacingOccurrences(of: pat, with: rep, options: .regularExpression)
        }
        re(#"\*\*\*(.+?)\*\*\*"#,      "<strong><em>$1</em></strong>")
        re(#"\*\*(.+?)\*\*"#,           "<strong>$1</strong>")
        re(#"__(.+?)__"#,               "<strong>$1</strong>")
        re(#"\*(.+?)\*"#,               "<em>$1</em>")
        re(#"_(.+?)_"#,                 "<em>$1</em>")
        re(#"~~(.+?)~~"#,               "<del>$1</del>")
        re(#"\[([^\]]+)\]\(([^)]+)\)"#, "<a href=\"$2\">$1</a>")

        // 4. 还原行内代码
        for (k, v) in codeSlots { text = text.replacingOccurrences(of: k, with: v) }
        return text
    }

    // MARK: - Helpers

    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }

    private struct Heading { var level: Int; var text: String }
    private func parseHeading(_ line: String) -> Heading? {
        var lvl = 0
        var i = line.startIndex
        while i < line.endIndex && line[i] == "#" && lvl < 6 { lvl += 1; i = line.index(after: i) }
        guard lvl > 0, i < line.endIndex, line[i] == " " else { return nil }
        return Heading(level: lvl, text: String(line[line.index(after: i)...]).trimmingCharacters(in: .whitespaces))
    }

    private func isHR(_ s: String) -> Bool {
        let c = s.filter { !$0.isWhitespace }
        return c.count >= 3 && (c.allSatisfy { $0 == "-" } || c.allSatisfy { $0 == "*" } || c.allSatisfy { $0 == "_" })
    }

    private func listType(of line: String) -> String? {
        let t = line.trimmingCharacters(in: .init(charactersIn: " \t"))
        if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("+ ") { return "ul" }
        if t.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil { return "ol" }
        return nil
    }

    private func listItemHTML(_ line: String, type: String) -> String {
        let t = line.trimmingCharacters(in: .init(charactersIn: " \t"))
        var content: String
        if type == "ul" {
            content = t.count > 2 ? String(t.dropFirst(2)) : ""
        } else {
            content = t.replacingOccurrences(of: #"^\d+\.\s+"#, with: "", options: .regularExpression)
        }
        // 任务清单 [ ] / [x]
        if content.hasPrefix("[ ] ") {
            return "<li class=\"task\"><input type=\"checkbox\" disabled> \(inline(String(content.dropFirst(4))))</li>"
        }
        if content.lowercased().hasPrefix("[x] ") {
            return "<li class=\"task\"><input type=\"checkbox\" checked disabled> \(inline(String(content.dropFirst(4))))</li>"
        }
        return "<li>\(inline(content))</li>"
    }

    // MARK: - HTML Page

    private func htmlPage(_ body: String) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>\(css)</style>
        <script>
        window.__updateBody = function(html) {
            document.body.innerHTML = html;
        };
        </script>
        </head>
        <body>\(body)</body>
        </html>
        """
    }

    private let css = """
        :root {
            --fg:#1c1c1e; --fg2:#6e6e73; --border:rgba(0,0,0,.1);
            --code-bg:rgba(0,0,0,.06); --pre-bg:rgba(0,0,0,.05);
            --bq-bar:rgba(0,0,0,.2); --link:#007aff;
        }
        @media(prefers-color-scheme:dark){:root{
            --fg:rgba(255,255,255,.88); --fg2:rgba(255,255,255,.48);
            --border:rgba(255,255,255,.12); --code-bg:rgba(255,255,255,.1);
            --pre-bg:rgba(255,255,255,.07); --bq-bar:rgba(255,255,255,.25); --link:#0a84ff;
        }}
        *{box-sizing:border-box;margin:0;padding:0}
        body{font:-apple-system-body;font-family:-apple-system,system-ui,sans-serif;
             font-size:14px;line-height:1.72;color:var(--fg);padding:14px 18px 40px;word-break:break-word}
        h1,h2,h3,h4,h5,h6{font-weight:600;line-height:1.3;margin:1.3em 0 .4em}
        h1:first-child,h2:first-child,h3:first-child{margin-top:0}
        h1{font-size:1.5em}h2{font-size:1.25em}h3{font-size:1.08em}
        p{margin:.6em 0}p:first-child{margin-top:0}
        a{color:var(--link);text-decoration:none}a:hover{text-decoration:underline}
        strong{font-weight:600}em{font-style:italic}del{text-decoration:line-through;opacity:.6}
        code{font-family:"SF Mono",Menlo,monospace;font-size:.87em;
             background:var(--code-bg);padding:.15em .38em;border-radius:4px}
        pre{background:var(--pre-bg);border-radius:8px;padding:12px 14px;margin:.8em 0;overflow-x:auto}
        pre code{background:none;padding:0;font-size:.85em;line-height:1.55}
        ul,ol{padding-left:1.5em;margin:.55em 0}li{margin:.18em 0}
        li.task{list-style:none;margin-left:-1em}
        li.task input{margin-right:.45em;vertical-align:middle}
        blockquote{border-left:3px solid var(--bq-bar);padding-left:12px;
                   margin:.75em 0;color:var(--fg2)}
        blockquote p{margin:.25em 0}
        hr{border:none;border-top:1px solid var(--border);margin:1.1em 0}
        """
}
