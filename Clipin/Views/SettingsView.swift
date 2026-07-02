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

    /// 介绍卡描述——对齐原生 System Settings 每个 pane 顶部「图标 + 标题 + 一句说明」介绍卡。
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

    /// 原生 System Settings 风格详情区：grouped Form 提供分组卡片 + 分隔线。
    /// 对齐原生（见「辅助功能」页参照）：pane 标题**同时**出现在两处——工具栏
    /// （navigationTitle，配 ←→ 导航）+ 内容区首张介绍卡（图标 + 标题 + 一句说明）。
    /// 这不是「双头」冗余，原生自己就这么做：工具栏是小的导航上下文，介绍卡是本页主视觉头部。
    /// About 是身份页不是设置表单，走 aboutPane（居中 hero + Form），见 SettingsView+About。
    @ViewBuilder
    private var detailPane: some View {
        if let tab = navigation.selectedTab {
            Group {
                if tab == .about {
                    aboutPane
                } else {
                    Form {
                        paneHeader(tab)
                        switch tab {
                        case .general:      generalContent
                        case .privacy:      privacyContent
                        case .storage:      storageContent
                        case .about:        EmptyView() // unreachable：About 走 aboutPane
                        }
                    }
                    .formStyle(.grouped)
                }
            }
            // 抵消 NavigationSplitView detail 列的幻影顶部空白（SwiftUI bug rdar://122947424）——
            // 见 ClipinChrome.settingsDetailTopGapFix 注释。负 padding 把内容上移到标题栏正下方。
            .padding(.top, -ClipinChrome.settingsDetailTopGapFix)
            .navigationTitle(tab.title)
        } else {
            ContentUnavailableView(
                "Choose a section",
                systemImage: "gearshape",
                description: Text("Select a section from the sidebar to edit Clipin preferences.")
            )
        }
    }

    /// 原生 System Settings 每个 pane 顶部的介绍卡：accent 圆角方块图标 + 标题 + 一句说明。
    /// 参照系统「辅助功能」页——图标是本页主视觉方块（非侧栏单色符号）；标题与工具栏标题
    /// 相同（原生本就重复，见 detailPane 注释）；说明取 tab.summary。作为 grouped Form 首张
    /// 卡片（无 section header），卡片外观交给 Form 原生绘制，不自绘背景（CLAUDE.md 无自绘红线）。
    private func paneHeader(_ tab: SettingsTab) -> some View {
        Section {
            HStack(alignment: .center, spacing: ClipinChrome.groupGap) {
                Image(systemName: tab.icon)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(
                        RoundedRectangle(cornerRadius: ClipinChrome.cornerControl, style: .continuous)
                            .fill(Color.accentColor)
                    )
                VStack(alignment: .leading, spacing: ClipinChrome.gap) {
                    Text(tab.title)
                        .font(.system(size: 15, weight: .semibold))
                    Text(tab.summary)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, ClipinChrome.gap)
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
