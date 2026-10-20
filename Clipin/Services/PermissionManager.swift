import AppKit
import ApplicationServices

/// 检测和引导辅助功能权限
@MainActor
final class PermissionManager: ObservableObject {
    static let shared = PermissionManager()

    @Published private(set) var isAccessibilityGranted: Bool = false

    private var pollTimer: Timer?
    private var lastCheckAt: CFAbsoluteTime = 0
    /// 呼出路径的权限检查节流窗口。AXIsProcessTrusted 走 tccd IPC，tccd 拥堵时会
    /// 卡住调用线程（showPanel 的排障日志已见过）。2s 足够覆盖用户连续呼出/关闭，
    /// 又短到不会让「刚在系统设置里授权」的感知明显滞后。
    private static let minimumCheckInterval: CFAbsoluteTime = 2

    private init() {
        isAccessibilityGranted = AXIsProcessTrusted()
        lastCheckAt = CFAbsoluteTimeGetCurrent()
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
        lastCheckAt = CFAbsoluteTimeGetCurrent()
        isAccessibilityGranted = AXIsProcessTrusted()
        if isAccessibilityGranted {
            stopPolling()
        }
    }

    /// 高频呼出路径专用：距上次检查不足 `minimumCheckInterval` 时复用缓存值。
    /// 粘贴 / 权限窗口 / onboarding 等需要准确结果的路径仍走 `checkNow()`——
    /// 那些场景本来就是用户主动求证权限状态，不能为了节流返回过期结论。
    func checkNowIfStale() {
        guard CFAbsoluteTimeGetCurrent() - lastCheckAt >= Self.minimumCheckInterval else { return }
        checkNow()
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
