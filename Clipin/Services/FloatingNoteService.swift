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

    /// 从磁盘读取文件内容。
    func load(from url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Placeholder Substitution

    private func applyDatePlaceholders(to pattern: String, date: Date) -> String {
        let cal = Calendar(identifier: .iso8601)
        let components = cal.dateComponents([.year, .month, .day, .hour, .weekOfYear], from: date)

        let year  = String(format: "%04d", components.year ?? 0)
        let month = String(format: "%02d", components.month ?? 0)
        let day   = String(format: "%02d", components.day ?? 0)
        let hour  = String(format: "%02d", components.hour ?? 0)
        let week  = String(format: "%02d", components.weekOfYear ?? 0)

        return pattern
            .replacingOccurrences(of: "YYYY", with: year)
            .replacingOccurrences(of: "MM",   with: month)
            .replacingOccurrences(of: "DD",   with: day)
            .replacingOccurrences(of: "HH",   with: hour)
            .replacingOccurrences(of: "WW",   with: week)
    }
}
