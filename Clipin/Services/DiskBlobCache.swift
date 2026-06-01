import Foundation

/// 磁盘 blob 缓存原语：per-key 单文件 + TTL 过期 + 后台 IO。
///
/// 收敛 WebScreenshotCache 与 FaviconCache 几乎逐行相同的磁盘层（diskDir / readDisk /
/// writeDisk / pruneExpired）。两者唯一实质差异是**子目录名**和**文件名策略**（截图按 URL 的
/// FNV hex、favicon 按 origin sanitize），都参数化为 `subdir` 与 `nameFor`。
///
/// **无隔离状态**：只读配置（dir/ttl/ext/nameFor）+ 无状态 IO，所有读写都在 `Task.detached`
/// 后台跑。因此任何隔离模型的缓存（FaviconCache=actor、WebScreenshotCache=@MainActor）都能
/// 持有同一个实例。一次性过期清理的「本 session 是否已跑」标志留在各缓存自身（各自隔离域里），
/// 这里只提供无副作用的 `pruneExpired()`。
struct DiskBlobCache: Sendable {
    private let dir: URL
    private let ttl: TimeInterval
    private let fileExtension: String
    private let nameFor: @Sendable (String) -> String

    /// - subdir: Application Support 下的相对子目录（如 "Clipin/screenshots"）。
    /// - ttl: 文件过期时长；read 命中但超 TTL 视为未命中（不在 read 里删，交给 pruneExpired 批量清）。
    /// - fileExtension: 文件后缀，默认 png（截图/favicon 都存 PNG）。
    /// - nameFor: key → 不含后缀的文件名。必须稳定且与历史一致，否则旧磁盘缓存集体失配。
    init(
        subdir: String,
        ttl: TimeInterval,
        fileExtension: String = "png",
        nameFor: @escaping @Sendable (String) -> String
    ) {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = support.appendingPathComponent(subdir, isDirectory: true)
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        self.dir = directory
        self.ttl = ttl
        self.fileExtension = fileExtension
        self.nameFor = nameFor
    }

    private func file(for key: String) -> URL {
        dir.appendingPathComponent(nameFor(key)).appendingPathExtension(fileExtension)
    }

    /// 后台读：命中且未过 TTL 返回 Data，否则 nil。
    func read(_ key: String) async -> Data? {
        let file = file(for: key)
        let ttl = ttl
        return await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            guard fm.fileExists(atPath: file.path),
                  let attrs = try? fm.attributesOfItem(atPath: file.path),
                  let modDate = attrs[.modificationDate] as? Date,
                  Date().timeIntervalSince(modDate) < ttl,
                  let data = try? Data(contentsOf: file) else { return nil }
            return data
        }.value
    }

    /// 后台写（fire-and-forget）：Data 是 Sendable 值类型，detached 直接写盘，无 NSImage 跨线程问题。
    func write(_ key: String, data: Data) {
        let file = file(for: key)
        Task.detached(priority: .utility) {
            try? data.write(to: file)
        }
    }

    /// 删除目录内所有超 TTL 的文件。每 session 跑一次（「是否已跑」标志由调用方持有）。
    func pruneExpired() {
        let dir = dir
        let ttl = ttl
        Task.detached(priority: .utility) {
            let fm = FileManager.default
            guard let entries = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { return }
            let now = Date()
            for file in entries {
                guard let attrs = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
                      let modDate = attrs.contentModificationDate else { continue }
                if now.timeIntervalSince(modDate) > ttl {
                    try? fm.removeItem(at: file)
                }
            }
        }
    }
}
