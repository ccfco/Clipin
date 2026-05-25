import Foundation

/// 备份文件夹清理工具：扫描历史遗物文件供用户主动清除。
///
/// 候选规则（保守原则——只清"当前代码不会再产生 + 非本机"的文件）：
/// 1. v1/v2 老格式 JSON：`*.json` / `*.previous.json`（v3 起改 .clipin.zip 后不再生成）
/// 2. 其他设备的自动备份：`clipin-backup-<slug>.clipin.zip` 或
///    `clipin-backup-<slug>.previous.clipin.zip`，且 slug ≠ 本机 hostname slug
///
/// **绝对不删**：
/// - 本机当前 hostname 的 `clipin-backup-<slug>.clipin.zip` / `.previous.clipin.zip`（主备份 + 安全网）
/// - 无 hostname 后缀的 `clipin-backup.clipin.zip`（hostname 为空时的合法本机备份）
/// - 手动导出文件 `Clipin-YYYY-MM-dd-HHmm.clipin.zip`（用户主动产出，不属"遗物"）
/// - 任何不匹配以上模式的文件（用户自己放进去的 zip 不归我们管）
enum BackupCleanupService {
    struct Candidate: Identifiable {
        let url: URL
        let reason: Reason
        let size: Int64
        let modifiedAt: Date?
        var id: String { url.path }
        var displayName: String { url.lastPathComponent }
    }

    enum Reason: String {
        /// v1/v2 老 JSON 格式
        case legacyJSON
        /// 其他设备 hostname 的备份
        case foreignHost
    }

    /// 扫描指定文件夹，返回候选清理文件。
    /// `currentHostSlug` 通常传 `AutoBackupService.currentHostnameSlug`。
    static func scan(folderURL: URL, currentHostSlug: String) -> [Candidate] {
        guard FileManager.default.fileExists(atPath: folderURL.path) else { return [] }
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return [] }

        return urls.compactMap { url -> Candidate? in
            guard let reason = classify(url: url, currentHostSlug: currentHostSlug) else { return nil }
            let values = try? url.resourceValues(forKeys: Set(keys))
            // 只看 regular file，跳过别人误丢进来的目录/symlink
            guard values?.isRegularFile == true else { return nil }
            let size = Int64(values?.fileSize ?? 0)
            return Candidate(
                url: url,
                reason: reason,
                size: size,
                modifiedAt: values?.contentModificationDate
            )
        }.sorted { lhs, rhs in
            // 老的排前面（用户大致按时间从老到新看）
            (lhs.modifiedAt ?? .distantPast) < (rhs.modifiedAt ?? .distantPast)
        }
    }

    /// 删除候选；返回成功删除的数量。失败的单条不抛错（用户已批准这批的删除，
    /// 单条失败常见原因是权限/iCloud 同步占用，整批回滚不友好），但累计字节数仍以成功为准。
    @discardableResult
    static func delete(_ candidates: [Candidate]) -> Int {
        var deleted = 0
        for candidate in candidates {
            do {
                try FileManager.default.removeItem(at: candidate.url)
                deleted += 1
            } catch {
                // 单条失败：log 不抛。用户在 sheet 里已审视过列表，整批中止反而困惑
                ClipinLog.settings.error(
                    "backup cleanup failed for \(candidate.url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        return deleted
    }

    // MARK: - 私有：分类

    private static func classify(url: URL, currentHostSlug: String) -> Reason? {
        let name = url.lastPathComponent
        let lower = name.lowercased()

        // 1. JSON 老格式（含 .previous.json）
        if lower.hasSuffix(".json") {
            return .legacyJSON
        }

        // 2. clipin-backup-<slug>.clipin.zip / clipin-backup-<slug>.previous.clipin.zip
        // 顺序必须先长后短：`.previous.clipin.zip` 文件的 lower 也 hasSuffix(".clipin.zip")，
        // 短后缀放前面会把 `MyMac.previous` 当成 slug 与 `MyMac` 比较失败 → 误判 foreign
        let prefix = "clipin-backup-"
        let suffixes = [".previous.clipin.zip", ".clipin.zip"]
        guard lower.hasPrefix(prefix) else { return nil }
        for suffix in suffixes {
            guard lower.hasSuffix(suffix) else { continue }
            // 在 lowercased 字符串上切片再用相同区间到原 name 上取 slug
            let stem = String(name.dropFirst(prefix.count).dropLast(suffix.count))
            // 空 slug 不归类（理论上不会有 `clipin-backup-.clipin.zip` 这种文件）
            guard !stem.isEmpty else { return nil }
            // 大小写不敏感比较：用户在 System Settings 改了电脑名（甚至只改大小写），
            // 旧本机备份文件名 vs 当前 hostname 会大小写不一致——精确比较会把旧本机
            // 备份误判为 foreign。代价是同名不同大小写的两台机器无法区分（极少见）。
            if stem.caseInsensitiveCompare(currentHostSlug) == .orderedSame { return nil }
            return .foreignHost
        }
        return nil
    }
}
