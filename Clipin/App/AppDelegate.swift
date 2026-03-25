import AppKit
import SwiftUI
import Combine

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
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
        self.viewModel = vm

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView],
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
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
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
        viewModel?.loadItems()

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
        stopClickOutsideMonitor()
        stopKeyMonitor()

        hideGeneration += 1
        let expectedGeneration = hideGeneration

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.hideGeneration == expectedGeneration else { return }
            panel.orderOut(nil)
            panel.alphaValue = 1
            self.previousApp?.activate()
        })
    }

    private func startClickOutsideMonitor() {
        guard clickOutsideMonitor == nil else { return }
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hidePanel()
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

            switch event.keyCode {
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
                return nil

            // ⌘O — open URL/file
            case 0x1F where flags == .command:
                vm.openSelected()
                return nil

            // ⌘C — copy to clipboard (without pasting)
            case 0x08 where flags == .command:
                vm.copySelected()
                return nil

            // ⌘, — open settings
            case 0x2B where flags == .command:
                self.hidePanel()
                self.openSettingsWindow()
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
        hidePanel()

        previousApp?.activate()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            PasteService.simulatePaste()
            self?.monitor?.resume()
        }
    }

    private func performPastePlain(_ item: ClipItem) {
        monitor?.pause()
        PasteService.writeAsPlainText(item)
        hidePanel()

        previousApp?.activate()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            PasteService.simulatePaste()
            self?.monitor?.resume()
        }
    }

    private func performCopy(_ item: ClipItem) {
        monitor?.pause()
        PasteService.writeToClipboard(item)
        hidePanel()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.monitor?.resume()
        }
    }
}
