import AppKit
import SwiftUI
import Combine
import QuickLookUI

/// `.borderless` NSPanel 默认 canBecomeKey = false，必须子类化 override，
/// 否则 makeKeyAndOrderFront 调用后 panel 不是 key window，TextField 无法 focus。
private final class ClipinPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
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
    private var hideGeneration: Int = 0
    private let quickLookService = QuickLookService()
    private var quickLookItems: [NSURL] = []

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
        vm.onQuickLookRequested = { [weak self] item in
            self?.toggleQuickLook(for: item)
        }
        vm.onCloseRequested = { [weak self] in
            self?.hidePanel()
        }

        Publishers.CombineLatest(
            vm.$searchQuery.removeDuplicates(),
            vm.$typeFilter.removeDuplicates()
        )
        .dropFirst()
        .receive(on: RunLoop.main)
        .sink { [weak self] _, _ in
            self?.closeQuickLook()
        }
        .store(in: &cancellables)
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

        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.midX - 360, y: f.midY + f.height * 0.1))
        }

        self.panel = panel
    }

    // MARK: - Monitoring

    private func startMonitoring() {
        let monitor = ClipboardMonitor(core: appState.core)
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
            hidePanel()
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
    }

    private func hidePanel() {
        guard let panel else { return }
        viewModel?.isPanelPinned = false
        viewModel?.hideActionsPalette()
        stopClickOutsideMonitor()
        stopKeyMonitor()
        closeQuickLook(restorePanelFocus: false)

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
                case 0x35:  // Escape
                    vm.hideActionsPalette(restoreFocus: true)
                    return nil
                default:
                    break  // 其他键（如字符输入）透传给搜索框
                }
            }

            switch event.keyCode {
            // Space — 当搜索框为空时，进入系统 Quick Look
            case 0x31 where flags.isEmpty && vm.canTriggerQuickLookWithSpace:
                vm.quickLookSelected()
                return nil

            // ⌘Y — 无论是否正在搜索，都提供稳定的系统级预览入口
            case 0x10 where flags == .command:
                vm.quickLookSelected()
                return nil

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
                self.refreshQuickLookIfNeeded()
                return nil
            case 0x7D:
                vm.selectNext()
                self.refreshQuickLookIfNeeded()
                return nil

            // Return — 粘贴选中项（全局生效）
            case 0x24 where flags.isEmpty:
                vm.pasteSelected()
                return nil

            // ⇧Return — paste as plain text
            case 0x24 where flags == .shift:
                vm.pastePlainSelected()
                return nil

            // ⌘⇧P — toggle pin
            case 0x23 where flags == [.command, .shift]:
                vm.togglePinSelected()
                return nil

            // ⌘⌫ — delete
            case 0x33 where flags == .command:
                vm.deleteSelected()
                self.refreshQuickLookIfNeeded()
                return nil

            // ⌘O — open URL/file
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
                        self.refreshQuickLookIfNeeded()
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
        PasteService.writeAsPlainText(item)
        executePasteFlow()
    }

    /// 根源解决 Pinned 模式下粘贴错乱的问题：
    /// 原先使用全局 `CGEvent.post(tap: .cghidEventTap)` 发送模拟按键时，HID 会根据当前的全局 Key Window 路由事件。
    /// 因为 Pinned 模式下面板仍是 Key Window，如果切换应用变慢，按键就会弹回给搜索框自己。
    /// 此处的根源解法是：获取准确的目标 app PID，利用 `CGEvent.postToPid` 进行进程级精准投递！
    /// 这样无论面板是否还是 Key Window，应用都能精准收到按键，无需任何闪烁/消失的补丁。
    private func executePasteFlow() {
        let pinned = viewModel?.isPanelPinned ?? false
        let targetApp = pinned ? previousApp : previousApp

        if !pinned {
            hidePanel()
        }

        // 激活目标并精准投递粘贴事件
        targetApp?.activate()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            // 精准打击：只把 Cmd+V 发给目标进程，彻底杜绝发给 Clipin 自己的可能！
            PasteService.simulatePaste(to: targetApp?.processIdentifier)
            self?.monitor?.resume()

            if pinned {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    // Pinned 模式下，粘贴完毕后只需把面板的输入焦点夺回来，面板一直都在！
                    guard let self, let panel = self.panel else { return }
                    panel.makeKeyAndOrderFront(nil)
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

    private func toggleQuickLook(for item: ClipItem) {
        if QLPreviewPanel.sharedPreviewPanelExists(),
           QLPreviewPanel.sharedPreviewPanel().isVisible {
            closeQuickLook()
            return
        }

        showQuickLook(for: item)
    }

    private func refreshQuickLookIfNeeded() {
        guard QLPreviewPanel.sharedPreviewPanelExists(),
              QLPreviewPanel.sharedPreviewPanel().isVisible,
              let item = viewModel?.currentSelectedItem() else { return }
        showQuickLook(for: item, preserveVisibility: true)
    }

    private func showQuickLook(for item: ClipItem, preserveVisibility: Bool = false) {
        guard let panel = activeQuickLookPanel() else { return }

        do {
            let items = try quickLookService.preparePreviewItems(for: item)
            guard !items.isEmpty else {
                closeQuickLook()
                return
            }

            quickLookItems = items
            panel.dataSource = self
            panel.delegate = self
            panel.reloadData()
            panel.currentPreviewItemIndex = 0

            if !preserveVisibility {
                panel.makeKeyAndOrderFront(nil)
            } else {
                panel.refreshCurrentPreviewItem()
            }
        } catch {
            print("⚠️ Failed to prepare Quick Look preview: \(error)")
            closeQuickLook()
        }
    }

    private func closeQuickLook(restorePanelFocus: Bool = true) {
        guard QLPreviewPanel.sharedPreviewPanelExists() else { return }
        let panel = QLPreviewPanel.sharedPreviewPanel()
        if panel.isVisible {
            panel.orderOut(nil)
        }
        panel.dataSource = nil
        panel.delegate = nil
        quickLookItems.removeAll()
        quickLookService.clearStagedFiles()
        if restorePanelFocus {
            self.panel?.makeKeyAndOrderFront(nil)
            NotificationCenter.default.post(name: .clipinRestoreSearchFocus, object: nil)
        }
    }

    private func activeQuickLookPanel() -> QLPreviewPanel? {
        QLPreviewPanel.sharedPreviewPanel()
    }
}

extension AppDelegate: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        quickLookItems.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard quickLookItems.indices.contains(index) else { return nil }
        return quickLookItems[index]
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }

        if event.keyCode == 0x31 || event.keyCode == 0x35 {
            closeQuickLook()
            return true
        }

        return false
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window == activeQuickLookPanel() else { return }
        quickLookItems.removeAll()
        quickLookService.clearStagedFiles()
        panel?.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .clipinRestoreSearchFocus, object: nil)
    }
}
