import AppKit

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
        if notification.object as? NSWindow === updateReminderWindow {
            updateReminder.dismissActiveReminder()
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
