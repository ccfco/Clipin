import Foundation

/// launcher 一次性提示的队列状态机。从 ClipboardViewModel 抽出:持有自动消失 task 与
/// 可选 action,通过 onChange 把「当前 notice / nil」投影到 VM 的 @Published launcherNotice。
@MainActor
final class LauncherNoticeCenter {
    private let onChange: (LauncherNotice?) -> Void
    private var task: Task<Void, Never>?
    private var action: (() -> Void)?

    init(onChange: @escaping (LauncherNotice?) -> Void) {
        self.onChange = onChange
    }

    func show(_ text: String,
              style: LauncherNoticeStyle,
              actionTitle: String?,
              duration: Duration,
              action: (() -> Void)?) {
        onChange(LauncherNotice(text: text, style: style, actionTitle: actionTitle))
        self.action = action
        task?.cancel()
        task = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: duration) } catch { return }
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    func performAction() {
        let action = self.action
        dismiss()
        action?()
    }

    func dismiss() {
        task?.cancel()
        task = nil
        action = nil
        onChange(nil)
    }
}
