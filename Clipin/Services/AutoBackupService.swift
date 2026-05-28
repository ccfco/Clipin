import Combine
import Foundation

/// 自动备份服务：按 hourly/daily/weekly 周期把历史写入指定文件夹的 .clipin.zip。
/// 写盘细节（zip 打包、.previous 轮转、NSFileCoordinator 协调）由 ArchiveService 负责。
///
/// 设计：纯周期定时器，不再监听剪贴板变化（v4 移除 onChange 模式）——单一调度路径
/// 更可预测，避免事件触发被多层节流后退化成"伪 hourly"的复杂胶水。
@MainActor
final class AutoBackupService: ObservableObject {
    static let shared = AutoBackupService(core: AppState.shared.core, settings: SettingsStore.shared)

    // MARK: - 路径与命名

    /// host-aware 备份文件名（不含目录）。
    /// 多设备同 iCloud 文件夹下用 hostname 分流，单机用户也带 hostname——避免"自动检测多设备
    /// 才改名"的隐式状态机，让 iCloud Drive 看到的备份名稳定可预测。
    static var backupFilename: String {
        let host = sanitizedHostname()
        return host.isEmpty ? "clipin-backup.clipin.zip" : "clipin-backup-\(host).clipin.zip"
    }

    /// 本机 hostname（已 sanitize），给 BackupCleanupService 判断"其他设备备份"用。
    static var currentHostnameSlug: String { sanitizedHostname() }

    /// 推导默认备份文件夹路径。iCloud Drive 可用 → iCloud 下 "Clipin Backups"；
    /// 否则 → `~/Documents/Clipin Backups`。**只返回路径不创建目录**。
    static func computeDefaultBackupFolder() -> URL {
        if let icloud = iCloudBackupFolder() { return icloud }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Clipin Backups", isDirectory: true)
    }

    /// iCloud Drive 是否真正可用。主判定用 `ubiquityIdentityToken`：
    /// - 用户登录 iCloud + 启用 iCloud Drive → 非 nil
    /// - 仅登录 Apple ID 没开 iCloud Drive → nil
    /// - 完全没登录 iCloud → nil
    ///
    /// 历史踩坑：早先注释说"非沙盒 app 不能用 ubiquityIdentityToken（需 entitlement）"
    /// 是错的——读 token 免 entitlement，只有 ubiquity container 读写需要。
    /// 早先 fallback 仅看 `~/Library/Mobile Documents/com~apple~CloudDocs` 目录存在性，
    /// 但这个目录在「用户曾开过 iCloud Drive 然后关掉」「macOS 升级时自动创建」等
    /// 场景下会残留，导致误判 iCloud 可用 → 用户在「未开 iCloud」的机器上看到默认
    /// 路径被设到 iCloud Mobile Documents 下，备份永远不会上云。
    ///
    /// 目录存在性仍作为第二道校验：登录态正常但目录被异常状态破坏时回到 Documents。
    static func isICloudDriveAvailable() -> Bool {
        guard FileManager.default.ubiquityIdentityToken != nil else { return false }
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: iCloudDriveRoot().path, isDirectory: &isDir)
        return exists && isDir.boolValue
    }

    static func iCloudBackupFolder() -> URL? {
        guard isICloudDriveAvailable() else { return nil }
        return iCloudDriveRoot().appendingPathComponent("Clipin Backups", isDirectory: true)
    }

    private static func iCloudDriveRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }

    /// 当前路径是否就是动态推导出的默认路径——把"两条 standardizedFileURL.path
    /// 字符串比较"收口到 service，避免 SettingsView 重复实现。
    static func isDefaultBackupFolder(_ path: String?) -> Bool {
        guard let path else { return false }
        let normalized = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
        return normalized == computeDefaultBackupFolder().standardizedFileURL.path
    }

    /// 当前路径是否落在 iCloud Drive 默认目录。
    /// iCloud 不可用时永远 false——不要把 ~/Library/Mobile Documents 残留路径
    /// 误判为"在 iCloud 上"。
    static func isICloudBackupFolder(_ path: String?) -> Bool {
        guard let path, let icloud = iCloudBackupFolder() else { return false }
        let normalized = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
        return normalized == icloud.standardizedFileURL.path
    }

    // MARK: - Published

    @Published private(set) var lastBackupAt: Date?
    @Published private(set) var lastBackupError: String?
    @Published private(set) var isBackingUp = false
    @Published private(set) var lastBackupSize: Int64 = 0
    @Published private(set) var lastBackupURL: URL?
    @Published private(set) var consecutiveFailures: Int = 0
    /// 上一次备份跳过的条目数（图片文件丢失等）。> 0 = partial backup，UI 必须显示
    /// warning 不能再显示纯绿色"成功"——用户依赖这个备份恢复时会少图。
    /// CLAUDE.md「不兜底」红线：partial 必须正面暴露不能被沉默吃掉。
    @Published private(set) var lastBackupSkipped: Int = 0
    /// 连续 maxConsecutiveFailures 次失败或目标文件夹失效 → 自动暂停。
    /// 用户在设置里点 Resume 或手动 Backup Now、改设置都会清掉。
    @Published private(set) var pausedDueToFailures: Bool = false

    // MARK: - 私有

    private let core: ClipinCore
    private let settings: SettingsStore
    /// lastBackup* 等状态的持久化后端。默认 `.standard`，单元测试注入独立 suite，
    /// 让测试实例不污染本机 production app 的 autoBackup.* keys。
    private let defaults: UserDefaults
    private var cancellables = Set<AnyCancellable>()
    private var timer: Timer?
    private var backupTask: Task<Void, Never>?
    private var backupGeneration = UUID()

    private static let maxConsecutiveFailures = 3

    private enum Keys {
        static let lastBackupAt = "autoBackup.lastBackupAt"
        static let lastBackupSize = "autoBackup.lastBackupSize"
        static let lastBackupURL = "autoBackup.lastBackupURL"
        static let consecutiveFailures = "autoBackup.consecutiveFailures"
        static let paused = "autoBackup.paused"
        static let lastBackupSkipped = "autoBackup.lastBackupSkipped"
    }

    init(core: ClipinCore, settings: SettingsStore, defaults: UserDefaults = .standard) {
        self.core = core
        self.settings = settings
        self.defaults = defaults

        let d = defaults
        self.lastBackupAt = d.object(forKey: Keys.lastBackupAt) as? Date
        self.lastBackupSize = (d.object(forKey: Keys.lastBackupSize) as? NSNumber)?.int64Value ?? 0
        if let p = d.string(forKey: Keys.lastBackupURL) {
            self.lastBackupURL = URL(fileURLWithPath: p)
        }
        self.consecutiveFailures = d.integer(forKey: Keys.consecutiveFailures)
        self.pausedDueToFailures = d.bool(forKey: Keys.paused)
        self.lastBackupSkipped = d.integer(forKey: Keys.lastBackupSkipped)

        // 自愈：lastBackupURL 不在当前 settings.autoBackupFolderPath 下 → 视为 stale
        // state（典型来源是用户改了备份 folder，旧 folder 下的 lastBackupURL 已不相关），
        // 清掉所有 lastBackup* 相关 published state 和持久化值，避免设置页永久显示
        // 一个指向旧路径的 "Last backup: ..." 假状态。
        purgeStaleBackupStateIfNeeded()

        settings.$autoBackupEnabled
            .combineLatest(settings.$autoBackupFolderPath, settings.$autoBackupInterval)
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in self?.reconfigure(settingsChanged: true) }
            .store(in: &cancellables)

        reconfigure(settingsChanged: false)
    }

    // MARK: - 配置

    /// `settingsChanged`：用户改动 settings 引发 → 视为"重新激活意图"，自动清 paused。
    /// init / resume 路径下保留 paused 语义（resume 自己已先清完）。
    private func reconfigure(settingsChanged: Bool) {
        timer?.invalidate()
        timer = nil
        backupTask?.cancel()
        backupTask = nil
        isBackingUp = false

        guard settings.autoBackupEnabled,
              let folderPath = settings.autoBackupFolderPath else { return }

        // 用户主动改设置 = 重新激活：清掉之前的 paused/failures
        if settingsChanged && pausedDueToFailures {
            pausedDueToFailures = false
            consecutiveFailures = 0
            persist(paused: false)
            persist(failures: 0)
        }
        if pausedDueToFailures { return }

        let folderURL = URL(fileURLWithPath: folderPath, isDirectory: true)
        let checkInterval = settings.autoBackupInterval.checkInterval

        if isBackupOverdue() {
            performBackup(folderURL: folderURL)
        }

        timer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                // !isBackingUp 让正在跑的备份自然完成——hourly/daily 的 checkInterval
                // 远大于备份时长，理论上不会撞上；但加 guard 让"checkInterval >
                // 备份时长"从隐式假设变成显式不变量。
                guard let self, !self.isBackingUp, self.isBackupOverdue() else { return }
                self.performBackup(folderURL: folderURL)
            }
        }
    }

    private func isBackupOverdue() -> Bool {
        let interval = settings.autoBackupInterval.backupInterval
        return Date().timeIntervalSince(lastBackupAt ?? .distantPast) >= interval
    }

    // MARK: - 执行

    private func performBackup(folderURL: URL) {
        // 文件夹失效检测：被删/移走/iCloud 关 → 直接进 paused 状态而非反复失败刷错
        guard FileManager.default.fileExists(atPath: folderURL.path) else {
            self.lastBackupError = NSLocalizedString("Backup folder is missing", comment: "")
            self.pausedDueToFailures = true
            persist(paused: true)
            return
        }

        let fileURL = folderURL.appendingPathComponent(Self.backupFilename)
        let core = self.core
        backupTask?.cancel()
        let generation = UUID()
        backupGeneration = generation
        isBackingUp = true
        lastBackupError = nil

        backupTask = Task { [weak self] in
            do {
                let result = try await ArchiveService.writeArchive(to: fileURL, core: core)
                guard !Task.isCancelled else { return }
                let completedAt = Date()
                guard self?.backupGeneration == generation else { return }
                self?.applySuccess(
                    at: completedAt,
                    url: result.url,
                    size: result.archiveSize,
                    skipped: result.skippedCount
                )
            } catch is CancellationError {
                guard self?.backupGeneration == generation else { return }
                self?.isBackingUp = false
                return
            } catch {
                guard self?.backupGeneration == generation else { return }
                self?.applyFailure(error: error)
            }
        }
    }

    private func applySuccess(at date: Date, url: URL, size: Int64, skipped: Int) {
        isBackingUp = false
        lastBackupAt = date
        lastBackupURL = url
        lastBackupSize = size
        lastBackupError = nil
        lastBackupSkipped = skipped
        consecutiveFailures = 0

        let d = defaults
        d.set(date, forKey: Keys.lastBackupAt)
        d.set(url.path, forKey: Keys.lastBackupURL)
        d.set(NSNumber(value: size), forKey: Keys.lastBackupSize)
        d.set(skipped, forKey: Keys.lastBackupSkipped)
        d.set(0, forKey: Keys.consecutiveFailures)
        // 成功后清掉之前可能的 paused 状态（理论上 paused 时不会进 performBackup，
        // 但 backupNow() 手动触发的成功路径需要这一步）
        if pausedDueToFailures {
            pausedDueToFailures = false
            d.set(false, forKey: Keys.paused)
        }
    }

    private func applyFailure(error: Error) {
        isBackingUp = false
        lastBackupError = error.localizedDescription
        let next = consecutiveFailures + 1
        consecutiveFailures = next
        persist(failures: next)
        if next >= Self.maxConsecutiveFailures {
            pausedDueToFailures = true
            persist(paused: true)
        }
    }

    private func persist(paused: Bool) {
        defaults.set(paused, forKey: Keys.paused)
    }

    private func persist(failures: Int) {
        defaults.set(failures, forKey: Keys.consecutiveFailures)
    }

    // MARK: - 用户操作

    func backupNow() {
        guard settings.autoBackupEnabled,
              let folderPath = settings.autoBackupFolderPath else { return }
        // 防御性 guard：UI 按钮 disable 是第一道防线，方法级再挡一次避免外部
        // 调用者绕过 UI 状态触发 backupTask cancel-replace。reconfigure() 这类
        // 配置切换走自己的 cancel 路径，不经过 backupNow。
        guard !isBackingUp else { return }
        // 手动触发：清 paused 给一次重试机会；失败仍会重新累积 failures
        if pausedDueToFailures {
            pausedDueToFailures = false
            persist(paused: false)
        }
        performBackup(folderURL: URL(fileURLWithPath: folderPath, isDirectory: true))
    }

    /// init 自愈：检测 lastBackupURL 是否还在当前备份文件夹下。不在 → 清掉所有
    /// lastBackup* 状态。这是 fail-healing 模式，解决「用户改了 autoBackupFolderPath，
    /// 旧 folder 下的 lastBackupURL 已不相关」的污染，避免设置页永久显示指向旧路径的
    /// 假"上次备份"状态。
    ///
    /// 设计权衡：用户「手动删了真备份文件」也会触发清理——但 lastBackup* 只是 UI
    /// 显示状态，清掉后下次备份会重新写入，没有数据丢失风险；而留着 stale state
    /// 会让 partial backup warning 永久挂在那里更糟。
    private func purgeStaleBackupStateIfNeeded() {
        guard let urlPath = lastBackupURL?.path else { return }
        let folderPath = settings.autoBackupFolderPath.map {
            URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.path
        }
        let normalizedURLDir = URL(fileURLWithPath: urlPath)
            .deletingLastPathComponent()
            .standardizedFileURL.path

        // 只在 lastBackupURL 不在当前 folder 下时清理；folderPath 为 nil 时也清掉
        // （没配置 folder 却有 lastBackupURL 一定是 stale state）
        if let folderPath, normalizedURLDir == folderPath {
            return
        }

        lastBackupAt = nil
        lastBackupURL = nil
        lastBackupSize = 0
        lastBackupSkipped = 0
        lastBackupError = nil

        let d = defaults
        d.removeObject(forKey: Keys.lastBackupAt)
        d.removeObject(forKey: Keys.lastBackupURL)
        d.removeObject(forKey: Keys.lastBackupSize)
        d.removeObject(forKey: Keys.lastBackupSkipped)
    }

    /// 用户在设置页点 Resume：清 paused + 重置 failures，重新进入调度
    func resume() {
        pausedDueToFailures = false
        consecutiveFailures = 0
        persist(paused: false)
        persist(failures: 0)
        reconfigure(settingsChanged: false)
    }

    // MARK: - hostname

    /// 取机器名，过滤为 alphanumerics（保留 Unicode 字母数字）。
    /// 例："Chenlei 的 MacBook Pro" → "Chenlei的MacBookPro"。
    /// 空格、标点会破坏 zip 文件名跨平台兼容；Unicode 字母仍保留让用户能在
    /// Finder 里一眼分清"哪台机器的备份"。
    private static func sanitizedHostname() -> String {
        let raw = Host.current().localizedName ?? ""
        let allowed = CharacterSet.alphanumerics
        return raw.unicodeScalars.filter { allowed.contains($0) }.map { String($0) }.joined()
    }
}
