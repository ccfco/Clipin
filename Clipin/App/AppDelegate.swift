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

    // 呼出面板前记录的前台应用，粘贴后切回
    private var previousApp: NSRunningApplication?

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

        // ViewModel 只通知"用户请求粘贴"，AppDelegate 负责完整编排
        vm.onPasteRequested = { [weak self] item in
            self?.performPaste(item)
        }
        vm.onCloseRequested = { [weak self] in
            self?.hidePanel()
        }

        self.viewModel = vm

        let hostingView = NSHostingView(rootView: MainPanel(viewModel: vm))

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hostingView
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .utilityWindow

        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.midX - 360, y: f.midY + f.height * 0.1))
        }

        self.panel = panel
    }

    // MARK: - Clipboard Monitoring

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

    // MARK: - Panel Show/Hide

    @objc func togglePanel() {
        guard let panel else { return }
        if panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        // 记录当前前台应用，关闭时恢复焦点
        previousApp = NSWorkspace.shared.frontmostApplication
        viewModel?.loadItems()
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func hidePanel() {
        panel?.orderOut(nil)
        previousApp?.activate()
        previousApp = nil
    }

    // MARK: - Paste

    /// 完整粘贴流程：暂停监控 → 写剪贴板 → 隐藏面板 → 等焦点切回 → 模拟 Cmd+V → 恢复监控
    private func performPaste(_ item: ClipItem) {
        guard let target = previousApp else {
            // 没有目标应用时，只写剪贴板
            monitor?.pause()
            PasteService.writeToClipboard(item)
            hidePanel()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.monitor?.resume()
            }
            return
        }

        monitor?.pause()
        PasteService.writeToClipboard(item)

        // 隐藏面板并切回目标应用
        panel?.orderOut(nil)
        previousApp = nil

        // 监听目标应用激活，确认焦点到位后再模拟按键
        var observer: NSObjectProtocol?
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let activated = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  activated.processIdentifier == target.processIdentifier else { return }

            // 目标应用已激活，移除 observer 并模拟粘贴
            if let obs = observer {
                NSWorkspace.shared.notificationCenter.removeObserver(obs)
            }
            PasteService.simulatePaste()
            self?.monitor?.resume()
        }

        target.activate()

        // 保底：2 秒后如果通知没触发也清理（目标应用已经在前台的情况）
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            if let obs = observer {
                NSWorkspace.shared.notificationCenter.removeObserver(obs)
                observer = nil
            }
            self?.monitor?.resume()
        }
    }
}
