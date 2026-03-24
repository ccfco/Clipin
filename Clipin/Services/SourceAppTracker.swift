import AppKit

/// 追踪当前前台应用（用于记录剪贴板内容来源）
@MainActor
final class SourceAppTracker {
    static let shared = SourceAppTracker()

    private(set) var currentApp: NSRunningApplication?

    private var observer: NSObjectProtocol?

    private init() {
        // 记录初始前台 app
        currentApp = NSWorkspace.shared.frontmostApplication

        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated {
                self?.currentApp = app
            }
        }
    }

    var bundleIdentifier: String? {
        currentApp?.bundleIdentifier
    }

    var appName: String? {
        currentApp?.localizedName
    }
}
