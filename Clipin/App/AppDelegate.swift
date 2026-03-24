import AppKit
import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private let appState = AppState.shared
    private var monitor: ClipboardMonitor?
    private var viewModel: ClipboardViewModel?
    private let hotKey = HotKeyService()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        setupPanel()
        startMonitoring()
        setupHotKey()
    }

    // MARK: - Menu Bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "clipboard", accessibilityDescription: "Clipin")
            button.action = #selector(togglePanel)
            button.target = self
        }
    }

    // MARK: - Panel

    private func setupPanel() {
        let vm = ClipboardViewModel(core: appState.core)
        vm.onPasteRequested = { [weak self] item in
            self?.performPaste(item)
        }
        vm.onCloseRequested = { [weak self] in
            self?.hidePanel()
        }
        self.viewModel = vm

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.contentView = NSHostingView(rootView: MainPanel(viewModel: vm))
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
            self?.viewModel?.loadItems()
        }
        monitor.start()
        self.monitor = monitor
    }

    // MARK: - Hotkey

    private func setupHotKey() {
        hotKey.onToggle = { [weak self] in
            self?.togglePanel()
        }
        hotKey.start()
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

    private func showPanel() {
        viewModel?.loadItems()
        // makeKeyAndOrderFront 让面板接收键盘事件
        // 不调 NSApp.activate —— 保持之前的应用为前台，粘贴时不需要切回
        panel?.makeKeyAndOrderFront(nil)
    }

    private func hidePanel() {
        panel?.orderOut(nil)
    }

    // MARK: - Paste

    private func performPaste(_ item: ClipItem) {
        // 暂停监控避免把自己写入的内容存一遍
        monitor?.pause()
        PasteService.writeToClipboard(item)

        // 隐藏面板，此时之前的应用自然重新获得键盘焦点
        hidePanel()

        // 极短延迟等面板动画完成，前台应用不变所以不需要切换等待
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            PasteService.simulatePaste()
            self?.monitor?.resume()
        }
    }
}
