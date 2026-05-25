import SwiftUI
import AppKit

// MARK: - SettingsTab

enum SettingsTab: String, CaseIterable, Identifiable {
    // v4 合并：Transfer 一次性导入导出并入 Backup（原 Auto Backup）—— 一个"备份与恢复"
    // 入口下统辖周期备份 + 一次性导入导出，少一项 sidebar 项的同时信息聚合更直观。
    case general, privacy, retention, backup, about
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .general:      return "General"
        case .privacy:      return "Privacy"
        case .retention:    return "Retention"
        case .backup:       return "Backup & Restore"
        case .about:        return "About"
        }
    }
    var icon: String {
        switch self {
        case .general:      return "gear"
        case .privacy:      return "hand.raised"
        case .retention:    return "clock.arrow.circlepath"
        case .backup:       return "icloud.and.arrow.up"
        case .about:        return "info.circle"
        }
    }

    var summary: LocalizedStringKey {
        switch self {
        case .general:
            return "Fine-tune keyboard behavior, launch defaults, and how Clipin looks."
        case .privacy:
            return "Control which clipboard writes are ignored so sensitive or noisy content stays out."
        case .retention:
            return "Set how long history stays around and when unpinned items should be trimmed."
        case .backup:
            return "Keep an automatic archive on disk so history can be restored, and move history in or out anytime."
        case .about:
            return "App version, updates, project links, and release notes."
        }
    }
}

@MainActor
final class SettingsNavigationModel: ObservableObject {
    @Published private(set) var selectedTab: SettingsTab?

    init(selectedTab: SettingsTab = .general) {
        self.selectedTab = selectedTab
    }

    func select(_ tab: SettingsTab?) {
        selectedTab = tab
    }

    func ensureSelection(_ fallback: SettingsTab = .general) {
        if selectedTab == nil { selectedTab = fallback }
    }

    func selectNext() {
        let all = SettingsTab.allCases
        guard let current = selectedTab, let idx = all.firstIndex(of: current) else { return }
        selectedTab = all[min(idx + 1, all.count - 1)]
    }

    func selectPrev() {
        let all = SettingsTab.allCases
        guard let current = selectedTab, let idx = all.firstIndex(of: current) else { return }
        selectedTab = all[max(idx - 1, 0)]
    }
}

// MARK: - SettingsView

/// Visible to cross-file extensions for notice display and state tracking.
struct SettingsNotice {
    let text: String
    let isError: Bool
}

/// Visible to cross-file extensions (tabs set/read activeOperation).
enum SettingsOperation: Equatable {
    case cleanup
    case exportArchive
    case importArchive
    /// 删除备份文件夹里 BackupCleanupService 扫到的历史遗物（旧 JSON / 其他设备 zip）
    case cleanupBackupFolder
}

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var updateReminder: UpdateReminderService
    @ObservedObject var autoBackup: AutoBackupService
    @ObservedObject var navigation: SettingsNavigationModel
    let core: ClipinCore
    let cleanupService: CleanupService

    // Internal so cross-file extensions (tabs, helpers) can read them.
    @Environment(\.colorScheme) var colorScheme
    @State var notice: SettingsNotice?
    @State var hoveredTab: SettingsTab?
    @State var activeOperation: SettingsOperation?
    @State var now: Date = .now
    /// 自动备份首次启用的隐私警示 sheet 显示标志。
    /// 写在主 struct 而非 extension：SwiftUI @State 不允许在 extension 上声明。
    @State var showAutoBackupFirstSetupNotice: Bool = false
    /// 备份文件夹清理候选（旧 JSON / 其他设备的 zip）。BackupCleanupService 扫描结果。
    @State var cleanupCandidates: [BackupCleanupService.Candidate] = []
    /// 清理确认 sheet 显示标志
    @State var showCleanupSheet: Bool = false

    @State private var dismissTask: Task<Void, Never>?
    @State private var tickTimer: Timer?

    /// Shared spacing between tab content groups.
    let contentStackSpacing: CGFloat = ClipinChrome.groupGap

    var body: some View {
        ZStack {
            windowBackdrop
            HStack(spacing: ClipinChrome.gap) {
                sidebar
                contentArea
                    .animation(ClipinMotion.panel, value: navigation.selectedTab)
            }
            .padding(ClipinChrome.gap)
        }
        .frame(width: 748, height: 620)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let notice {
                noticeView(notice)
                    .padding(.horizontal, ClipinChrome.groupGap)
                    .padding(.vertical, ClipinChrome.gap)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear {
            settings.refreshLaunchAtLoginStatus()
            tickTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
                Task { @MainActor in self.now = .now }
            }
        }
        .onDisappear {
            dismissTask?.cancel()
            dismissTask = nil
            notice = nil
            tickTimer?.invalidate()
            tickTimer = nil
        }
    }

    // MARK: - Content Area

    private var contentArea: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ClipinChrome.groupGap) {
                if let tab = navigation.selectedTab {
                    detailHeader(for: tab)

                    switch tab {
                    case .general:      generalContent
                    case .privacy:      privacyContent
                    case .retention:    retentionContent
                    case .backup:       backupContent
                    case .about:        aboutContent
                    }
                } else {
                    settingsSelectionPlaceholder
                }
            }
            .id(navigation.selectedTab?.rawValue)
            .padding(ClipinChrome.gap)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(
            ClipinContentSurface(cornerRadius: ClipinChrome.cornerSurface)
        )
    }

    // MARK: - Notice + Backdrop

    private var windowBackdrop: some View {
        Color.clear
            .clipinChromeGlass(cornerRadius: ClipinChrome.cornerShell)
            .ignoresSafeArea()
    }

    private func noticeView(_ notice: SettingsNotice) -> some View {
        HStack(spacing: ClipinChrome.gap) {
            Circle()
                .fill(notice.isError ? Color.red : Color.accentColor)
                .frame(width: 8, height: 8)
            Text(notice.text)
                .font(.system(size: 12))
                .foregroundStyle(ClipinInk.secondary)
        }
        .padding(.horizontal, ClipinChrome.groupGap)
        .padding(.vertical, ClipinChrome.gap)
        .clipinChromeGlass(cornerRadius: ClipinChrome.cornerControl)
    }

    func showNotice(_ text: String, isError: Bool = false) {
        notice = SettingsNotice(text: text, isError: isError)
        dismissTask?.cancel()
        guard !isError else { return }
        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            notice = nil
        }
    }

    func localized(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: NSLocalizedString(key, comment: ""), arguments: arguments)
    }
}
