import Foundation

/// 浮动笔记文件规则引擎：将 pattern 解析为当前时间对应的文件路径，
/// 并负责创建文件（含中间目录）和自动保存。
///
/// Pattern 占位符（区分大小写）：
///   YYYY → 四位年  MM → 两位月  DD → 两位日
///   HH   → 两位时  WW → ISO 周次（01-53）
///
/// 示例：
///   "YYYY-MM-DD.md"            → "2026-04-14.md"（固定为每日同一文件）
///   "YYYY/MM/YYYY-MM-DD.md"   → "2026/04/2026-04-14.md"
///   "inbox.md"                  → "inbox.md"（无占位符 = 固定文件）
final class FloatingNoteService: @unchecked Sendable {
    static let shared = FloatingNoteService()

    private init() {}

    // MARK: - Path Resolution

    /// 根据 rootFolder + pattern 解析当前时间对应的文件 URL。
    /// - Returns: 绝对路径 URL，不保证文件已存在。
    func resolveURL(rootFolder: String, pattern: String, date: Date = Date()) -> URL {
        let resolved = applyDatePlaceholders(to: pattern, date: date)
        let root = URL(fileURLWithPath: rootFolder, isDirectory: true)
        return root.appendingPathComponent(resolved)
    }

    /// 确保文件（及中间目录）存在。文件不存在时用 template 内容创建。
    /// - Throws: 文件系统错误
    func ensureFileExists(at url: URL, template: String) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        if !fm.fileExists(atPath: url.path) {
            try template.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// 将文件内容写盘（原子写入）。
    func save(content: String, to url: URL) throws {
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    /// 根据内容重命名文件，返回新的 URL。
    /// 仅在目标文件名不存在时执行重命名，避免覆盖已有文件。
    func renameByContentIfNeeded(currentURL: URL, content: String, rootFolder: String) throws -> URL {
        let root = URL(fileURLWithPath: rootFolder, isDirectory: true)
        let newName = deriveFilename(from: content)
        let newURL = root.appendingPathComponent(newName)

        // 如果新名和当前名相同，或目标已存在，跳过
        guard newURL.path != currentURL.path, !FileManager.default.fileExists(atPath: newURL.path) else {
            return currentURL
        }

        try FileManager.default.moveItem(at: currentURL, to: newURL)
        return newURL
    }

    /// 从磁盘读取文件内容。
    func load(from url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    /// 枚举 rootFolder 下所有 .md 文件，按最后修改时间降序排列，最多返回 limit 条。
    func listMarkdownFiles(in rootFolder: String, limit: Int = 100) -> [URL] {
        let root = URL(fileURLWithPath: rootFolder, isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [(url: URL, date: Date)] = []
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "md" else { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            files.append((url, values?.contentModificationDate ?? .distantPast))
        }

        return files
            .sorted { $0.date > $1.date }
            .prefix(limit)
            .map(\.url)
    }

    /// 从 Markdown 内容的前几行截取前 N 个字符，生成安全的文件名。
    /// 去除 Markdown 标记（#、-、* 等），跳过空行。
    func deriveFilename(from content: String, maxLength: Int = 20) -> String {
        for line in content.components(separatedBy: .newlines) {
            let stripped = line.trimmingCharacters(in: .whitespaces)
            guard !stripped.isEmpty else { continue }
            // 去除 Markdown 前缀
            var clean = stripped
            // 去除 # 前缀
            if clean.hasPrefix("#") {
                clean = clean.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
            }
            // 去除列表前缀
            if clean.hasPrefix("- ") || clean.hasPrefix("* ") || clean.hasPrefix("+ ") {
                clean = String(clean.dropFirst(2))
            }
            // 去除有序列表前缀
            if let range = clean.range(of: #"^\d+\.\s*"#, options: .regularExpression) {
                clean = String(clean[range.upperBound...])
            }
            // 去除 > 引用前缀
            if clean.hasPrefix("> ") {
                clean = String(clean.dropFirst(2))
            }
            clean = clean.trimmingCharacters(in: .whitespaces)
            guard !clean.isEmpty else { continue }
            // 截断到指定长度
            if clean.count > maxLength {
                clean = String(clean.prefix(maxLength)).trimmingCharacters(in: .whitespaces)
            }
            // 替换文件系统不安全的字符
            clean = clean
                .replacingOccurrences(of: "/", with: "／")
                .replacingOccurrences(of: "\\", with: "＼")
                .replacingOccurrences(of: ":", with: "：")
                .replacingOccurrences(of: "*", with: "·")
                .replacingOccurrences(of: "?", with: "？")
                .replacingOccurrences(of: "\"", with: "\u{201D}")
                .replacingOccurrences(of: "<", with: "‹")
                .replacingOccurrences(of: ">", with: "›")
                .replacingOccurrences(of: "|", with: "｜")
            return clean + ".md"
        }
        return "新笔记.md"
    }

    /// 以内容派生的文件名创建新笔记，确保文件唯一。
    /// - Returns: 新笔记的 URL
    func createNote(content: String, in rootFolder: String) throws -> URL {
        let root = URL(fileURLWithPath: rootFolder, isDirectory: true)
        if !FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        let filename = deriveFilename(from: content)
        var url = root.appendingPathComponent(filename)

        // 如果文件已存在，追加时间戳保证唯一
        var counter = 0
        while FileManager.default.fileExists(atPath: url.path) {
            counter += 1
            let name = (filename as NSString).deletingPathExtension
            url = root.appendingPathComponent("\(name)-\(counter).md")
        }

        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Placeholder Substitution

    /// 支持的占位符：
    ///   YYYY  → 四位年          MM  → 两位月       DD  → 两位日
    ///   HH    → 两位小时(24h)   WW/ww → ISO 周次   ddd → 中文周名（周一…周日）
    ///
    /// 支持 `[literal text]` 语法：方括号内的内容原样输出，括号被剥除，
    /// 避免中文字符与占位符混淆（如 `[第]ww[周]` → `第16周`）。
    private func applyDatePlaceholders(to pattern: String, date: Date) -> String {
        let cal = Calendar(identifier: .iso8601)
        let comps = cal.dateComponents([.year, .month, .day, .hour, .weekOfYear, .weekday], from: date)

        let year     = String(format: "%04d", comps.year ?? 0)
        let month    = String(format: "%02d", comps.month ?? 0)
        let day      = String(format: "%02d", comps.day ?? 0)
        let hour     = String(format: "%02d", comps.hour ?? 0)
        let week     = String(format: "%02d", comps.weekOfYear ?? 0)
        let weekday  = chineseWeekday(comps.weekday ?? 1)

        // Step 1：把 [literal] 块提取出来，用 UUID 占位防止被日期逻辑替换
        var literals: [String: String] = [:]
        var work = pattern
        let bracketRegex = try! NSRegularExpression(pattern: #"\[[^\]]*\]"#)
        let matches = bracketRegex.matches(in: work, range: NSRange(work.startIndex..., in: work))
        // 从后往前替换，避免替换后偏移量变化
        for match in matches.reversed() {
            guard let range = Range(match.range, in: work) else { continue }
            let raw = String(work[range])
            let inner = String(raw.dropFirst().dropLast()) // 去掉 [ ]
            let placeholder = "§\(literals.count)§"
            literals[placeholder] = inner
            work.replaceSubrange(range, with: placeholder)
        }

        // Step 2：替换日期占位符
        work = work
            .replacingOccurrences(of: "YYYY", with: year)
            .replacingOccurrences(of: "MM",   with: month)
            .replacingOccurrences(of: "DD",   with: day)
            .replacingOccurrences(of: "HH",   with: hour)
            .replacingOccurrences(of: "WW",   with: week)
            .replacingOccurrences(of: "ww",   with: week)
            .replacingOccurrences(of: "ddd",  with: weekday)

        // Step 3：还原字面量
        for (placeholder, literal) in literals {
            work = work.replacingOccurrences(of: placeholder, with: literal)
        }

        return work
    }

    private func chineseWeekday(_ weekday: Int) -> String {
        // NSCalendar weekday: 1=Sunday, 2=Monday, ..., 7=Saturday
        switch weekday {
        case 2: return "周一"
        case 3: return "周二"
        case 4: return "周三"
        case 5: return "周四"
        case 6: return "周五"
        case 7: return "周六"
        default: return "周日"
        }
    }
}
