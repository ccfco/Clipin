import AppKit
import SwiftUI
import Combine

/// 原生 titled/fullSizeContentView 窗口专用 hosting view。
/// 这类窗口的 frame、圆角、裁切和阴影都交给 AppKit，不在 content layer 再画边/裁切。
private final class ClipinWindowHostingView<V: View>: NSHostingView<V> {
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
private final class ClipinBorderlessHostingView<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isOpaque: Bool { false }
    override func updateLayer() {
        super.updateLayer()
        // masksToBounds=true 在 CALayer compositor 层裁掉所有 AppKit subview（含旧 AppKit 毛玻璃 material 子视图），
        // 只用于 borderless 浮层；原生 titled 窗口不能走这里，否则会和 NSWindow frame 叠线。
        layer?.backgroundColor = .clear
        layer?.cornerRadius = ClipinChrome.shellCornerRadius
        layer?.cornerCurve = .continuous
        layer?.allowsEdgeAntialiasing = true
        layer?.borderWidth = 1 / max(window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2, 1)
        layer?.borderColor = separatorLineColor.cgColor
        layer?.masksToBounds = true
        window?.invalidateShadow()
    }

    private var separatorLineColor: NSColor {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark
            ? NSColor.white.withAlphaComponent(0.16)
            : NSColor.black.withAlphaComponent(0.12)
    }
}

/// 主 launcher 专用 hosting view。
/// chrome 玻璃已移交 SwiftUI 根 `GlassEffectContainer`，
/// 这里只保留正确的窗口行为：zero safeAreaInsets / clear layer / 不 mask。
private final class ClipinPanelHostingView<V: View>: NSHostingView<V> {
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
private final class ClipinPanel: NSPanel {
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
private final class ClipinSettingsWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }
}

/// 更新提醒需要轻量浮层：不抢主面板焦点，但要支持首击按钮和 Esc 关闭。
private final class ClipinUpdateReminderPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        close()
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var panel: ClipinPanel?
    private var settingsWindow: NSWindow?
    private var updateReminderWindow: NSWindow?
    private let appState = AppState.shared
    private let settings = SettingsStore.shared
    private let updateReminder = UpdateReminderService.shared
    private let settingsNavigation = SettingsNavigationModel()
    private var monitor: ClipboardMonitor?
    private var viewModel: ClipboardViewModel?
    private let hotKey = HotKeyService(id: 1)
    private var cancellables = Set<AnyCancellable>()
    private var permissionGrantedObserver: AnyCancellable?
    private var permissionWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var onboardingFlow: OnboardingFlow?
    private var onboardingIsForTesting = false
    private lazy var cleanupService = CleanupService(core: appState.core, settings: settings)
    private let autoBackupService = AutoBackupService.shared
    private var previousApp: NSRunningApplication?
    private var clickOutsideMonitor: Any?
    private var keyMonitor: Any?
    private var appSwitchObserver: Any?
    private var activeSpaceObserver: Any?
    private var suppressResignKey = false
    private var hideGeneration: Int = 0
    private var savedPanelOrigin: NSPoint?
    private var isProgrammaticMove = false
    private var savePositionTask: Task<Void, Never>?
    private var backfillTask: Task<Void, Never>?
    private var updateReminderSubscription: AnyCancellable?
    private var updateBadgeSubscription: AnyCancellable?
    private var isRestoringFailedShortcut = false

    private enum PanelPositionKeys {
        static let originX = "panel.savedOriginX"
        static let originY = "panel.savedOriginY"
    }

    private enum SettingsWindowMetrics {
        static let size = NSSize(width: 748, height: 620)
    }

    private enum OnboardingWindowMetrics {
        static let size = NSSize(width: 560, height: 640)
    }

    private enum PermissionWindowMetrics {
        static let size = NSSize(width: 430, height: 486)
    }

    private enum KeyboardContext {
        case onboarding(OnboardingFlow)
        case mainPanel(ClipboardViewModel)
        case actionsPalette(ClipboardViewModel)
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
        updateReminder.start()
        _ = autoBackupService  // 确保备份服务在 App 启动时立即初始化，不依赖设置窗口打开
        backfillOcrForExistingImages()
    }

    // MARK: - Menu Bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = statusItemImage(hasPendingUpdate: updateReminder.latestRelease != nil)
            button.action = #selector(statusBarClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.target = self
        }
    }

    @objc private func statusBarClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            let menu = NSMenu()
            if let latestRelease = updateReminder.latestRelease {
                let updateTitle = String(
                    format: NSLocalizedString("New Version Available: %@", comment: ""),
                    latestRelease.displayVersion
                )
                let updateItem = NSMenuItem(title: updateTitle, action: #selector(openUpdateDetails), keyEquivalent: "")
                updateItem.target = self
                menu.addItem(updateItem)

                let downloadItem = NSMenuItem(title: NSLocalizedString("Download Latest", comment: ""), action: #selector(downloadLatestRelease), keyEquivalent: "")
                downloadItem.target = self
                menu.addItem(downloadItem)

                let releaseItem = NSMenuItem(title: NSLocalizedString("View Release", comment: ""), action: #selector(openReleasePage), keyEquivalent: "")
                releaseItem.target = self
                menu.addItem(releaseItem)

                menu.addItem(NSMenuItem.separator())
            }

            let checkUpdatesItem = NSMenuItem(title: NSLocalizedString("Check for Updates...", comment: ""), action: #selector(checkForUpdates), keyEquivalent: "")
            checkUpdatesItem.target = self
            menu.addItem(checkUpdatesItem)
            let aboutItem = NSMenuItem(title: NSLocalizedString("About Clipin", comment: ""), action: #selector(openAbout), keyEquivalent: "")
            aboutItem.target = self
            menu.addItem(aboutItem)
            menu.addItem(
                NSMenuItem(
                    title: NSLocalizedString("Settings...", comment: ""),
                    action: #selector(openSettings),
                    keyEquivalent: ","
                )
            )
            menu.addItem(NSMenuItem.separator())
            menu.addItem(makeOnboardingMenuItem())
            menu.addItem(NSMenuItem.separator())
            menu.addItem(
                NSMenuItem(
                    title: NSLocalizedString("Quit Clipin", comment: ""),
                    action: #selector(quitApp),
                    keyEquivalent: "q"
                )
            )
            statusItem?.menu = menu
            statusItem?.button?.performClick(nil)
            // 用完后移除 menu，恢复左键 toggle 行为
            statusItem?.menu = nil
        } else {
            togglePanel()
        }
    }

    @objc func openSettings() {
        openSettingsWindow()
    }

    func openAboutFromCommand() {
        openSettingsWindow(select: .about)
    }

    func checkForUpdatesFromCommand() {
        checkForUpdates()
    }

    func showOnboardingFromCommand() {
        showOnboardingForTesting(resetState: false)
    }

    func resetOnboardingStateFromCommand() {
        settings.resetOnboardingForTesting()
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    @objc private func openAbout() {
        openSettingsWindow(select: .about)
    }

    @objc private func checkForUpdates() {
        openSettingsWindow(select: .about)
        updateReminder.checkNow()
    }

    @objc private func openUpdateDetails() {
        openSettingsWindow(select: .about)
    }

    @objc private func openReleasePage() {
        updateReminder.openReleasePage()
    }

    @objc private func downloadLatestRelease() {
        updateReminder.downloadLatestRelease()
    }

    private func makeOnboardingMenuItem() -> NSMenuItem {
        let onboardingTitle = NSLocalizedString("Onboarding", comment: "")
        let onboardingItem = NSMenuItem(title: onboardingTitle, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: onboardingTitle)

        let showItem = NSMenuItem(
            title: NSLocalizedString("Show Onboarding", comment: ""),
            action: #selector(showOnboardingForDebugMenu),
            keyEquivalent: ""
        )
        showItem.target = self
        submenu.addItem(showItem)

        let resetItem = NSMenuItem(
            title: NSLocalizedString("Reset Onboarding State", comment: ""),
            action: #selector(resetOnboardingStateForDebugMenu),
            keyEquivalent: ""
        )
        resetItem.target = self
        submenu.addItem(resetItem)

        onboardingItem.submenu = submenu
        return onboardingItem
    }

    @objc private func showOnboardingForDebugMenu() {
        showOnboardingForTesting(resetState: false)
    }

    @objc private func resetOnboardingStateForDebugMenu() {
        settings.resetOnboardingForTesting()
    }

    // MARK: - Panel

    private func setupPanel() {
        let vm = ClipboardViewModel(core: appState.core)
        vm.onPasteRequested = { [weak self] item in
            self?.performPaste(item)
        }
        vm.onPastePlainRequested = { [weak self] item in
            self?.performPastePlain(item)
        }
        vm.onPasteRepresentationRequested = { [weak self] item, uti in
            self?.performPasteRepresentation(item, uti: uti)
        }
        vm.onCopyRequested = { [weak self] item in
            self?.performCopy(item)
        }
        vm.onCloseRequested = { [weak self] in
            self?.hidePanel()
        }
        vm.onOpenSettingsRequested = { [weak self] in
            guard let self else { return }
            if !(self.viewModel?.isContinuousPasteEnabled ?? false) {
                self.hidePanel()
            }
            self.openSettingsWindow()
        }

        self.viewModel = vm
        let panelSize = NSSize(width: 800, height: 540)

        let panel = ClipinPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // macOS 26 原生 Liquid Glass 窗面(Spotlight/Raycast 那种"整窗即玻璃、内容浮其上"):
        // NSGlassEffectView 是 .glassEffect 的 AppKit 对应,contentView 自动用 Auto Layout
        // 绑定几何。launcher 整体即导航层,整面玻璃合法。cornerRadius 与 shell 一致;窗口
        // frame cornerRadius KVC 在 macOS 26 会自动 concentric 框住玻璃,不手动 mask/border
        // (避免与 NSWindow frame hairline 叠双发丝线 —— CLAUDE.md 旧坑)。
        let glassSurface = NSGlassEffectView()
        glassSurface.cornerRadius = ClipinChrome.shellCornerRadius
        glassSurface.contentView = ClipinPanelHostingView(rootView: MainPanel(viewModel: vm))
        panel.contentView = glassSurface
        panel.isMovableByWindowBackground = true
        panel.title = ""
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.setValue(ClipinChrome.shellCornerRadius, forKey: "cornerRadius")
        [.closeButton, .miniaturizeButton, .zoomButton].forEach { button in
            panel.standardWindowButton(button)?.isHidden = true
        }
        // .titled 窗口始终有系统 window frame：必须用 cornerRadius KVC 把 frame 圆角设成
        // shellCornerRadius，与 SwiftUI 根 .glassEffect/.clipShape 的 24pt 角对齐，否则
        // 默认 titled 角会在四角露出 frame 发丝弧（与设置/引导/权限窗口同一处理）。
        // 旧双发丝线源是已删除的 AppKit material 宿主层抗锯齿边，不是此 KVC。
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.moveToActiveSpace, .transient, .fullScreenAuxiliary]
        panel.becomesKeyOnlyIfNeeded = false
        panel.onResignKey = { [weak self] in
            self?.handlePanelResignKey()
        }
        panel.delegate = self
        panel.invalidateShadow()

        self.panel = panel
    }

    // MARK: - Monitoring

    private func startMonitoring() {
        let monitor = ClipboardMonitor(core: appState.core, settings: settings)
        monitor.onNewItem = { [weak self] in
            self?.runCleanupAndReload(selectLatest: true)
        }
        monitor.start()
        self.monitor = monitor
    }

    // MARK: - Hotkey

    private func setupHotKey() {
        hotKey.onToggle = { [weak self] in
            self?.togglePanel()
        }
    }

    private func setupSettingsObservers() {
        settings.$shortcut
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] shortcut in
                self?.registerGlobalShortcut(shortcut)
            }
            .store(in: &cancellables)

        Publishers.CombineLatest(
            settings.$retentionDays.removeDuplicates(),
            settings.$maxHistoryItems.removeDuplicates()
        )
        .dropFirst()
        .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
        .sink { [weak self] _, _ in
            self?.runCleanupAndReload()
        }
        .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .clipHistoryDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.viewModel?.loadItems()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .clipinPreviewVisibilityDidChange)
            .compactMap { $0.userInfo?["isVisible"] as? Bool }
            .receive(on: RunLoop.main)
            .sink { [weak self] isVisible in
                self?.handlePreviewVisibilityChange(isVisible: isVisible)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .clipinPreviewSelectionDidChange)
            .compactMap { $0.userInfo?["clipID"] as? String }
            .receive(on: RunLoop.main)
            .sink { [weak self] clipID in
                self?.viewModel?.syncSelectionToPreviewedClip(id: clipID)
            }
            .store(in: &cancellables)

        settings.$appearanceOverride
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { override in
                switch override {
                case .system: NSApp.appearance = nil
                case .light:  NSApp.appearance = NSAppearance(named: .aqua)
                case .dark:   NSApp.appearance = NSAppearance(named: .darkAqua)
                }
            }
            .store(in: &cancellables)

        settings.$rememberPanelPosition
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled {
                    // 开启时立即持久化当前内存中的位置（如果有）
                    if let origin = savedPanelOrigin {
                        UserDefaults.standard.set(origin.x, forKey: PanelPositionKeys.originX)
                        UserDefaults.standard.set(origin.y, forKey: PanelPositionKeys.originY)
                    }
                } else {
                    UserDefaults.standard.removeObject(forKey: PanelPositionKeys.originX)
                    UserDefaults.standard.removeObject(forKey: PanelPositionKeys.originY)
                }
            }
            .store(in: &cancellables)
    }

    private func setupUpdateReminderObservers() {
        updateReminderSubscription = updateReminder.$activeReminder
            .receive(on: RunLoop.main)
            .sink { [weak self] release in
                guard let self else { return }
                if let release {
                    self.presentUpdateReminder(for: release)
                } else {
                    self.dismissUpdateReminderWindow()
                }
            }

        updateBadgeSubscription = updateReminder.$latestRelease
            .receive(on: RunLoop.main)
            .sink { [weak self] release in
                self?.statusItem?.button?.image = self?.statusItemImage(hasPendingUpdate: release != nil)
            }
    }

    private func registerGlobalShortcut(_ shortcut: HotKeyShortcut) {
        guard !isRestoringFailedShortcut else { return }
        if hotKey.activeShortcut == shortcut {
            return
        }

        switch hotKey.start(with: shortcut) {
        case .registered:
            settings.clearShortcutRegistrationNote()
        case let .failed(status):
            let restored = hotKey.activeShortcut ?? .default
            settings.reportShortcutRegistrationFailure(
                requested: shortcut,
                restored: restored,
                status: status
            )
            guard settings.shortcut != restored else { return }
            isRestoringFailedShortcut = true
            settings.shortcut = restored
            isRestoringFailedShortcut = false
        }
    }

    // MARK: - Show / Hide

    @objc func togglePanel() {
        if let onboardingWindow, onboardingWindow.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            onboardingWindow.makeKeyAndOrderFront(nil)
            return
        }

        guard let panel else { return }
        if panel.isVisible {
            if viewModel?.isContinuousPasteEnabled == true {
                // 连续粘贴模式下热键不关闭面板，而是夺回键盘焦点
                QuickLookPreviewService.shared.dismiss()
                panel.makeKeyAndOrderFront(nil)
                NotificationCenter.default.post(name: .clipinRestoreSearchFocus, object: nil)
            } else {
                hidePanel()
            }
        } else {
            showPanel()
        }
    }

    @objc private func showPanel() {
        if presentOnboardingIfRequired() {
            return
        }

        guard let panel else { return }

        // 取消正在进行的 hide 动画（递增 generation 使旧 completion 失效）
        hideGeneration += 1
        panel.alphaValue = 1
        panel.animator().alphaValue = 1

        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp = front
        }
        viewModel?.prepareForLauncherPresentation(
            targetAppName: previousApp?.localizedName,
            selectLatest: true
        )

        positionPanelForShow()

        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }

        startClickOutsideMonitor()
        startAppSwitchObserver()
    }

    private func presentOnboardingIfRequired() -> Bool {
        let permission = PermissionManager.shared
        permission.checkNow()

        guard settings.shouldShowOnboarding(
            core: appState.core,
            permissionGranted: permission.isAccessibilityGranted,
            hadExistingStorageBeforeBootstrap: appState.hadExistingStorageBeforeBootstrap
        ) else {
            return false
        }

        openOnboardingWindow(permission: permission)
        return true
    }

    private func hidePanel(restorePreviousApp: Bool = true) {
        guard let panel else { return }
        viewModel?.isContinuousPasteEnabled = false
        viewModel?.hideActionsPalette()
        viewModel?.cancelPreviewPreparation()
        QuickLookPreviewService.shared.dismiss()
        suppressResignKey = false
        stopClickOutsideMonitor()
        stopAppSwitchObserver()

        hideGeneration += 1
        let expectedGeneration = hideGeneration

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.hideGeneration == expectedGeneration else { return }
                panel.orderOut(nil)
                panel.alphaValue = 1
                // settings 窗口可见时不还原焦点，避免把 settings 推到其他 app 后面
                if restorePreviousApp, self.settingsWindow?.isVisible != true {
                    self.previousApp?.activate()
                }
            }
        })
    }

    private func startActiveSpaceObserver() {
        guard activeSpaceObserver == nil else { return }
        activeSpaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self,
                      let panel = self.panel,
                      panel.isVisible else { return }
                self.hidePanel(restorePreviousApp: false)
            }
        }
    }

    private func stopActiveSpaceObserver() {
        if let observer = activeSpaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            activeSpaceObserver = nil
        }
    }

    /// 根据当前状态决定面板出现位置：优先使用已记忆的位置，否则计算友好默认位置。
    private func positionPanelForShow() {
        guard let panel else { return }

        // 有记忆位置且面板矩形与某个屏幕可见区域相交 → 直接还原
        if let saved = savedPanelOrigin {
            let savedRect = NSRect(origin: saved, size: panel.frame.size)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(savedRect) }) {
                isProgrammaticMove = true
                panel.setFrameOrigin(saved)
                isProgrammaticMove = false
                return
            }
            savedPanelOrigin = nil   // 记忆位置已失效（如拔掉外接屏），清除避免重复检查
        }

        // 默认位置：跟随鼠标所在屏幕，面板中心位于可见区域 58% 高度处，确保不超出边界
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let f = screen?.visibleFrame else { return }
        let size = panel.frame.size
        let x = f.minX + (f.width - size.width) / 2
        let centerY = f.minY + f.height * 0.58
        let y = max(f.minY, min(centerY - size.height / 2, f.maxY - size.height))
        isProgrammaticMove = true
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        isProgrammaticMove = false
    }

    /// 应用启动时从 UserDefaults 恢复面板位置（仅当"跨重启记忆"开启时）。
    private func loadSavedPanelPosition() {
        guard settings.rememberPanelPosition else { return }
        let defaults = UserDefaults.standard
        guard let x = defaults.object(forKey: PanelPositionKeys.originX) as? Double,
              let y = defaults.object(forKey: PanelPositionKeys.originY) as? Double else { return }
        savedPanelOrigin = NSPoint(x: x, y: y)
    }

    /// 连续粘贴回焦的前置条件：面板可见、连续粘贴开启、设置/权限/Quick Look 都不在抢焦点。
    /// resignKey 入口和 150ms 后的延迟入口都用这个判断，避免重复条件漂移。
    private var canRestoreContinuousPasteFocus: Bool {
        !suppressResignKey
            && !QuickLookPreviewService.shared.isPresenting
            && viewModel?.isContinuousPasteEnabled == true
            && settingsWindow?.isVisible != true
            && permissionWindow?.isVisible != true
    }

    /// 连续粘贴模式下面板失去 key window 时，短暂延迟后自动夺回焦点。
    /// 延迟是为了让用户的鼠标点击先完成（目标输入框获得焦点、frontmostApplication 更新）。
    private func handlePanelResignKey() {
        guard canRestoreContinuousPasteFocus else { return }
        scheduleContinuousPasteFocusRestore(after: 0.15)
    }

    /// 连续粘贴模式的回焦要和鼠标点击后的回焦策略保持一致：
    /// 先给目标 app 足够时间完成 first responder / paste，再把 panel 抢回。
    private func scheduleContinuousPasteFocusRestore(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self,
                  self.canRestoreContinuousPasteFocus,
                  let panel = self.panel,
                  panel.isVisible else { return }
            panel.makeKeyAndOrderFront(nil)
            self.viewModel?.targetAppName = self.resolveTargetApp()?.localizedName
            NotificationCenter.default.post(name: .clipinRestoreSearchFocus, object: nil)
        }
    }

    private func startClickOutsideMonitor() {
        guard clickOutsideMonitor == nil else { return }
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, !(self.viewModel?.isContinuousPasteEnabled ?? false) else { return }
            self.hidePanel()
        }
    }

    private func stopClickOutsideMonitor() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
    }

    // MARK: - App Switch Observer (连续粘贴模式下提前更新底栏目标应用名)

    private func startAppSwitchObserver() {
        guard appSwitchObserver == nil else { return }
        appSwitchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleId = app?.bundleIdentifier
            let name = app?.localizedName
            Task { @MainActor [weak self] in
                guard let self,
                      self.viewModel?.isContinuousPasteEnabled == true,
                      let app,
                      bundleId != Bundle.main.bundleIdentifier else { return }
                self.previousApp = app
                self.viewModel?.targetAppName = name
            }
        }
    }

    private func stopAppSwitchObserver() {
        if let observer = appSwitchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            appSwitchObserver = nil
        }
    }

    // MARK: - Key Monitor

    private func startKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            switch self.keyboardContext {
            case .onboarding(let flow):
                return self.handleOnboardingKeyEvent(event, flags: flags, flow: flow)
            case .actionsPalette(let vm):
                return self.handlePaletteKeyEvent(event, flags: flags, viewModel: vm)
            case .mainPanel(let vm):
                return self.handlePanelKeyEvent(event, flags: flags, viewModel: vm)
            case .settingsWindow(let nav):
                return self.handleSettingsKeyEvent(event, navigation: nav)
            case .none:
                return event
            }
        }
    }

    /// 为历史图片补跑 OCR（仅处理 ocr_text 为 NULL 的条目，分页直到处理完毕）
    /// 使用 .background 优先级串行处理，不影响 UI 和正常的新图片 OCR；
    /// Task 存储在 backfillTask 供 applicationWillTerminate 取消
    private func backfillOcrForExistingImages() {
        let core = appState.core
        backfillTask = Task.detached(priority: .background) {
            let pageSize: Int32 = 20
            var totalProcessed = 0

            // 每次取最早的 N 条未处理图片（ocr_text IS NULL），处理后再取下一批
            // 无 offset，新增图片不会导致分页跳过
            while !Task.isCancelled {
                let pending = core.getUnprocessedImages(limit: pageSize)
                if pending.isEmpty { break }

                for item in pending {
                    guard !Task.isCancelled else { break }

                    guard let path = item.imagePath else {
                        try? core.updateOcrText(id: item.id, ocrText: "")
                        continue
                    }
                    guard FileManager.default.fileExists(atPath: path) else {
                        try? core.updateOcrText(id: item.id, ocrText: "")
                        continue
                    }

                    let text = await OcrService.recognizeText(at: path)
                    do {
                        try core.updateOcrText(id: item.id, ocrText: text)
                        if !text.isEmpty {
                            NotificationCenter.default.post(name: .clipboardItemOcrUpdated, object: nil)
                        }
                        totalProcessed += 1
                    } catch {
                        print("⚠️ OCR backfill write error for \(item.id): \(error)")
                    }
                }
            }

            if totalProcessed > 0 {
                print("ℹ️ OCR backfill complete: \(totalProcessed) image(s) processed")
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        viewModel?.finalizePendingDeletion()
        backfillTask?.cancel()
        stopActiveSpaceObserver()
    }

    private func runCleanupAndReload(selectLatest: Bool = false) {
        let cleanup = cleanupService
        viewModel?.loadItems(selectLatest: selectLatest)
        Task { @MainActor [weak self] in
            let result = try? await cleanup.runNow()
            if (result?.totalRemoved ?? 0) > 0 {
                self?.viewModel?.loadItems()
            }
        }
    }

    private func handleEscape(for vm: ClipboardViewModel) {
        if vm.clearActiveQueryAndFilters() {
            return
        }
        hidePanel()
    }

    private var keyboardContext: KeyboardContext {
        if let onboardingWindow, onboardingWindow.isVisible, onboardingWindow.isKeyWindow, let onboardingFlow {
            return .onboarding(onboardingFlow)
        }
        if let panel, panel.isVisible, panel.isKeyWindow, let viewModel {
            return viewModel.isShowingActions ? .actionsPalette(viewModel) : .mainPanel(viewModel)
        }
        if let settingsWindow, settingsWindow.isVisible, settingsWindow.isKeyWindow {
            return .settingsWindow(settingsNavigation)
        }
        return .none
    }

    private func handleOnboardingKeyEvent(_ event: NSEvent, flags: NSEvent.ModifierFlags, flow: OnboardingFlow) -> NSEvent? {
        // 注意：方向键的 modifierFlags 里始终包含 .function/.numericPad，不能用全局 flags.isEmpty guard
        switch event.keyCode {
        case KeyCode.arrowLeft, KeyCode.arrowUp:
            flow.goBack()
            return nil
        case KeyCode.arrowRight, KeyCode.arrowDown:
            if flow.step == .welcome || flow.step == .workflow {
                flow.move(1)
                return nil
            }
            return event
        case KeyCode.returnKey where flags.isEmpty:
            flow.activatePrimary()
            return nil
        case KeyCode.escape:
            flow.goBack()
            return nil
        default:
            return event
        }
    }

    private func handleSettingsKeyEvent(_ event: NSEvent, navigation: SettingsNavigationModel) -> NSEvent? {
        switch event.keyCode {
        case KeyCode.arrowUp:   navigation.selectPrev(); return nil
        case KeyCode.arrowDown: navigation.selectNext(); return nil
        default:                return event
        }
    }

    private func handlePaletteKeyEvent(_ event: NSEvent, flags: NSEvent.ModifierFlags, viewModel vm: ClipboardViewModel) -> NSEvent? {
        if let shortcut = PaletteActionShortcut.matching(keyCode: event.keyCode, flags: flags),
           vm.executePaletteShortcut(shortcut) {
            return nil
        }

        switch event.keyCode {
        case KeyCode.arrowUp:
            vm.navigatePalette(delta: -1)
            return nil
        case KeyCode.arrowDown:
            vm.navigatePalette(delta: 1)
            return nil
        case KeyCode.returnKey where flags.isEmpty:
            vm.executeSelectedPaletteAction()
            return nil
        case KeyCode.letterK where flags == .command:
            vm.hideActionsPalette(restoreFocus: true)
            return nil
        case KeyCode.escape:
            vm.hideActionsPalette(restoreFocus: true)
            return nil
        case KeyCode.tab, KeyCode.delete:
            return nil
        default:
            return nil
        }
    }

    private func isIMEComposingInPanel() -> Bool {
        if let textView = panel?.firstResponder as? NSTextView {
            return textView.hasMarkedText()
        }
        if let textView = NSApp.keyWindow?.firstResponder as? NSTextView {
            return textView.hasMarkedText()
        }
        return false
    }

    private func handlePanelKeyEvent(_ event: NSEvent, flags: NSEvent.ModifierFlags, viewModel vm: ClipboardViewModel) -> NSEvent? {
        if isIMEComposingInPanel() {
            switch event.keyCode {
            case KeyCode.tab, KeyCode.arrowUp, KeyCode.arrowDown,
                 KeyCode.returnKey, KeyCode.space, KeyCode.escape:
                return event
            default:
                break
            }
        }

        switch event.keyCode {
        case KeyCode.tab where flags.isEmpty:
            vm.cycleBrowseMode()
            return nil
        case KeyCode.tab where flags == .shift:
            vm.cycleBrowseMode(reverse: true)
            return nil
        case KeyCode.arrowUp:
            vm.selectPrev()
            return nil
        case KeyCode.arrowDown:
            vm.selectNext()
            return nil
        case KeyCode.returnKey where flags.isEmpty:
            vm.pasteSelected()
            return nil
        case KeyCode.space where flags.isEmpty:
            // 其余情况 Space 是 launcher 保留键，有可预览项则预览，否则吞掉
            if vm.canPreviewSelectedItem {
                _ = vm.previewSelected()
            }
            return nil
        case KeyCode.returnKey where flags == .shift:
            vm.pastePlainSelected()
            return nil
        case KeyCode.escape:
            handleEscape(for: vm)
            return nil
        case KeyCode.letterP where flags == [.command, .shift]:
            vm.togglePinSelected()
            return nil
        case KeyCode.delete where flags == .command:
            if LauncherKeyRouting.shouldPreserveTextEditing(
                keyCode: event.keyCode,
                flags: flags,
                firstResponderIsTextView: self.panel?.firstResponder is NSTextView
            ) {
                return event
            }
            vm.deleteSelected()
            return nil
        case KeyCode.letterO where flags == .command:
            vm.openSelected()
            return nil
        case KeyCode.letterC where flags == .command:
            if let responder = self.panel?.firstResponder as? NSTextView,
               responder.selectedRange().length > 0 {
                return event
            }
            vm.copySelected()
            return nil
        case KeyCode.letterK where flags == .command:
            vm.toggleActionsPalette()
            return nil
        case KeyCode.comma where flags == .command:
            if !vm.isContinuousPasteEnabled { self.hidePanel() }
            self.openSettingsWindow()
            return nil
        case KeyCode.letterL where flags == [.command, .shift]:
            vm.toggleContinuousPaste()
            return nil
        case KeyCode.letterH where flags == .option:
            if vm.selectedRepresentationUTIs.contains("public.html") {
                vm.pasteRepresentationSelected(uti: "public.html")
            }
            return nil
        case KeyCode.letterR where flags == .option:
            if vm.selectedRepresentationUTIs.contains("public.rtf") {
                vm.pasteRepresentationSelected(uti: "public.rtf")
            }
            return nil
        default:
            if flags == .command,
               let char = event.charactersIgnoringModifiers,
               let digit = char.first?.wholeNumberValue,
               (1...9).contains(digit) {
                vm.pasteItemAt(index: digit - 1)
                return nil
            }
            if flags == .option {
                let modeMapping: [UInt16: LauncherBrowseMode] = [
                    KeyCode.digit0: .all,
                    KeyCode.digit1: .pinned,
                    KeyCode.digit2: .text,
                    KeyCode.digit3: .image,
                    KeyCode.digit4: .file,
                    KeyCode.digit5: .url,
                ]
                if let mode = modeMapping[event.keyCode] {
                    vm.browseMode = mode
                    return nil
                }
            }
            return event
        }
    }

    private func handlePreviewVisibilityChange(isVisible: Bool) {
        guard !isVisible,
              viewModel?.isContinuousPasteEnabled == true,
              settingsWindow?.isVisible != true,
              permissionWindow?.isVisible != true,
              let panel,
              panel.isVisible else { return }
        panel.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .clipinRestoreSearchFocus, object: nil)
    }

    private func openSettingsWindow(select tab: SettingsTab? = nil) {
        let window: NSWindow
        let isNew: Bool

        if let tab {
            settingsNavigation.select(tab)
        } else {
            settingsNavigation.ensureSelection()
        }

        if let existingWindow = settingsWindow {
            window = existingWindow
            isNew = false
        } else {
            let newWindow = ClipinSettingsWindow(
                contentRect: NSRect(origin: .zero, size: SettingsWindowMetrics.size),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            newWindow.title = "Clipin Settings"
            newWindow.titlebarAppearsTransparent = true
            newWindow.titleVisibility = .hidden
            newWindow.titlebarSeparatorStyle = .none
            newWindow.toolbarStyle = .preference
            newWindow.backgroundColor = .clear
            newWindow.isOpaque = false
            newWindow.isMovableByWindowBackground = true
            newWindow.hasShadow = true
            newWindow.isReleasedWhenClosed = false
            // 隐藏交通灯，避免和 .fullSizeContentView 内容重叠
            [.closeButton, .miniaturizeButton, .zoomButton].forEach { button in
                newWindow.standardWindowButton(button)?.isHidden = true
            }
            // 通过 KVC 设置窗口圆角，让系统 frame 的裁切和 SwiftUI 内容的 shellCornerRadius 对齐
            newWindow.setValue(ClipinChrome.shellCornerRadius, forKey: "cornerRadius")
            newWindow.contentView = ClipinWindowHostingView(
                rootView: SettingsView(
                    settings: settings,
                    updateReminder: updateReminder,
                    autoBackup: autoBackupService,
                    navigation: settingsNavigation,
                    core: appState.core,
                    cleanupService: cleanupService
                )
            )
            settingsWindow = newWindow
            window = newWindow
            isNew = true
        }

        settings.refreshLaunchAtLoginStatus()
        if isNew { window.center() }  // 复用窗口时保留上次位置，符合 macOS 惯例
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func presentUpdateReminder(for release: ReleaseInfo) {
        let window: NSWindow

        if let existingWindow = updateReminderWindow {
            existingWindow.contentView = ClipinBorderlessHostingView(
                rootView: UpdateReminderView(
                    settings: settings,
                    release: release,
                    onLater: { [weak self] in self?.updateReminder.dismissActiveReminder() },
                    onViewRelease: { [weak self] in self?.updateReminder.openReleasePage() },
                    onDownload: { [weak self] in self?.updateReminder.downloadLatestRelease() }
                )
            )
            window = existingWindow
        } else {
            let newWindow = ClipinUpdateReminderPanel(
                contentRect: NSRect(x: 0, y: 0, width: 360, height: 220),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            newWindow.backgroundColor = .clear
            newWindow.isOpaque = false
            newWindow.hasShadow = true
            newWindow.level = .statusBar
            newWindow.isFloatingPanel = true
            newWindow.hidesOnDeactivate = false
            newWindow.collectionBehavior = [.canJoinAllSpaces, .transient]
            newWindow.isReleasedWhenClosed = false
            newWindow.contentView = ClipinBorderlessHostingView(
                rootView: UpdateReminderView(
                    settings: settings,
                    release: release,
                    onLater: { [weak self] in self?.updateReminder.dismissActiveReminder() },
                    onViewRelease: { [weak self] in self?.updateReminder.openReleasePage() },
                    onDownload: { [weak self] in self?.updateReminder.downloadLatestRelease() }
                )
            )
            newWindow.delegate = self
            updateReminderWindow = newWindow
            window = newWindow
        }

        positionUpdateReminderWindow(window)
        window.alphaValue = 0
        window.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }
    }

    private func dismissUpdateReminderWindow() {
        guard let updateReminderWindow else { return }
        let window = updateReminderWindow
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in
                window.orderOut(nil)
                window.alphaValue = 1
            }
        })
    }

    private func positionUpdateReminderWindow(_ window: NSWindow) {
        let size = window.frame.size
        if let button = statusItem?.button, let hostWindow = button.window {
            let buttonFrameInWindow = button.convert(button.bounds, to: nil)
            let buttonFrameOnScreen = hostWindow.convertToScreen(buttonFrameInWindow)
            let x = max(buttonFrameOnScreen.maxX - size.width, buttonFrameOnScreen.minX - 12)
            let y = buttonFrameOnScreen.minY - size.height - 10
            window.setFrameOrigin(NSPoint(x: x, y: y))
            return
        }

        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let x = visible.maxX - size.width - 20
        let y = visible.maxY - size.height - 20
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func statusItemImage(hasPendingUpdate: Bool) -> NSImage? {
        let symbolName = hasPendingUpdate ? "clipboard.badge.exclamationmark" : "clipboard"
        let fallbackName = hasPendingUpdate ? "arrow.down.circle" : "clipboard"
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Clipin")
            ?? NSImage(systemSymbolName: fallbackName, accessibilityDescription: "Clipin")
        image?.isTemplate = true
        return image
    }

    // MARK: - Permission

    private func showLaunchExperienceIfNeeded() {
        let permission = PermissionManager.shared

        if settings.shouldShowOnboarding(
            core: appState.core,
            permissionGranted: permission.isAccessibilityGranted,
            hadExistingStorageBeforeBootstrap: appState.hadExistingStorageBeforeBootstrap
        ) {
            openOnboardingWindow(permission: permission)
        }
        // 权限提示只在用户主动粘贴时按需触发（executePasteFlow），避免每次启动都弹窗打扰
    }

    private func openOnboardingWindow(permission: PermissionManager) {
        let window: NSWindow
        let isNew: Bool

        let flow: OnboardingFlow
        if let existingFlow = onboardingFlow {
            flow = existingFlow
        } else {
            let newFlow = OnboardingFlow(permission: permission) { [weak self] in
                self?.finishOnboarding()
            }
            onboardingFlow = newFlow
            flow = newFlow
        }

        if let existingWindow = onboardingWindow {
            window = existingWindow
            isNew = false
        } else {
            let newWindow = NSWindow(
                contentRect: NSRect(origin: .zero, size: OnboardingWindowMetrics.size),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            newWindow.title = "Welcome to Clipin"
            newWindow.titlebarAppearsTransparent = true
            newWindow.titleVisibility = .hidden
            newWindow.titlebarSeparatorStyle = .none
            newWindow.backgroundColor = .clear
            newWindow.isOpaque = false
            newWindow.isMovableByWindowBackground = true
            newWindow.isReleasedWhenClosed = false
            newWindow.hasShadow = true
            // 隐藏交通灯
            [.closeButton, .miniaturizeButton, .zoomButton].forEach { button in
                newWindow.standardWindowButton(button)?.isHidden = true
            }
            newWindow.setValue(ClipinChrome.shellCornerRadius, forKey: "cornerRadius")
            newWindow.delegate = self
            newWindow.contentView = ClipinWindowHostingView(
                rootView: OnboardingView(permission: permission, flow: flow)
            )
            onboardingWindow = newWindow
            window = newWindow
            isNew = true
        }

        if isNew { window.center() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func finishOnboarding() {
        settings.markOnboardingCompleted()
        onboardingWindow?.close()
        let shouldShowPanel = !onboardingIsForTesting
        onboardingIsForTesting = false
        if shouldShowPanel {
            DispatchQueue.main.async { [weak self] in
                self?.showPanel()
            }
        }
    }

    private func showOnboardingForTesting(resetState: Bool) {
        if resetState {
            settings.resetOnboardingForTesting()
        }

        if panel?.isVisible == true {
            hidePanel()
        }

        onboardingIsForTesting = true
        permissionWindow?.close()
        PermissionManager.shared.checkNow()
        onboardingFlow?.reset()
        openOnboardingWindow(permission: .shared)
    }

    private func showPermissionWindowIfNeeded(_ pm: PermissionManager = .shared, activateApp: Bool = false) {
        pm.checkNow()

        guard !pm.isAccessibilityGranted else {
            permissionWindow?.close()
            return
        }

        let window: NSWindow
        if let existingWindow = permissionWindow {
            window = existingWindow
        } else {
            let newWindow = NSWindow(
                contentRect: NSRect(origin: .zero, size: PermissionWindowMetrics.size),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            newWindow.contentView = ClipinWindowHostingView(rootView: PermissionView(
                permission: pm,
                onSkip: { [weak newWindow] in newWindow?.close() }
            ))
            newWindow.titlebarAppearsTransparent = true
            newWindow.titleVisibility = .hidden
            newWindow.titlebarSeparatorStyle = .none
            newWindow.backgroundColor = .clear
            newWindow.isOpaque = false
            newWindow.isMovableByWindowBackground = true
            newWindow.hasShadow = true
            // 隐藏交通灯
            [.closeButton, .miniaturizeButton, .zoomButton].forEach { button in
                newWindow.standardWindowButton(button)?.isHidden = true
            }
            newWindow.setValue(ClipinChrome.shellCornerRadius, forKey: "cornerRadius")
            newWindow.delegate = self
            newWindow.center()
            // 不设 .floating，让 System Settings 可以自然覆盖在权限窗口上方
            permissionWindow = newWindow
            window = newWindow

            permissionGrantedObserver = pm.$isAccessibilityGranted
                .filter { $0 }
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    // 授权后需要重启让 CGEventTap 在受信任进程里重新创建
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                        self?.permissionGrantedObserver = nil
                        Process.launchedProcess(launchPath: "/usr/bin/open", arguments: [Bundle.main.bundleURL.path])
                        NSApp.terminate(nil)
                    }
                }
        }

        if activateApp {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFrontRegardless()
        }
    }

    // MARK: - Paste

    private func performPaste(_ item: ClipItem) {
        monitor?.pause()

        let representations: [ClipRepresentation]
        if item.clipType == .text || item.clipType == .url {
            representations = (try? appState.core.getRepresentations(id: item.id)) ?? []
        } else {
            representations = []
        }

        guard PasteService.writeAllRepresentations(item, representations: representations) else {
            monitor?.resume()
            viewModel?.showNotice(NSLocalizedString("Could not write this item to the clipboard.", comment: ""), style: .error)
            return
        }
        do { try appState.core.incrementPasteCount(id: item.id) } catch { print("⚠️ Failed to increment paste count: \(error)") }

        // 富文本首次粘贴的教育提示：告诉用户额外格式被保留。
        // 仅在连续粘贴模式触发——普通模式 executePasteFlow 会立即 hidePanel，
        // launcher notice 根本来不及被看到（与 performCopy 的 notice 同一约束）。
        // representations 只含 plain text 之外的额外 UTI，总格式数需 +1。
        if viewModel?.isContinuousPasteEnabled == true,
           !representations.isEmpty,
           settings.richPasteNoticeCountSeen < 3 {
            viewModel?.showNotice(
                String(
                    format: NSLocalizedString("notice.pastedWithFormats", comment: ""),
                    representations.count + 1
                ),
                style: .success
            )
            settings.richPasteNoticeCountSeen += 1
        }

        executePasteFlow(isImage: item.clipType == .image)
    }

    private func performPastePlain(_ item: ClipItem) {
        monitor?.pause()
        guard PasteService.writeAsPlainText(item) else {
            monitor?.resume()
            viewModel?.showNotice(NSLocalizedString("Could not write this item to the clipboard.", comment: ""), style: .error)
            return
        }
        do { try appState.core.incrementPasteCount(id: item.id) } catch { print("⚠️ Failed to increment paste count: \(error)") }
        executePasteFlow(isImage: false)
    }

    private func performPasteRepresentation(_ item: ClipItem, uti: String) {
        monitor?.pause()
        let representations = (try? appState.core.getRepresentations(id: item.id)) ?? []
        guard PasteService.writeRepresentation(item, uti: uti, representations: representations) else {
            monitor?.resume()
            viewModel?.showNotice(NSLocalizedString("Could not write this item to the clipboard.", comment: ""), style: .error)
            return
        }
        do { try appState.core.incrementPasteCount(id: item.id) } catch { print("⚠️ Failed to increment paste count: \(error)") }
        executePasteFlow(isImage: false)
    }

    /// 连续粘贴模式下实时查询 frontmostApplication 作为粘贴目标（LSUIElement app 不会成为 frontmostApplication）；
    /// 非连续粘贴模式使用 showPanel 时快照的 previousApp。
    private func resolveTargetApp() -> NSRunningApplication? {
        let continuousPasteEnabled = viewModel?.isContinuousPasteEnabled ?? false
        if continuousPasteEnabled {
            let front = NSWorkspace.shared.frontmostApplication
            if front?.bundleIdentifier != Bundle.main.bundleIdentifier {
                return front
            }
        }
        return previousApp
    }

    private func executePasteFlow(isImage: Bool = false) {
        let permission = PermissionManager.shared
        permission.checkNow()

        guard permission.isAccessibilityGranted else {
            monitor?.resume()
            viewModel?.showNotice(NSLocalizedString("Accessibility permission is required to paste automatically.", comment: ""), style: .warning)
            showPermissionWindowIfNeeded(permission, activateApp: true)
            return
        }

        let continuousPasteEnabled = viewModel?.isContinuousPasteEnabled ?? false
        let targetApp = resolveTargetApp()

        // 粘贴流程中抑制 resignKey 自动夺回，避免和下面的手动夺回竞争
        if continuousPasteEnabled { suppressResignKey = true }

        if !continuousPasteEnabled {
            hidePanel()
        }

        // 激活目标并精准投递粘贴事件
        targetApp?.activate()

        let useCtrlV = isImage
            && SettingsStore.shared.useCtrlVInTerminalForImages
            && PasteService.isTerminalApp(targetApp)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            PasteService.simulatePaste(to: targetApp?.processIdentifier, useCtrlV: useCtrlV)
            self?.monitor?.resume()

            if continuousPasteEnabled {
                self?.suppressResignKey = false
                self?.scheduleContinuousPasteFocusRestore(after: 0.15)
            }
        }
    }

    private func performCopy(_ item: ClipItem) {
        monitor?.pause()
        guard PasteService.writeToClipboard(item) else {
            monitor?.resume()
            viewModel?.showNotice(NSLocalizedString("Could not write this item to the clipboard.", comment: ""), style: .error)
            return
        }
        let continuousPasteEnabled = viewModel?.isContinuousPasteEnabled ?? false
        if continuousPasteEnabled {
            viewModel?.showNotice(NSLocalizedString("Copied to clipboard.", comment: ""), style: .success)
        }
        if !continuousPasteEnabled { hidePanel() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.monitor?.resume()
            if continuousPasteEnabled {
                NotificationCenter.default.post(name: .clipinRestoreSearchFocus, object: nil)
            }
        }
    }
}

// MARK: - NSWindowDelegate

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === onboardingWindow {
            onboardingWindow = nil
            onboardingFlow = nil
        }
        if notification.object as? NSWindow === permissionWindow {
            permissionWindow = nil
            permissionGrantedObserver = nil
        }
        if notification.object as? NSWindow === updateReminderWindow {
            updateReminder.dismissActiveReminder()
        }
    }

    /// 用户拖拽面板后更新记忆位置。
    /// isProgrammaticMove 防止 showPanel() 里的 setFrameOrigin 误触发。
    /// UserDefaults 写入做 0.3s 防抖，避免拖拽过程中每帧都写。
    func windowDidMove(_ notification: Notification) {
        guard !isProgrammaticMove,
              let panel = self.panel,
              notification.object as? ClipinPanel === panel else { return }
        savedPanelOrigin = panel.frame.origin       // 内存即时更新
        guard settings.rememberPanelPosition else { return }
        savePositionTask?.cancel()
        let origin = panel.frame.origin
        savePositionTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.3))
            guard !Task.isCancelled else { return }
            UserDefaults.standard.set(origin.x, forKey: PanelPositionKeys.originX)
            UserDefaults.standard.set(origin.y, forKey: PanelPositionKeys.originY)
        }
    }
}
