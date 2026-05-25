import Combine
import Foundation

/// 自动备份服务：监听设置变化，定时或按剪贴板变化将历史写入指定文件夹的 .clipin.zip。
/// 写盘细节（zip 打包、.previous 轮转、NSFileCoordinator 协调）由 ArchiveService 负责。
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

    /// 推导默认备份文件夹路径。iCloud Drive 可用 → iCloud 下 "Clipin Backups"；
    /// 否则 → `~/Documents/Clipin Backups`。**只返回路径不创建目录**。
    static func computeDefaultBackupFolder() -> URL {
        if let icloud = iCloudBackupFolder() { return icloud }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Clipin Backups", isDirectory: true)
    }

    /// 非沙盒 app 不能用 `ubiquityIdentityToken`（需 entitlement）。
    /// 直接看 `~/Library/Mobile Documents/com~apple~CloudDocs` 是否存在且为目录——
    /// 单纯 `fileExists` 不够：路径存在但是失效 symlink、被替换成普通文件等异常状态下
    /// 仍会返回 true，让 UI 误启用 iCloud 路径。用 `isDirectory:` out-param 强校验。
    static func isICloudDriveAvailable() -> Bool {
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

    // MARK: - Published

    @Published private(set) var lastBackupAt: Date?
    @Published private(set) var lastBackupError: String?
    @Published private(set) var isBackingUp = false
    @Published private(set) var lastBackupSize: Int64 = 0
    @Published private(set) var lastBackupURL: URL?
    @Published private(set) var consecutiveFailures: Int = 0
    /// 连续 maxConsecutiveFailures 次失败或目标文件夹失效 → 自动暂停。
    /// 用户在设置里点 Resume 或手动 Backup Now、改设置都会清掉。
    @Published private(set) var pausedDueToFailures: Bool = false

    // MARK: - 私有

    private let core: ClipinCore
    private let settings: SettingsStore
    private let changeDebounceDelay: Duration
    /// 两次自动备份的最小间隔。onChange 模式下用 lastBackupAt 协作，避免一年后 1+ GB 库
    /// 高频触发 → iCloud 上行流量雪崩。
    private let minimumInterval: TimeInterval
    private var cancellables = Set<AnyCancellable>()
    private var timer: Timer?
    private var changeObservers: [NSObjectProtocol] = []
    private var debounceTask: Task<Void, Never>?
    private var backupTask: Task<Void, Never>?
    private var backupGeneration = UUID()

    private static let maxConsecutiveFailures = 3

    private enum Keys {
        static let lastBackupAt = "autoBackup.lastBackupAt"
        static let lastBackupSize = "autoBackup.lastBackupSize"
        static let lastBackupURL = "autoBackup.lastBackupURL"
        static let consecutiveFailures = "autoBackup.consecutiveFailures"
        static let paused = "autoBackup.paused"
    }

    init(
        core: ClipinCore,
        settings: SettingsStore,
        changeDebounceDelay: Duration = .seconds(10),
        minimumInterval: TimeInterval = 5 * 60
    ) {
        self.core = core
        self.settings = settings
        self.changeDebounceDelay = changeDebounceDelay
        self.minimumInterval = minimumInterval

        let d = UserDefaults.standard
        self.lastBackupAt = d.object(forKey: Keys.lastBackupAt) as? Date
        self.lastBackupSize = (d.object(forKey: Keys.lastBackupSize) as? NSNumber)?.int64Value ?? 0
        if let p = d.string(forKey: Keys.lastBackupURL) {
            self.lastBackupURL = URL(fileURLWithPath: p)
        }
        self.consecutiveFailures = d.integer(forKey: Keys.consecutiveFailures)
        self.pausedDueToFailures = d.bool(forKey: Keys.paused)

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
        for observer in changeObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        changeObservers.removeAll()
        debounceTask?.cancel()
        debounceTask = nil
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

        switch settings.autoBackupInterval {
        case .onChange:
            // reconfigure 立即触发改 scheduleDebounced：用户在设置里连点多个选项不会触发
            // 多次立即备份；scheduleDebounced 内部还会再走 minimumInterval 节流
            scheduleDebounced(folderURL: folderURL)
            changeObservers = [.clipHistoryDidChange, .clipHistoryItemSaved].map { name in
                NotificationCenter.default.addObserver(
                    forName: name,
                    object: nil,
                    queue: nil
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.scheduleDebounced(folderURL: folderURL) }
                }
            }

        case .daily, .weekly:
            let checkInterval = settings.autoBackupInterval.checkInterval!

            if isBackupOverdue() {
                performBackup(folderURL: folderURL)
            }

            timer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.isBackupOverdue() else { return }
                    self.performBackup(folderURL: folderURL)
                }
            }
        }
    }

    private func isBackupOverdue() -> Bool {
        guard let interval = settings.autoBackupInterval.backupInterval else { return false }
        return Date().timeIntervalSince(lastBackupAt ?? .distantPast) >= interval
    }

    // MARK: - 调度

    /// onChange 防抖 + 最小间隔双层节流：
    /// - 防抖 10s 把"连续粘贴一批"合并为一次
    /// - 防抖结束后检查最小间隔（默认 5min），未到则继续等
    /// 双层组合避免极端场景"长期间断性使用每 10s 触发一次"导致全量重传雪崩。
    ///
    /// 每次 sleep 后重新读 `lastBackupAt` 计算 remaining：在 sleep 期间用户可能手动
    /// Backup Now 或定时任务跑过，旧快照里的 elapsed 已失效；不重判会触发"自动备份取消
    /// 正在进行的手动备份"竞态。真正进入 performBackup 前还检查 isBackingUp，避免和并发
    /// 任务对撞。
    private func scheduleDebounced(folderURL: URL) {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(for: self.changeDebounceDelay) } catch { return }

            while !Task.isCancelled {
                let elapsed = Date().timeIntervalSince(self.lastBackupAt ?? .distantPast)
                if elapsed >= self.minimumInterval { break }
                let remaining = self.minimumInterval - elapsed
                do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
            }
            if Task.isCancelled { return }
            // 手动 Backup Now 正在跑、或并发任务先到 → 让出，让进行中的备份完成
            if self.isBackingUp { return }
            self.performBackup(folderURL: folderURL)
        }
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
                self?.applySuccess(at: completedAt, url: result.url, size: result.archiveSize)
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

    private func applySuccess(at date: Date, url: URL, size: Int64) {
        isBackingUp = false
        lastBackupAt = date
        lastBackupURL = url
        lastBackupSize = size
        lastBackupError = nil
        consecutiveFailures = 0

        let d = UserDefaults.standard
        d.set(date, forKey: Keys.lastBackupAt)
        d.set(url.path, forKey: Keys.lastBackupURL)
        d.set(NSNumber(value: size), forKey: Keys.lastBackupSize)
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
        UserDefaults.standard.set(paused, forKey: Keys.paused)
    }

    private func persist(failures: Int) {
        UserDefaults.standard.set(failures, forKey: Keys.consecutiveFailures)
    }

    // MARK: - 用户操作

    func backupNow() {
        guard settings.autoBackupEnabled,
              let folderPath = settings.autoBackupFolderPath else { return }
        // 取消正在等待的 debounce task，避免它在手动备份完成后醒来又触发一次自动备份
        // （会把刚成功的状态又抹掉、spinner 闪一下）
        debounceTask?.cancel()
        debounceTask = nil
        // 手动触发：清 paused 给一次重试机会；失败仍会重新累积 failures
        if pausedDueToFailures {
            pausedDueToFailures = false
            persist(paused: false)
        }
        performBackup(folderURL: URL(fileURLWithPath: folderPath, isDirectory: true))
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
