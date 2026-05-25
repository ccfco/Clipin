import AppKit
import SwiftUI
import Combine

extension AppDelegate {
    // MARK: - Panel

    func setupPanel() {
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

        // QA hover 钩子:去掉 .nonactivatingPanel + 跳过失焦自关,
        // 让合成鼠标能触发真 hover(语义见 QAFlags)。
        let qaHoverable = QAFlags.hoverablePanel
        let panelStyle: NSWindow.StyleMask = qaHoverable
            ? [.titled, .fullSizeContentView]
            : [.titled, .fullSizeContentView, .nonactivatingPanel]
        let panel = ClipinPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: panelStyle,
            backing: .buffered,
            defer: false
        )
        // 窗面 = macOS 26 原生整窗 Liquid Glass(导航层,Spotlight/Raycast 同款)。
        // NSGlassEffectView 是 .glassEffect 的 AppKit 对应,几何绑定到 contentView;
        // launcher 整窗即导航层,整面玻璃合法,底栏命令簇是其上独立 GlassEffectContainer
        // (Apple 文档化的控件玻璃浮导航玻璃,非禁止的无序 glass-on-glass)。跟随系统
        // 外观自适应,不锁 dark——旧"发白发平"是内容铺不透明底压平玻璃,非明暗问题。
        // 决策留痕:v2 的「实心深色 NSView」被用户多轮真机否决(不够原生)。
        let glass = NSGlassEffectView()
        glass.cornerRadius = ClipinChrome.cornerShell
        let host = ClipinPanelHostingView(rootView: MainPanel(viewModel: vm))
        glass.contentView = host
        panel.contentView = glass
        panel.isMovableByWindowBackground = true
        panel.title = ""
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        // .titled 窗口始终有系统 frame:用 cornerRadius KVC 把 frame 圆角对齐 shell 24pt
        // (同设置/引导/权限窗口),否则默认 titled 角会在四角露 frame 发丝弧。不手动
        // masksToBounds——旧双发丝线源是已删除的 AppKit material 宿主层抗锯齿边,踩过坑。
        panel.setValue(ClipinChrome.cornerShell, forKey: "cornerRadius")
        [.closeButton, .miniaturizeButton, .zoomButton].forEach { button in
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.moveToActiveSpace, .transient, .fullScreenAuxiliary]
        panel.becomesKeyOnlyIfNeeded = false
        panel.onResignKey = { [weak self] in
            // 面板失焦后本 app 收不到 .flagsChanged,fail-closed 复位「长按 ⌘」状态,
            // 否则再次获得焦点时可能残留过期的数字提示。
            self?.resetShortcutHint()
            // QA hover 模式:不因失焦自关,保证 screencapture 前面板常驻可被合成鼠标 hover。
            if qaHoverable { return }
            self?.handlePanelResignKey()
        }
        panel.delegate = self
        panel.invalidateShadow()

        self.panel = panel
    }

    // MARK: - Monitoring

    func startMonitoring() {
        let monitor = ClipboardMonitor(core: appState.core, settings: settings)
        monitor.onNewItem = { [weak self] in
            self?.runCleanupAndReload(selectLatest: true)
        }
        monitor.start()
        self.monitor = monitor
    }

    // MARK: - Hotkey

    func setupHotKey() {
        hotKey.onToggle = { [weak self] in
            self?.togglePanel()
        }
    }

    func setupSettingsObservers() {
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

    func setupUpdateReminderObservers() {
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

    func registerGlobalShortcut(_ shortcut: HotKeyShortcut) {
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

}
