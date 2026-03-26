import AppKit
import SwiftUI
import Combine

/// `.borderless` NSPanel 默认 canBecomeKey = false，必须子类化 override，
/// 否则 makeKeyAndOrderFront 调用后 panel 不是 key window，TextField 无法 focus。
private final class ClipinPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Stay 模式下面板失去 key window 时的回调
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
    private var monitor: ClipboardMonitor?
    private var viewModel: ClipboardViewModel?
    private let hotKey = HotKeyService()
    private var cancellables = Set<AnyCancellable>()
    private var permissionWindow: NSWindow?
    private lazy var cleanupService = CleanupService(core: appState.core, settings: settings)
    private var previousApp: NSRunningApplication?
    private var clickOutsideMonitor: Any?
    private var keyMonitor: Any?
    private var appSwitchObserver: Any?
    private var suppressResignKey = false
    private var hideGeneration: Int = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        setupPanel()
        startMonitoring()
        setupHotKey()
        setupSettingsObservers()
        runCleanupAndReload()
        checkPermissionOnLaunch()
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
            if !(self.viewModel?.isPanelPinned ?? false) {
                self.hidePanel()
            }
            self.openSettingsWindow()
        }

        self.viewModel = vm

        let panel = ClipinPanel(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = NSHostingView(
            rootView: MainPanel(
                viewModel: vm,
                onOpenSettings: { [weak self] in
                    self?.openSettingsWindow()
                }
            )
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

        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.midX - 360, y: f.midY + f.height * 0.1))
        }

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
    }

    // MARK: - Show / Hide

    @objc func togglePanel() {
        guard let panel else { return }
        if panel.isVisible {
            if viewModel?.isPanelPinned == true {
                // Pinned 模式下热键不关闭面板，而是夺回键盘焦点
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

        let screen = NSScreen.screens.first(where: {
            $0.frame.contains(NSEvent.mouseLocation)
        }) ?? NSScreen.main ?? NSScreen.screens.first
        if let f = screen?.visibleFrame {
            let panelSize = panel.frame.size
            let x = f.midX - panelSize.width / 2
            let y = f.midY + f.height * 0.1
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }

        startClickOutsideMonitor()
        startKeyMonitor()
        startAppSwitchObserver()
    }

    private func hidePanel() {
        guard let panel else { return }
        viewModel?.isPanelPinned = false
        viewModel?.hideActionsPalette()
        suppressResignKey = false
        stopClickOutsideMonitor()
        stopKeyMonitor()
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
                self.previousApp?.activate()
            }
        })
    }

    /// Stay 模式下面板失去 key window 时，短暂延迟后自动夺回焦点。
    /// 延迟是为了让用户的鼠标点击先完成（目标输入框获得焦点、frontmostApplication 更新）。
    private func handlePanelResignKey() {
        guard !suppressResignKey,
              viewModel?.isPanelPinned == true,
              settingsWindow?.isVisible != true,
              permissionWindow?.isVisible != true,
              let panel else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self,
                  !self.suppressResignKey,
                  self.viewModel?.isPanelPinned == true,
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
            guard let self, !(self.viewModel?.isPanelPinned ?? false) else { return }
            self.hidePanel()
        }
    }

    private func stopClickOutsideMonitor() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
    }

    // MARK: - App Switch Observer (Pinned 模式下提前更新底栏目标应用名)

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
                      self.viewModel?.isPanelPinned == true,
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
            guard let self, let vm = self.viewModel else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            // Palette 模式：优先拦截导航键，不让其到达搜索框
            if vm.isShowingActions {
                switch event.keyCode {
                case 0x7E:  // ↑
                    vm.navigatePalette(delta: -1); return nil
                case 0x7D:  // ↓
                    vm.navigatePalette(delta: 1); return nil
                case 0x24 where flags.isEmpty:  // Return（无修饰键）
                    vm.executeSelectedPaletteAction(); return nil
                case 0x33 where flags.isEmpty:  // Delete / Backspace
                    vm.removeLastActionQueryCharacter()
                    return nil
                case 0x30:  // Tab / Shift-Tab 在动作面板内不应泄漏到类型筛选
                    return nil
                case 0x35:  // Escape
                    if !vm.clearActionQuery() {
                        vm.hideActionsPalette(restoreFocus: true)
                    }
                    return nil
                default:
                    if shouldRouteEventToPalette(event, flags: flags),
                       let text = event.characters {
                        vm.appendActionQuery(text)
                        return nil
                    }
                    break
                }
            }

            switch event.keyCode {
                    // Tab / Shift-Tab — 全局循环筛选（不依赖搜索框焦点）
            case 0x30 where flags.isEmpty:
                vm.cycleTypeFilter()
                return nil
            case 0x30 where flags == .shift:
                vm.cycleTypeFilter(reverse: true)
                return nil

            // ↑↓ — 项目导航（全局生效，不受焦点影响）
            // 注意：不要使用 flags.isEmpty，箭头键自带 .numericPad 等隐藏修饰符
            case 0x7E:
                vm.selectPrev()
                return nil
            case 0x7D:
                vm.selectNext()
                return nil

            // Return — 粘贴选中项（全局生效）
            case 0x24 where flags.isEmpty:
                vm.pasteSelected()
                return nil

            // ⇧Return — paste as plain text
            case 0x24 where flags == .shift:
                vm.pastePlainSelected()
                return nil

            // Escape — 先退出瞬态状态，再关闭面板；不依赖当前焦点位置
            case 0x35:
                handleEscape(for: vm)
                return nil

            // ⌘⇧P — toggle pin
            case 0x23 where flags == [.command, .shift]:
                vm.togglePinSelected()
                return nil

            // ⌘⌫ — delete
            case 0x33 where flags == .command:
                vm.deleteSelected()
                return nil

            // ⌘O — open URL / reveal copied files in Finder
            case 0x1F where flags == .command:
                vm.openSelected()
                return nil

            // ⌘C — copy to clipboard (without pasting)
            // 如果焦点在文本控件且有选区，放行给系统处理
            case 0x08 where flags == .command:
                if let responder = self.panel?.firstResponder as? NSTextView,
                   responder.selectedRange().length > 0 {
                    return event
                }
                vm.copySelected()
                return nil

            // ⌘K — toggle actions palette
            case 0x28 where flags == .command:
                vm.toggleActionsPalette()
                return nil

            // ⌘, — open settings
            case 0x2B where flags == .command:
                if !vm.isPanelPinned { self.hidePanel() }
                self.openSettingsWindow()
                return nil

            // ⌘⇧L — toggle stay (keep open) mode
            case 0x25 where flags == [.command, .shift]:
                vm.togglePanelPin()
                return nil

            default:
                // ⌘1-9 — quick paste by index
                if flags == .command,
                   let char = event.charactersIgnoringModifiers,
                   let digit = char.first?.wholeNumberValue,
                   (1...9).contains(digit) {
                    vm.pasteItemAt(index: digit - 1)
                    return nil
                }
                // ⌥1-5 — type filter (All/Text/Images/Files/URLs)
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
    }

    private func stopKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
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

    private func shouldRouteEventToPalette(_ event: NSEvent, flags: NSEvent.ModifierFlags) -> Bool {
        guard !flags.contains(.command),
              !flags.contains(.control),
              !flags.contains(.option),
              !flags.contains(.function) else {
            return false
        }

        guard let text = event.characters, !text.isEmpty else { return false }
        return text.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
        }
    }

    private func openSettingsWindow() {
        let window: NSWindow

        if let existingWindow = settingsWindow {
            window = existingWindow
        } else {
            let newWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            newWindow.title = "Clipin Settings"
            newWindow.titlebarAppearsTransparent = true
            newWindow.isReleasedWhenClosed = false
            newWindow.contentView = NSHostingView(
                rootView: SettingsView(settings: settings, core: appState.core)
            )
            settingsWindow = newWindow
            window = newWindow
        }

        settings.refreshLaunchAtLoginStatus()
        window.level = .floating
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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

    /// Pinned 模式下实时查询 frontmostApplication 作为粘贴目标（LSUIElement app 不会成为 frontmostApplication）；
    /// 非 Pinned 模式使用 showPanel 时快照的 previousApp。
    private func resolveTargetApp() -> NSRunningApplication? {
        let pinned = viewModel?.isPanelPinned ?? false
        if pinned {
            let front = NSWorkspace.shared.frontmostApplication
            if front?.bundleIdentifier != Bundle.main.bundleIdentifier {
                return front
            }
        }
        return previousApp
    }

    private func executePasteFlow() {
        let pinned = viewModel?.isPanelPinned ?? false
        let targetApp = resolveTargetApp()

        // 粘贴流程中抑制 resignKey 自动夺回，避免和下面的手动夺回竞争
        if pinned { suppressResignKey = true }

        if !pinned {
            hidePanel()
        }

        // 激活目标并精准投递粘贴事件
        targetApp?.activate()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            PasteService.simulatePaste(to: targetApp?.processIdentifier)
            self?.monitor?.resume()

            if pinned {
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
        let pinned = viewModel?.isPanelPinned ?? false
        if !pinned { hidePanel() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.monitor?.resume()
            if pinned {
                NotificationCenter.default.post(name: .clipinRestoreSearchFocus, object: nil)
            }
        }
    }
}
