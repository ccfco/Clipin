import AppKit
import SwiftUI
import Combine
import Sparkle

/// 原生 titled/fullSizeContentView 窗口专用 hosting view。
/// 这类窗口的 frame、圆角、裁切和阴影都交给 AppKit，不在 content layer 再画边/裁切。
final class ClipinWindowHostingView<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isOpaque: Bool { false }
    override var safeAreaInsets: NSEdgeInsets {
        NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }

    override func updateLayer() {
        super.updateLayer()
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.borderWidth = 0
        layer?.borderColor = nil
        layer?.masksToBounds = false
    }
}

/// borderless 小浮层专用 hosting view。
/// 没有原生 window frame 的窗口才在 content layer 负责圆角裁切和轻量分离线。
final class ClipinBorderlessHostingView<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isOpaque: Bool { false }
    override func updateLayer() {
        super.updateLayer()
        // masksToBounds=true 在 CALayer compositor 层裁掉所有 AppKit subview（含旧 AppKit 毛玻璃 material 子视图），
        // 只用于 borderless 浮层；原生 titled 窗口不能走这里，否则会和 NSWindow frame 叠线。
        layer?.backgroundColor = .clear
        layer?.cornerRadius = ClipinChrome.cornerShell
        layer?.cornerCurve = .continuous
        layer?.allowsEdgeAntialiasing = true
        layer?.borderWidth = 1 / max(window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2, 1)
        layer?.borderColor = separatorLineColor.cgColor
        layer?.masksToBounds = true
        window?.invalidateShadow()
    }

    var separatorLineColor: NSColor {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark
            ? NSColor.white.withAlphaComponent(0.16)
            : NSColor.black.withAlphaComponent(0.12)
    }
}

/// 主 launcher 专用 hosting view。
/// chrome 玻璃已移交 SwiftUI 根 `GlassEffectContainer`，
/// 这里只保留正确的窗口行为：zero safeAreaInsets / clear layer / 不 mask。
final class ClipinPanelHostingView<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isOpaque: Bool { false }
    // `.titled + .fullSizeContentView` 会把隐藏标题栏区域作为 SwiftUI safe area 注入，
    // 导致 launcher 内容整体下移。chrome 玻璃与圆角已由 SwiftUI 根 GlassEffectContainer +
    // .glassEffect 负责，这里只需归零 safe area 让内容填满 bounds。
    override var safeAreaInsets: NSEdgeInsets {
        NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }

    override func updateLayer() {
        super.updateLayer()
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.borderWidth = 0
        layer?.borderColor = nil
        layer?.masksToBounds = false
    }
}

/// launcher 是 nonactivating panel，必须子类化 override，
/// 否则 makeKeyAndOrderFront 调用后 panel 不是 key window，TextField 无法 focus。
final class ClipinPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// 连续粘贴模式下面板失去 key window 时的回调
    var onResignKey: (() -> Void)?

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}

/// 设置窗口需要像系统偏好页一样支持 Esc 关闭；
/// 让 responder chain 先给内容控件机会，只有无人消费 cancel 时才真正关窗。
final class ClipinSettingsWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }
}

/// 更新提醒需要轻量浮层：不抢主面板焦点，但要支持首击按钮和 Esc 关闭。
final class ClipinUpdateReminderPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        close()
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var panel: ClipinPanel?
    var settingsWindow: NSWindow?
    var updateReminderWindow: NSWindow?
    let appState = AppState.shared
    let settings = SettingsStore.shared
    let updateReminder = UpdateReminderService.shared
    let settingsNavigation = SettingsNavigationModel()
    var monitor: ClipboardMonitor?
    var viewModel: ClipboardViewModel?
    let hotKey = HotKeyService(id: 1)
    var cancellables = Set<AnyCancellable>()
    var permissionGrantedObserver: AnyCancellable?
    var permissionWindow: NSWindow?
    var onboardingWindow: NSWindow?
    var onboardingFlow: OnboardingFlow?
    var onboardingIsForTesting = false
    lazy var cleanupService = CleanupService(core: appState.core, settings: settings)
    let autoBackupService = AutoBackupService.shared
    var previousApp: NSRunningApplication?
    var clickOutsideMonitor: Any?
    var keyMonitor: Any?
    var appSwitchObserver: Any?
    var activeSpaceObserver: Any?
    /// 连续粘贴模式下抑制 resignKey 自动夺回的 80ms 窗口。
    /// `executePasteFlow` 激活目标 app 时会导致 panel 立刻失去 key window，
    /// 若不抑制，handlePanelResignKey 会在 +150ms 排一次重新夺回，又和粘贴
    /// 完成后 +150ms 的回调重复排一次，造成"失焦立刻夺回 / 粘贴后再夺回"
    /// 双触发。维持此 flag 让焦点恢复路径仍是单一入口。
    var suppressResignKey = false
    var hideGeneration: Int = 0
    var savedPanelOrigin: NSPoint?
    var isProgrammaticMove = false
    var savePositionTask: Task<Void, Never>?
    var backfillTask: Task<Void, Never>?
    var dimensionBackfillTask: Task<Void, Never>?
    var updateReminderSubscription: AnyCancellable?
    var updateBadgeSubscription: AnyCancellable?
    var sparkleUpdater: SPUStandardUpdaterController?
    var isRestoringFailedShortcut = false
    /// 「长按 ⌘」检测:当前是否处于「纯 ⌘ 按住」(未叠加 Shift/Option/Control),
    /// 以及尚未触发的延迟显示任务。
    var isPureCommandHeld = false
    var commandHoldTask: Task<Void, Never>?

    enum PanelPositionKeys {
        static let originX = "panel.savedOriginX"
        static let originY = "panel.savedOriginY"
    }

    /// 「长按 ⌘」阈值:⌘ 需持续按住超过此时长才浮出数字提示。
    /// 取值偏长(刻意的「长按」手势):太短会在用户只是顺手碰一下 ⌘、
    /// 或快速敲组合键时频繁弹出打扰用户;太长则手感迟钝。
    static let commandHoldRevealDelay: Duration = .milliseconds(600)

    /// ⌥+顶排数字键 → 浏览模式映射。文件级常量，避免每次 keyDown 重建字典。
    static let optionDigitBrowseMode: [UInt16: LauncherBrowseMode] = [
        KeyCode.digit0: .all,
        KeyCode.digit1: .pinned,
        KeyCode.digit2: .text,
        KeyCode.digit3: .image,
        KeyCode.digit4: .file,
        KeyCode.digit5: .url,
    ]

    enum SettingsWindowMetrics {
        static let size = NSSize(width: 748, height: 620)
        /// 可拉伸窗口的最小内容尺寸——低于此原生 split view 侧栏/详情会挤坏。
        static let minSize = NSSize(width: 680, height: 520)
    }

    enum OnboardingWindowMetrics {
        static let size = NSSize(width: 560, height: 640)
    }

    enum PermissionWindowMetrics {
        static let size = NSSize(width: 430, height: 486)
    }

    enum KeyboardContext {
        case onboarding(OnboardingFlow)
        case mainPanel(ClipboardViewModel)
        case actionsPalette(ClipboardViewModel)
        case renamingItem(ClipboardViewModel)
        case editingContent(ClipboardViewModel)
        case settingsWindow(SettingsNavigationModel)
        case none
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        setupPanel()
        loadSavedPanelPosition()
        startMonitoring()
        setupHotKey()
        setupSettingsObservers()
        setupUpdateReminderObservers()
        startKeyMonitor()
        startActiveSpaceObserver()
        runCleanupAndReload()
        showLaunchExperienceIfNeeded()
        setupSparkle()
        updateReminder.start()
        _ = autoBackupService  // 确保备份服务在 App 启动时立即初始化，不依赖设置窗口打开
        backfillOcrForExistingImages()
        backfillImageDimensionsForExistingImages()
        reconcileOrphanAttachments()
        // QA 自截图钩子(语义见 QAFlags)。用 showPanel() 而非 togglePanel():
        // showLaunchExperienceIfNeeded() 现在可能已在启动时点亮面板,
        // toggle 会把已可见的面板反向关掉;QA 钩子的意图是「确保面板可见」,showPanel 幂等。
        if QAFlags.showPanelOnLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.showPanel()
                if QAFlags.showActionsOnLaunch {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                        self?.viewModel?.showActionsPalette()
                    }
                }
            }
        }
        if let aux = QAFlags.showAuxWindowOnLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self else { return }
                switch aux {
                // "settings" 开默认 tab；"settings:storage" 等直达指定 tab（自截图逐 tab 验收）。
                case let s where s == "settings" || s.hasPrefix("settings:"):
                    let tabRaw = s.hasPrefix("settings:") ? String(s.dropFirst("settings:".count)) : nil
                    self.openSettingsWindow(select: tabRaw.flatMap(SettingsTab.init(rawValue:)))
                case "onboarding":  self.openOnboardingWindow(permission: .shared)
                case "permission":  self.showPermissionWindowIfNeeded(.shared, activateApp: true, forceShow: true)
                default:            break
                }
            }
        }
    }
}
