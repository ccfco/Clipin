import AppKit
import SwiftUI
import Combine

/// NSHostingView 默认 acceptsFirstMouse = false，导致点击普通 NSWindow 里的 SwiftUI 控件
/// 需要两次点击（第一次激活窗口，第二次才触发动作）。子类化覆盖后，首次点击直接触发动作。
private final class ClipinHostingView<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
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
    private let settingsNavigation = SettingsNavigationModel()
    private var monitor: ClipboardMonitor?
    private var viewModel: ClipboardViewModel?
    private let hotKey = HotKeyService()
    private var cancellables = Set<AnyCancellable>()
    private var permissionWindow: NSWindow?
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

    private enum KeyboardContext {
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
        checkPermissionOnLaunch()
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
            menu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ","))
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

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
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
        panel.contentView = NSHostingView(
            rootView: MainPanel(viewModel: vm)
        )
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
        guard let panel else { return }
        if panel.isVisible {
            if viewModel?.isContinuousPasteEnabled == true {
                // 连续粘贴模式下热键不关闭面板，而是夺回键盘焦点
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

    private func hidePanel() {
        guard let panel else { return }
        viewModel?.isContinuousPasteEnabled = false
        viewModel?.hideActionsPalette()
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
            let pageSize = 200
            var offset = 0
            var totalProcessed = 0

            while !Task.isCancelled {
                let page = core.getItems(limit: Int32(pageSize), offset: Int32(offset), typeFilter: .image)
                let pending = page.filter { $0.ocrText == nil }

                if pending.isEmpty {
                    // 本页无待处理条目：若页面未满说明已到末尾；否则继续翻页
                    if page.count < pageSize { break }
                    offset += pageSize
                    continue
                }

                for item in pending {
                    guard !Task.isCancelled else { break }

                    guard let path = item.imagePath else {
                        // imagePath 为 nil 是数据异常（image 类型必须有路径），记录日志
                        print("⚠️ OCR backfill: item \(item.id) has no imagePath, marking as processed")
                        try? core.updateOcrText(id: item.id, ocrText: "")
                        continue
                    }
                    guard FileManager.default.fileExists(atPath: path) else {
                        // 文件已被清理，标记为已处理避免重复扫描
                        try? core.updateOcrText(id: item.id, ocrText: "")
                        continue
                    }

                    let text = await OcrService.recognizeText(at: path)
                    // 无论是否识别到文字都写回（NULL=未处理，""=处理过但无文字）
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
                offset += pageSize
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
        if let panel, panel.isVisible, panel.isKeyWindow, let viewModel {
            return viewModel.isShowingActions ? .actionsPalette(viewModel) : .mainPanel(viewModel)
        }
        if let settingsWindow, settingsWindow.isVisible, settingsWindow.isKeyWindow {
            return .settingsWindow(settingsNavigation)
        }
        return .none
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

    private func handlePanelKeyEvent(_ event: NSEvent, flags: NSEvent.ModifierFlags, viewModel vm: ClipboardViewModel) -> NSEvent? {
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

    private func openSettingsWindow() {
        let window: NSWindow

        settingsNavigation.ensureSelection()

        if let existingWindow = settingsWindow {
            window = existingWindow
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
                    autoBackup: autoBackupService,
                    navigation: settingsNavigation,
                    core: appState.core
                )
            )
            settingsWindow = newWindow
            window = newWindow
        }

        settings.refreshLaunchAtLoginStatus()
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        focusSettingsSidebar(in: window)
    }

    private func focusSettingsSidebar(in window: NSWindow, attemptsRemaining: Int = 3) {
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }

            guard window.isKeyWindow else {
                guard attemptsRemaining > 0 else { return }
                self.focusSettingsSidebar(in: window, attemptsRemaining: attemptsRemaining - 1)
                return
            }

            guard let tableView: NSTableView = self.findSubview(ofType: NSTableView.self, in: window.contentView) else {
                return
            }

            window.makeFirstResponder(tableView)
        }
    }

    private func findSubview<T: NSView>(ofType type: T.Type, in root: NSView?) -> T? {
        guard let root else { return nil }
        if let match = root as? T {
            return match
        }

        for child in root.subviews {
            if let match: T = findSubview(ofType: type, in: child) {
                return match
            }
        }

        return nil
    }

    // MARK: - Permission

    private func checkPermissionOnLaunch() {
        let pm = PermissionManager.shared
        guard !pm.isAccessibilityGranted else { return }

        let view = PermissionView(permission: pm)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 420),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(rootView: view)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.center()
        window.level = .floating

        // 授权后自动关闭
        pm.$isAccessibilityGranted
            .filter { $0 }
            .first()
            .receive(on: RunLoop.main)
            .sink { [weak window] _ in window?.close() }
            .store(in: &cancellables)

        // floating level 足够让窗口可见，不需要 activate 整个 app
        window.orderFrontRegardless()
        self.permissionWindow = window
    }

    // MARK: - Paste

    private func performPaste(_ item: ClipItem) {
        monitor?.pause()
        guard PasteService.writeToClipboard(item) else {
            monitor?.resume()
            return
        }
        executePasteFlow()
    }

    private func performPastePlain(_ item: ClipItem) {
        monitor?.pause()
        guard PasteService.writeAsPlainText(item) else {
            monitor?.resume()
            return
        }
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
        PasteService.writeToClipboard(item)
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
