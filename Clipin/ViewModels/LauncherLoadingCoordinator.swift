import Foundation

/// 顶部流光(isLauncherLoading)的引用计数 + 防闪烁状态机。从 ClipboardViewModel 抽出。
/// 多个慢异步源(网络预览 / Quick Look 准备)各占一个 Source;点亮即记时间,熄灭走
/// minimumVisibleSeconds 最小可见时长防一闪而过。可见性翻转时经 onVisibleChange 投影到
/// VM @Published isLauncherLoading。注意:本地 SQLite getItem 这类瞬时操作绝不入此集合——
/// 否则 ↑↓ 连按每次选中都点亮流光,叠加最小可见时长会把它钉成持续重绘,拖卡键盘导航。
@MainActor
final class LauncherLoadingCoordinator {
    enum Source: Hashable {
        case quickLookPreparation
        case previewNetwork(String)
    }

    private let minimumVisibleSeconds: TimeInterval
    private let onVisibleChange: (Bool) -> Void
    private var sources: Set<Source> = []
    private var becameVisibleAt: Date?
    private var hideTask: Task<Void, Never>?
    private var isVisible = false

    init(minimumVisibleSeconds: TimeInterval, onVisibleChange: @escaping (Bool) -> Void) {
        self.minimumVisibleSeconds = minimumVisibleSeconds
        self.onVisibleChange = onVisibleChange
    }

    func set(_ isLoading: Bool, source: Source) {
        if isLoading {
            sources.insert(source)
        } else {
            sources.remove(source)
        }
        if sources.isEmpty {
            scheduleHide()
        } else {
            hideTask?.cancel()
            hideTask = nil
            if !isVisible {
                becameVisibleAt = Date()
                setVisible(true)
            }
        }
    }

    func clear() {
        hideTask?.cancel()
        hideTask = nil
        sources.removeAll()
        if isVisible { setVisible(false) }
        becameVisibleAt = nil
    }

    private func setVisible(_ value: Bool) {
        isVisible = value
        onVisibleChange(value)
    }

    private func scheduleHide() {
        guard isVisible else { return }
        let visibleAt = becameVisibleAt ?? Date()
        let elapsed = Date().timeIntervalSince(visibleAt)
        let remaining = max(0, minimumVisibleSeconds - elapsed)
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            if remaining > 0 {
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            }
            guard let self, !Task.isCancelled, self.sources.isEmpty else { return }
            self.setVisible(false)
            self.becameVisibleAt = nil
            self.hideTask = nil
        }
    }
}
