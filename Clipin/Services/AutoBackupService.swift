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

    init(core: ClipinCore, settings: SettingsStore) {
        self.core = core
        self.settings = settings

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
        // 清除旧配置
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

        case .every15min, .every1hour:
            guard let interval = settings.autoBackupInterval.timerInterval else { return }
            timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.performBackup(folderURL: folderURL) }
            }
            // 启用后立即执行一次
            performBackup(folderURL: folderURL)
        }
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
