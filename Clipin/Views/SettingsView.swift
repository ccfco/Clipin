import SwiftUI
import AppKit

// MARK: - SettingsTab

enum SettingsTab: String, CaseIterable, Identifiable {
    // v5 合并：Retention（保留多久）并入 Backup 改名 Storage——两者本质都是"历史数据
    // 生命周期管理"，独立 tab 只放 2 个 picker 性价比低。"先保多久 → 再如何归档"
    // 是一条用户心智链路，并到一处避免来回切换。
    case general, privacy, storage, about
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .general:      return "General"
        case .privacy:      return "Privacy"
        case .storage:      return "Storage"
        case .about:        return "About"
        }
    }
    var icon: String {
        switch self {
        case .general:      return "gear"
        case .privacy:      return "hand.raised"
        case .storage:      return "externaldrive"
        case .about:        return "info.circle"
        }
    }

    /// pane header 描述——对齐原生 System Settings 每个 pane 顶部「图标 + 标题 + 一句说明」。
    var summary: LocalizedStringKey {
        switch self {
        case .general:      return "Fine-tune keyboard behavior, launch defaults, and how Clipin looks."
        case .privacy:      return "Control which clipboard writes are ignored so sensitive or noisy content stays out."
        case .storage:      return "Set how long history stays around, keep an automatic archive on disk, and move history in or out."
        case .about:        return "App version, updates, project links, and release notes."
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
    @ObservedObject var cleanupService: CleanupService
    @ObservedObject var navigation: SettingsNavigationModel
    let core: ClipinCore

    // Internal so cross-file extensions (tabs, helpers) can read them.
    @State var notice: SettingsNotice?
    @State var activeOperation: SettingsOperation?
    @State var now: Date = .now
    /// 自动备份首次启用的隐私警示 sheet 显示标志。
    /// 写在主 struct 而非 extension：SwiftUI @State 不允许在 extension 上声明。
    @State var showAutoBackupFirstSetupNotice: Bool = false
    /// 备份文件夹清理候选（旧 JSON / 其他设备的 zip）。BackupCleanupService 扫描结果。
    @State var cleanupCandidates: [BackupCleanupService.Candidate] = []
    /// 清理确认 sheet 显示标志
    @State var showCleanupSheet: Bool = false
    /// 当前 sheet 中用户选中的 candidate id 集合——粒度选择关键状态。
    /// sheet 打开时默认全选；用户可按类型或单条 toggle。
    @State var cleanupSelection: Set<String> = []

    @State private var dismissTask: Task<Void, Never>?
    @State private var tickTimer: Timer?
    /// 当前 notice 是否被鼠标悬停——hover 时暂停 6s dismiss 让用户读完
    @State private var noticeHovered: Bool = false

    /// List(selection:) 需要可写 binding；selectedTab 仍 private(set)，写入只走 navigation.select。
    /// key monitor 的 ↑↓ 仍驱动 navigation.selectPrev/Next，原生高亮通过此 binding 跟随。
    /// setter 故意吞掉 nil：Cmd-click 侧栏当前高亮行会触发 nil 写入（macOS 单选 List 允许取消
    /// 高亮），这是 SwiftUI 里"侧栏必须恒有选中项"的标准写法（原生 System Settings 同样不可
    /// 取消选中）；get 仍返回旧 tab，下一次渲染即用它把高亮读回来，不需要额外处理。
    var selectionBinding: Binding<SettingsTab?> {
        Binding(
            get: { navigation.selectedTab },
            set: { if let tab = $0 { navigation.select(tab) } }
        )
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailPane
        }
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
            updateTickTimer(for: navigation.selectedTab)
        }
        .onChange(of: navigation.selectedTab) { _, newTab in
            updateTickTimer(for: newTab)
        }
        .onDisappear {
            dismissTask?.cancel()
            dismissTask = nil
            notice = nil
            tickTimer?.invalidate()
            tickTimer = nil
        }
    }

    /// 60s tick 仅供 Storage（备份状态相对时间）和 About（更新检查相对时间）使用。
    /// 切到 General/Privacy 时关闭，避免空转。
    private func updateTickTimer(for tab: SettingsTab?) {
        let needsTick = (tab == .storage || tab == .about)
        if needsTick {
            guard tickTimer == nil else { return }
            now = .now
            tickTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
                Task { @MainActor in self.now = .now }
            }
        } else {
            tickTimer?.invalidate()
            tickTimer = nil
        }
    }

    // MARK: - Detail Pane

    /// 原生 System Settings 风格详情区：grouped Form 提供分组卡片 + 分隔线，
    /// 顶部 paneHeader（图标 + 标题 + 描述）对齐原生每个 pane 的头部块。
    /// 必须留在 Form 的 Section 里——CLAUDE.md「设置页内禁止再自绘 surface/卡片/玻璃壳，
    /// 分组卡片交给 grouped Form」；Form 对首个 Section 有平台级固定顶部留白（已验证与内容
    /// 无关、公开 API 够不着），这是接受该留白换取合规的代价，不再手绘卡片绕开它。
    @ViewBuilder
    private var detailPane: some View {
        if let tab = navigation.selectedTab {
            Form {
                // About 的第一个 section 已是 app 身份卡（图标 + 名字 + 版本），
                // 本身就是它的头部，不再叠通用 paneHeader，避免「双头」冗余。
                if tab != .about { paneHeader(tab) }
                switch tab {
                case .general:      generalContent
                case .privacy:      privacyContent
                case .storage:      storageContent
                case .about:        aboutContent
                }
            }
            .formStyle(.grouped)
            .navigationTitle(tab.title)
        } else {
            ContentUnavailableView(
                "Choose a section",
                systemImage: "gearshape",
                description: Text("Select a section from the sidebar to edit Clipin preferences.")
            )
        }
    }

    /// 原生 System Settings 每个 pane 顶部的头部块：accent 圆角方块图标 + 标题 + 一句描述。
    /// 图标用 accent 方块（不是侧栏那种单色符号）——它是本 pane 的主视觉，原生同款做法。
    private func paneHeader(_ tab: SettingsTab) -> some View {
        Section {
            identityHeaderRow {
                Image(systemName: tab.icon)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: ClipinChrome.cornerControl, style: .continuous)
                            .fill(Color.accentColor)
                    )
            } content: {
                Text(tab.title)
                    .font(.system(size: 18, weight: .semibold))
                Text(tab.summary)
                    .settingsCaption()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Notice

    private func noticeView(_ notice: SettingsNotice) -> some View {
        HStack(spacing: ClipinChrome.gap) {
            Circle()
                .fill(notice.isError ? Color.red : Color.accentColor)
                .frame(width: 8, height: 8)
            Text(notice.text)
                .font(.system(size: 12))
                .foregroundStyle(ClipinInk.secondary)
                .textSelection(.enabled)

            Spacer(minLength: ClipinChrome.gap)

            Button {
                dismissTask?.cancel()
                dismissTask = nil
                self.notice = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(ClipinInk.tertiary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(NSLocalizedString("Dismiss", comment: ""))
        }
        .padding(.horizontal, ClipinChrome.groupGap)
        .padding(.vertical, ClipinChrome.gap)
        .clipinChromeGlass(cornerRadius: ClipinChrome.cornerControl)
        .onHover { hovered in
            noticeHovered = hovered
            if hovered {
                // 暂停 auto-dismiss，让用户读完
                dismissTask?.cancel()
                dismissTask = nil
            } else if !notice.isError, self.notice != nil {
                // 离开 hover 重新计时，但只剩 2s（短于初始 6s）——已经看过的 notice 不需要再陪 6s
                scheduleNoticeAutoDismiss(after: .seconds(2))
            }
        }
    }

    func showNotice(_ text: String, isError: Bool = false) {
        notice = SettingsNotice(text: text, isError: isError)
        dismissTask?.cancel()
        // 关键：新 notice 必须重置 hover 状态——否则上一条 notice 退场前用户
        // 鼠标若仍在该位置，新 notice 出现就会继承 hovered=true 永不消失。
        noticeHovered = false
        guard !isError else { return }
        scheduleNoticeAutoDismiss(after: .seconds(6))
    }

    private func scheduleNoticeAutoDismiss(after delay: Duration) {
        dismissTask?.cancel()
        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, !noticeHovered else { return }
            notice = nil
        }
    }

    func localized(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: NSLocalizedString(key, comment: ""), arguments: arguments)
    }
}
