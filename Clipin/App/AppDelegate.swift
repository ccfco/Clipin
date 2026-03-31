import AppKit
import SwiftUI
import Combine

/// NSHostingView 默认 acceptsFirstMouse = false，导致点击普通 NSWindow 里的 SwiftUI 控件
/// 需要两次点击（第一次激活窗口，第二次才触发动作）。子类化覆盖后，首次点击直接触发动作。
private final class ClipinHostingView<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isOpaque: Bool { false }
    override func updateLayer() {
        super.updateLayer()
        // masksToBounds=true 在 CALayer compositor 层裁掉所有 AppKit subview（含 NSVisualEffectView），
        // 是根治圆角透明的唯一正确位置——SwiftUI .clipShape() 不进入 AppKit compositor。
        layer?.backgroundColor = .clear
        layer?.cornerRadius = ClipinChrome.shellCornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }
}

/// `.borderless` NSPanel 默认 canBecomeKey = false，必须子类化 override，
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

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var panel: ClipinPanel?
    private var settingsWindow: NSWindow?
    private let appState = AppState.shared
    private let settings = SettingsStore.shared
    private let updateReminder = UpdateReminderService.shared
    private let settingsNavigation = SettingsNavigationModel()
    private var monitor: ClipboardMonitor?
    private var viewModel: ClipboardViewModel?
    private let hotKey = HotKeyService()
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
    private var suppressResignKey = false
    private var hideGeneration: Int = 0
    private var savedPanelOrigin: NSPoint?
    private var isProgrammaticMove = false
    private var savePositionTask: Task<Void, Never>?
    private var backfillTask: Task<Void, Never>?

    private enum PanelPositionKeys {
        static let originX = "panel.savedOriginX"
        static let originY = "panel.savedOriginY"
    }

    private enum SettingsWindowMetrics {
        static let size = NSSize(width: 720, height: 608)
    }

    private enum OnboardingWindowMetrics {
        static let size = NSSize(width: 560, height: 640)
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
        startKeyMonitor()
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
            button.image = NSImage(systemSymbolName: "clipboard", accessibilityDescription: "Clipin")
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
            menu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ","))
            menu.addItem(NSMenuItem.separator())
            menu.addItem(makeOnboardingMenuItem())
            menu.addItem(NSMenuItem.separator())
            menu.addItem(NSMenuItem(title: "Quit Clipin", action: #selector(quitApp), keyEquivalent: "q"))
            statusItem?.menu = menu
            statusItem?.button?.performClick(nil)
            // 用完后移除 menu，恢复左键 toggle 行为
            statusItem?.menu = nil
        } else {
            togglePanel()
        }
    }

    @objc private func openSettings() {
        openSettingsWindow()
    }

    func openSettingsFromCommand() {
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
        let onboardingItem = NSMenuItem(title: "Onboarding", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Onboarding")

        let showItem = NSMenuItem(title: "Show Onboarding", action: #selector(showOnboardingForDebugMenu), keyEquivalent: "")
        showItem.target = self
        submenu.addItem(showItem)

        let resetItem = NSMenuItem(title: "Reset Onboarding State", action: #selector(resetOnboardingStateForDebugMenu), keyEquivalent: "")
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

        let panel = ClipinPanel(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 540),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = ClipinHostingView(rootView: MainPanel(viewModel: vm))
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .utilityWindow
        panel.becomesKeyOnlyIfNeeded = false
        panel.onResignKey = { [weak self] in
            self?.handlePanelResignKey()
        }
        panel.delegate = self

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
                self?.hotKey.start(with: shortcut)
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
        viewModel?.searchQuery = ""
        viewModel?.typeFilter = nil
        viewModel?.isPinnedView = false
        viewModel?.targetAppName = previousApp?.localizedName
        viewModel?.loadItems(selectLatest: true)

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

    private func hidePanel() {
        guard let panel else { return }
        viewModel?.isContinuousPasteEnabled = false
        viewModel?.hideActionsPalette()
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
                if self.settingsWindow?.isVisible != true {
                    self.previousApp?.activate()
                }
            }
        })
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

    /// 连续粘贴模式下面板失去 key window 时，短暂延迟后自动夺回焦点。
    /// 延迟是为了让用户的鼠标点击先完成（目标输入框获得焦点、frontmostApplication 更新）。
    private func handlePanelResignKey() {
        guard !suppressResignKey,
              !QuickLookPreviewService.shared.isPresenting,
              viewModel?.isContinuousPasteEnabled == true,
              settingsWindow?.isVisible != true,
              permissionWindow?.isVisible != true,
              let panel else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self,
                  !self.suppressResignKey,
                  self.viewModel?.isContinuousPasteEnabled == true,
                  self.settingsWindow?.isVisible != true,
                  self.permissionWindow?.isVisible != true,
                  panel.isVisible else { return }
            panel.makeKeyAndOrderFront(nil)
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
        backfillTask?.cancel()
    }

    private func runCleanupAndReload(selectLatest: Bool = false) {
        let cleanup = cleanupService
        Task.detached(priority: .utility) {
            _ = try? await cleanup.runNow()
        }
        viewModel?.loadItems(selectLatest: selectLatest)
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
        case 0x7B, 0x7E:   // ← ↑ 回上一步
            flow.goBack()
            return nil
        case 0x7C, 0x7D:   // → ↓ 进下一步（只在前两步生效）
            if flow.step == .welcome || flow.step == .workflow {
                flow.move(1)
                return nil
            }
            return event
        case 0x24 where flags.isEmpty:   // Return（不含修饰键）
            flow.activatePrimary()
            return nil
        case 0x35:          // Esc 回上一步
            flow.goBack()
            return nil
        default:
            return event
        }
    }

    private func handleSettingsKeyEvent(_ event: NSEvent, navigation: SettingsNavigationModel) -> NSEvent? {
        switch event.keyCode {
        case 0x7E: navigation.selectPrev(); return nil
        case 0x7D: navigation.selectNext(); return nil
        default:   return event
        }
    }

    private func handlePaletteKeyEvent(_ event: NSEvent, flags: NSEvent.ModifierFlags, viewModel vm: ClipboardViewModel) -> NSEvent? {
        switch event.keyCode {
        case 0x7E:
            vm.navigatePalette(delta: -1)
            return nil
        case 0x7D:
            vm.navigatePalette(delta: 1)
            return nil
        case 0x24 where flags.isEmpty:
            vm.executeSelectedPaletteAction()
            return nil
        case 0x28 where flags == .command:
            vm.hideActionsPalette(restoreFocus: true)
            return nil
        case 0x35:
            vm.hideActionsPalette(restoreFocus: true)
            return nil
        case 0x30, 0x33:
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
            case 0x30, 0x7E, 0x7D, 0x24, 0x31, 0x35:
                return event
            default:
                break
            }
        }

        switch event.keyCode {
        case 0x30 where flags.isEmpty:
            vm.cycleTypeFilter()
            return nil
        case 0x30 where flags == .shift:
            vm.cycleTypeFilter(reverse: true)
            return nil
        case 0x7E:
            vm.selectPrev()
            return nil
        case 0x7D:
            vm.selectNext()
            return nil
        case 0x24 where flags.isEmpty:
            vm.pasteSelected()
            return nil
        case 0x31 where flags.isEmpty:
            // 其余情况 Space 是 launcher 保留键，有可预览项则预览，否则吞掉
            if vm.canPreviewSelectedItem {
                _ = vm.previewSelected()
            }
            return nil
        case 0x24 where flags == .shift:
            vm.pastePlainSelected()
            return nil
        case 0x35:
            handleEscape(for: vm)
            return nil
        case 0x23 where flags == [.command, .shift]:
            vm.togglePinSelected()
            return nil
        case 0x33 where flags == .command:
            vm.deleteSelected()
            return nil
        case 0x1F where flags == .command:
            vm.openSelected()
            return nil
        case 0x08 where flags == .command:
            if let responder = self.panel?.firstResponder as? NSTextView,
               responder.selectedRange().length > 0 {
                return event
            }
            vm.copySelected()
            return nil
        case 0x28 where flags == .command:
            vm.toggleActionsPalette()
            return nil
        case 0x2B where flags == .command:
            if !vm.isContinuousPasteEnabled { self.hidePanel() }
            self.openSettingsWindow()
            return nil
        case 0x25 where flags == [.command, .shift]:
            vm.toggleContinuousPaste()
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
                let optMapping: [UInt16: Int] = [18: 0, 19: 1, 20: 2, 21: 3, 23: 4]
                if let index = optMapping[event.keyCode] {
                    vm.setTypeFilterByIndex(index)
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
            let newWindow = NSWindow(
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
            newWindow.contentView = ClipinHostingView(
                rootView: SettingsView(
                    settings: settings,
                    updateReminder: updateReminder,
                    autoBackup: autoBackupService,
                    navigation: settingsNavigation,
                    core: appState.core
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
            // 不设 .floating，让 System Settings 等系统窗口可以自然覆盖在上方
            newWindow.delegate = self
            newWindow.contentView = ClipinHostingView(
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
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 460),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            newWindow.contentView = NSHostingView(rootView: PermissionView(
                permission: pm,
                onSkip: { [weak newWindow] in newWindow?.close() }
            ))
            newWindow.titlebarAppearsTransparent = true
            newWindow.titleVisibility = .hidden
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
        guard PasteService.writeToClipboard(item) else {
            monitor?.resume()
            return
        }
        try? appState.core.incrementPasteCount(id: item.id)
        executePasteFlow()
    }

    private func performPastePlain(_ item: ClipItem) {
        monitor?.pause()
        guard PasteService.writeAsPlainText(item) else {
            monitor?.resume()
            return
        }
        try? appState.core.incrementPasteCount(id: item.id)
        executePasteFlow()
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

    private func executePasteFlow() {
        let permission = PermissionManager.shared
        permission.checkNow()

        guard permission.isAccessibilityGranted else {
            monitor?.resume()
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

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            PasteService.simulatePaste(to: targetApp?.processIdentifier)
            self?.monitor?.resume()

            if continuousPasteEnabled {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    guard let self else { return }
                    self.suppressResignKey = false
                    guard let panel = self.panel else { return }
                    panel.makeKeyAndOrderFront(nil)
                    self.viewModel?.targetAppName = self.resolveTargetApp()?.localizedName
                    NotificationCenter.default.post(name: .clipinRestoreSearchFocus, object: nil)
                }
            }
        }
    }

    private func performCopy(_ item: ClipItem) {
        monitor?.pause()
        guard PasteService.writeToClipboard(item) else {
            monitor?.resume()
            return
        }
        let continuousPasteEnabled = viewModel?.isContinuousPasteEnabled ?? false
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
