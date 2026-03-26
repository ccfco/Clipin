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

    private let core: ClipinCore
    private let settings: SettingsStore
    private var cancellables = Set<AnyCancellable>()
    private var timer: Timer?
    private var changeObserver: Any?
    private var debounceTask: Task<Void, Never>?

    // lastBackupAt 持久化到 UserDefaults，App 重启后能判断是否逾期
    private static let lastBackupKey = "autoBackup.lastBackupAt"

    init(core: ClipinCore, settings: SettingsStore) {
        self.core = core
        self.settings = settings
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
        if let observer = changeObserver {
            NotificationCenter.default.removeObserver(observer)
            changeObserver = nil
        }
        debounceTask?.cancel()
        debounceTask = nil

        guard settings.autoBackupEnabled,
              let folderPath = settings.autoBackupFolderPath else { return }

        let folderURL = URL(fileURLWithPath: folderPath, isDirectory: true)

        switch settings.autoBackupInterval {
        case .onChange:
            changeObserver = NotificationCenter.default.addObserver(
                forName: .clipHistoryDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.scheduleDebounced(folderURL: folderURL)
            }

        case .daily, .weekly, .monthly:
            guard let checkInterval = settings.autoBackupInterval.checkInterval else { return }

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
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            self?.performBackup(folderURL: folderURL)
        }
    }

    private func performBackup(folderURL: URL) {
        let fileURL = folderURL.appendingPathComponent(Self.backupFilename)
        do {
            _ = try ArchiveService.writeArchive(to: fileURL, core: core)
            lastBackupAt = Date()
            lastBackupError = nil
            UserDefaults.standard.set(lastBackupAt, forKey: Self.lastBackupKey)
        } catch {
            lastBackupError = error.localizedDescription
        }
    }

    // MARK: - 手动触发

    func backupNow() {
        guard settings.autoBackupEnabled,
              let folderPath = settings.autoBackupFolderPath else { return }
        performBackup(folderURL: URL(fileURLWithPath: folderPath, isDirectory: true))
    }
}
