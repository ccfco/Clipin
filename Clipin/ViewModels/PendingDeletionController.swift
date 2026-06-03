import Foundation

/// 7s 可撤销删除的「pending id + 倒计时 task」状态机。从 ClipboardViewModel 抽出。
/// 删库副作用不进本类——由调用方在 arm 时注入 commit closure,本类只管何时执行它。
@MainActor
final class PendingDeletionController {
    private(set) var pendingID: String?
    private let window: Duration
    private var task: Task<Void, Never>?
    private var pendingCommit: (() -> Void)?

    init(window: Duration) {
        self.window = window
    }

    /// 置 pending=id 并起 window 倒计时,到点执行 commit。只做 set+timer,
    /// 不隐式处理旧 pending(清旧由调用方显式 commitOther(than:))。
    func arm(id: String, commit: @escaping () -> Void) {
        pendingID = id
        pendingCommit = commit
        task?.cancel()
        let window = self.window
        task = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: window) } catch { return }
            guard let self, self.pendingID == id else { return }
            self.runCommit()
        }
    }

    /// 立即提交当前 pending(若有)。用于 finalize / 退出前收尾。
    func commitNow() {
        guard pendingID != nil else { return }
        task?.cancel()
        runCommit()
    }

    /// 若存在 pending 且 != id,立即提交它(删除新条目前清旧 pending)。
    func commitOther(than id: String) {
        guard let pid = pendingID, pid != id else { return }
        commitNow()
    }

    /// 撤销:取消倒计时、清 pending,不执行 commit。
    func cancel() {
        task?.cancel()
        task = nil
        pendingID = nil
        pendingCommit = nil
    }

    private func runCommit() {
        let commit = pendingCommit
        task = nil
        pendingID = nil
        pendingCommit = nil
        commit?()
    }
}
