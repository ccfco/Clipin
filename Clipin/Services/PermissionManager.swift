import AppKit
import ApplicationServices

/// 检测和引导辅助功能权限
@MainActor
final class PermissionManager: ObservableObject {
    static let shared = PermissionManager()

    @Published private(set) var isAccessibilityGranted: Bool = false

    private var pollTimer: Timer?

    private init() {
        isAccessibilityGranted = AXIsProcessTrusted()
    }

    /// 请求权限（弹出系统对话框），并开始轮询直到授权
    func requestAndPoll() {
        // 弹出系统提示并跳转到辅助功能设置
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let options = [key: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        startPolling()
    }

    /// 打开系统设置 → 辅助功能，并确保 System Settings 窗口置于最前
    func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open(url, configuration: config) { _, _ in }
        startPolling()
    }

    func checkNow() {
        isAccessibilityGranted = AXIsProcessTrusted()
        if isAccessibilityGranted {
            stopPolling()
        }
    }

    private func startPolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkNow()
            }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}
