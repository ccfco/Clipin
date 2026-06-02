import AppKit
import SwiftUI
import Combine

extension AppDelegate {
    // MARK: - Permission

    func showLaunchExperienceIfNeeded() {
        let permission = PermissionManager.shared

        if settings.shouldShowOnboarding(
            core: appState.core,
            permissionGranted: permission.isAccessibilityGranted,
            hadExistingStorageBeforeBootstrap: appState.hadExistingStorageBeforeBootstrap
        ) {
            openOnboardingWindow(permission: permission)
            // 引导结束后由 finishOnboarding() 负责亮出面板，这里不再叠一层。
            return
        }

        // 不走引导的冷启动也必须给出可见反馈：菜单栏 app 启动后唯一信号是 16pt 小图标，
        // 不点亮面板会让用户以为 app 没启动成功。但开启「登录时启动」意味着用户主动选择了
        // 后台静默自启，登录时不该弹面板；未开启时每一次启动都来自用户手动双击，值得亮出面板。
        //
        // 关键：showPanel() 必须延后到下一个 run loop 轮次，不能在 applicationDidFinishLaunching
        // 的同步上下文里直接调用——实测同步调用时面板不会显示出来。延后一轮等启动序列收尾，
        // showPanel() 才和热键路径在同样的稳态时机执行（QA 自截图钩子早先也用 asyncAfter 绕过此问题）。
        if !settings.launchAtLoginEnabled && QAFlags.showAuxWindowOnLaunch == nil {
            DispatchQueue.main.async { [weak self] in
                self?.showPanel()
            }
        }
        // 权限提示只在用户主动粘贴时按需触发（executePasteFlow），避免每次启动都弹窗打扰
    }

    func openOnboardingWindow(permission: PermissionManager) {
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
            applyAuxiliaryChrome(newWindow, title: "Welcome to Clipin")
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

    func finishOnboarding() {
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

    func showOnboardingForTesting(resetState: Bool) {
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

    func showPermissionWindowIfNeeded(_ pm: PermissionManager = .shared, activateApp: Bool = false, forceShow: Bool = false) {
        pm.checkNow()

        if !forceShow {
            guard !pm.isAccessibilityGranted else {
                permissionWindow?.close()
                return
            }
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
            applyAuxiliaryChrome(newWindow, title: "")
            newWindow.delegate = self
            newWindow.contentView = ClipinWindowHostingView(rootView: PermissionView(
                permission: pm,
                onSkip: { [weak newWindow] in newWindow?.close() }
            ))
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

}
