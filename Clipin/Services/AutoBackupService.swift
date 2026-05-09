import Combine
import Foundation

/// 自动备份服务：监听设置变化，定时或按剪贴板变化将历史写入指定文件夹的 clipin-backup.json。
/// iCloud Drive 会自动同步该文件，实现被动跨设备同步。
@MainActor
final class AutoBackupService: ObservableObject {
    static let shared = AutoBackupService(core: AppState.shared.core, settings: SettingsStore.shared)
    static let backupFilename = "clipin-backup.json"

    @Published private(set) var lastBackupAt: Date?
    @Published private(set) var lastBackupError: String?
    @Published private(set) var isBackingUp = false

    private let core: ClipinCore
    private let settings: SettingsStore
    private let changeDebounceDelay: Duration
    private var cancellables = Set<AnyCancellable>()
    private var timer: Timer?
    private var changeObservers: [NSObjectProtocol] = []
    private var debounceTask: Task<Void, Never>?
    private var backupTask: Task<Void, Never>?
    private var backupGeneration = UUID()

    // lastBackupAt 持久化到 UserDefaults，App 重启后能判断是否逾期
    private static let lastBackupKey = "autoBackup.lastBackupAt"

    init(
        core: ClipinCore,
        settings: SettingsStore,
        changeDebounceDelay: Duration = .seconds(10)
    ) {
        self.core = core
        self.settings = settings
        self.changeDebounceDelay = changeDebounceDelay
        self.lastBackupAt = UserDefaults.standard.object(forKey: Self.lastBackupKey) as? Date

        // 任意备份相关设置变化时重新配置
        settings.$autoBackupEnabled
            .combineLatest(settings.$autoBackupFolderPath, settings.$autoBackupInterval)
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in self?.reconfigure() }
            .store(in: &cancellables)

        reconfigure()
    }

    // MARK: - 配置

    private func reconfigure() {
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

        let folderURL = URL(fileURLWithPath: folderPath, isDirectory: true)

        switch settings.autoBackupInterval {
        case .onChange:
            // 启用/配置后立即备份一次，用户能立刻在文件夹里看到结果
            performBackup(folderURL: folderURL)
            // 手动导入/清理等批量变化走 didChange；剪贴板新增走 itemSaved，避免为了备份强迫主面板重复 reload。
            changeObservers = [.clipHistoryDidChange, .clipHistoryItemSaved].map { name in
                NotificationCenter.default.addObserver(
                    forName: name,
                    object: nil,
                    queue: nil
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.scheduleDebounced(folderURL: folderURL) }
                }
            }

        case .daily, .weekly, .monthly:
            // checkInterval 对 .onChange 以外的 case 保证非 nil
            let checkInterval = settings.autoBackupInterval.checkInterval!

            // App 启动时立即检查是否逾期，避免等完整间隔才触发第一次
            if isBackupOverdue() {
                performBackup(folderURL: folderURL)
            }

            // 用远小于备份间隔的频率轮询，确保不漏触发
            timer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.isBackupOverdue() else { return }
                    self.performBackup(folderURL: folderURL)
                }
            }
        }
    }

    // MARK: - 逾期判断

    private func isBackupOverdue() -> Bool {
        guard let interval = settings.autoBackupInterval.backupInterval else { return false }
        return Date().timeIntervalSince(lastBackupAt ?? .distantPast) >= interval
    }

    // MARK: - 执行备份

    private func scheduleDebounced(folderURL: URL) {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(for: self.changeDebounceDelay) } catch { return }
            self.performBackup(folderURL: folderURL)
        }
    }

    private func performBackup(folderURL: URL) {
        let fileURL = folderURL.appendingPathComponent(Self.backupFilename)
        let core = self.core
        backupTask?.cancel()
        let generation = UUID()
        backupGeneration = generation
        isBackingUp = true
        lastBackupError = nil
        backupTask = Task { [weak self] in
            do {
                _ = try await ArchiveService.writeArchive(to: fileURL, core: core)
                guard !Task.isCancelled else { return }
                let completedAt = Date()
                guard self?.backupGeneration == generation else { return }
                self?.isBackingUp = false
                self?.lastBackupAt = completedAt
                self?.lastBackupError = nil
                UserDefaults.standard.set(completedAt, forKey: Self.lastBackupKey)
            } catch is CancellationError {
                guard self?.backupGeneration == generation else { return }
                self?.isBackingUp = false
                return
            } catch {
                guard self?.backupGeneration == generation else { return }
                self?.isBackingUp = false
                self?.lastBackupError = error.localizedDescription
            }
        }
    }

    // MARK: - 手动触发

    func backupNow() {
        guard settings.autoBackupEnabled,
              let folderPath = settings.autoBackupFolderPath else { return }
        performBackup(folderURL: URL(fileURLWithPath: folderPath, isDirectory: true))
    }
}
