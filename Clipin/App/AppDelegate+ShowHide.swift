import AppKit
import SwiftUI
import Combine

extension AppDelegate {
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

    @objc func showPanel() {
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
            targetApp: previousApp,
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

    func presentOnboardingIfRequired() -> Bool {
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

    func hidePanel(restorePreviousApp: Bool = true) {
        guard let panel else { return }
        viewModel?.isContinuousPasteEnabled = false
        viewModel?.isInTypingMode = false
        viewModel?.commitRenaming()      // 改名进行中关面板 = 提交（与失焦自动提交一致）
        viewModel?.cancelEditContent()   // 内容编辑进行中关面板 = 放弃，不静默写入
        // 面板关闭时复位「长按 ⌘」状态,避免下次打开残留旧的数字提示
        resetShortcutHint()
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

    func startActiveSpaceObserver() {
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

    func stopActiveSpaceObserver() {
        if let observer = activeSpaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            activeSpaceObserver = nil
        }
    }

    /// 根据当前状态决定面板出现位置：始终以鼠标所在屏幕为目标屏。
    /// 记忆位置只在「就落在目标屏上」时还原（同屏记忆）；鼠标移到别的屏则跟随鼠标在该屏居中（跨屏跟随）。
    func positionPanelForShow() {
        guard let panel else { return }

        // 鼠标当前所在屏幕即用户的操作焦点，作为本次唤起的目标屏
        let target = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let target else { return }
        let f = target.visibleFrame

        // 有记忆位置且就落在目标屏上 → 还原（同屏才记忆）。
        // 用 frame.contains(origin) 判断「位置归属哪块屏」：屏幕 frame 无缝拼接，
        // 任意点恰好属于一块屏；visibleFrame 间有菜单栏/Dock 缝隙会误判归属。
        if let saved = savedPanelOrigin {
            if target.frame.contains(saved) {
                isProgrammaticMove = true
                panel.setFrameOrigin(saved)
                isProgrammaticMove = false
                return
            }
            // 记忆位置不属于任何现存屏幕（旧屏已拔）才清除；仅是跨屏时保留，
            // 用户移回原屏仍能还原原位置。
            if !NSScreen.screens.contains(where: { $0.frame.contains(saved) }) {
                savedPanelOrigin = nil
            }
        }

        // 默认 / 跨屏：在目标屏居中，面板中心位于可见区域 58% 高度处，确保不超出边界
        let size = panel.frame.size
        let x = f.minX + (f.width - size.width) / 2
        let centerY = f.minY + f.height * 0.58
        let y = max(f.minY, min(centerY - size.height / 2, f.maxY - size.height))
        isProgrammaticMove = true
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        isProgrammaticMove = false
    }

    /// 应用启动时从 UserDefaults 恢复面板位置（仅当"跨重启记忆"开启时）。
    func loadSavedPanelPosition() {
        guard settings.rememberPanelPosition else { return }
        let defaults = UserDefaults.standard
        guard let x = defaults.object(forKey: PanelPositionKeys.originX) as? Double,
              let y = defaults.object(forKey: PanelPositionKeys.originY) as? Double else { return }
        savedPanelOrigin = NSPoint(x: x, y: y)
    }

    /// 连续粘贴回焦的前置条件：面板可见、连续粘贴开启、设置/权限/Quick Look 都不在抢焦点。
    /// resignKey 入口和 150ms 后的延迟入口都用这个判断，避免重复条件漂移。
    var canRestoreContinuousPasteFocus: Bool {
        !suppressResignKey
            && !QuickLookPreviewService.shared.isQuickLookOnScreen
            && viewModel?.isContinuousPasteEnabled == true
            && settingsWindow?.isVisible != true
            && permissionWindow?.isVisible != true
    }

    /// 连续粘贴模式下面板失去 key window 时，短暂延迟后自动夺回焦点。
    /// 延迟是为了让用户的鼠标点击先完成（目标输入框获得焦点、frontmostApplication 更新）。
    func handlePanelResignKey() {
        guard canRestoreContinuousPasteFocus else { return }
        scheduleContinuousPasteFocusRestore(after: 0.15)
    }

    /// 连续粘贴模式的回焦要和鼠标点击后的回焦策略保持一致：
    /// 先给目标 app 足够时间完成 first responder / paste，再把 panel 抢回。
    func scheduleContinuousPasteFocusRestore(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self,
                  self.canRestoreContinuousPasteFocus,
                  let panel = self.panel,
                  panel.isVisible else { return }
            panel.makeKeyAndOrderFront(nil)
            self.viewModel?.updateTargetApp(self.resolveTargetApp())
            NotificationCenter.default.post(name: .clipinRestoreSearchFocus, object: nil)
        }
    }

    func startClickOutsideMonitor() {
        guard clickOutsideMonitor == nil else { return }
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, !(self.viewModel?.isContinuousPasteEnabled ?? false) else { return }
            // Quick Look 内容区是跨进程远程视图，在预览里选图片文字的点击也会被全局监视器
            // 收到。只有点击真的落在预览面板「之外」才关面板。坐标换算关键：event.window
            // 是本进程内的 QLPreviewPanel（非 nil），event.locationInWindow 是相对它的窗口
            // 坐标，必须用该窗口转成屏幕坐标，再与预览面板 frame（屏幕坐标）比较；event.window
            // 为 nil（点到其它 app）时 locationInWindow 本就是屏幕坐标。
            let screenPoint = event.window?.convertPoint(toScreen: event.locationInWindow)
                ?? event.locationInWindow
            if QuickLookPreviewService.shared.previewPanelContains(screenPoint: screenPoint) {
                return
            }
            self.hidePanel()
        }
    }

    func stopClickOutsideMonitor() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
    }

    // MARK: - App Switch Observer (连续粘贴模式下提前更新底栏目标应用名)

    func startAppSwitchObserver() {
        guard appSwitchObserver == nil else { return }
        appSwitchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleId = app?.bundleIdentifier
            Task { @MainActor [weak self] in
                guard let self,
                      self.viewModel?.isContinuousPasteEnabled == true,
                      let app,
                      bundleId != Bundle.main.bundleIdentifier else { return }
                self.previousApp = app
                self.viewModel?.updateTargetApp(app)
            }
        }
    }

    func stopAppSwitchObserver() {
        if let observer = appSwitchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            appSwitchObserver = nil
        }
    }

}
