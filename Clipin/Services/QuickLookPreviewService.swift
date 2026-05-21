import AppKit
import Foundation
import Quartz

final class QuickLookPreviewService: NSObject, @unchecked Sendable {
    @MainActor static let shared = QuickLookPreviewService()

    private struct PreviewPanelEntry {
        let clipID: String
        let item: NSURL
    }

    private var previewEntries: [PreviewPanelEntry] = []
    /// 上次已广播的预览可见性——仅用于 setPreviewVisibility 去重。
    /// 「预览此刻是否在屏上」的真相一律走 isQuickLookOnScreen 直接查系统单例，
    /// 不靠这个缓存标志：QLPreviewPanel 的关闭回调不在所有路径都可靠触发，缓存会漂移。
    private var publishedVisibility = false

    @MainActor
    func present(session: ClipPreviewSession) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !session.entries.isEmpty, session.entries.indices.contains(session.selectedIndex) else { return }
        previewEntries = session.entries.map { entry in
            PreviewPanelEntry(clipID: entry.clipID, item: entry.url as NSURL)
        }
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = session.selectedIndex
        publishSelectionChange(for: session.selectedIndex)
        NSApp.activate(ignoringOtherApps: true)
        setPreviewVisibility(true)
        panel.makeKeyAndOrderFront(nil)
    }

    @MainActor
    func dismiss() {
        dispatchPrecondition(condition: .onQueue(.main))
        clearPreviewSession()
        guard let panel = QLPreviewPanel.shared(), panel.isVisible else {
            setPreviewVisibility(false)
            return
        }
        panel.orderOut(nil)
        setPreviewVisibility(false)
    }

    /// Quick Look 预览面板此刻是否真的在屏上。直接查系统共享单例，不依赖任何缓存标志——
    /// 这段代码绕过了 QLPreviewPanelController 责任链，previewPanelWillClose 关闭回调
    /// 并不在所有路径都可靠触发，缓存标志会漂移成「预览已关但标志仍为真」。
    @MainActor
    var isQuickLookOnScreen: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && (QLPreviewPanel.shared()?.isVisible ?? false)
    }

    /// 给定屏幕坐标是否落在可见的预览面板范围内。全局点击监视器用它区分
    /// 「在预览里操作（选 Live Text 文字）」和「点到了预览之外」。
    @MainActor
    func previewPanelContains(screenPoint: NSPoint) -> Bool {
        guard isQuickLookOnScreen, let panel = QLPreviewPanel.shared() else { return false }
        return panel.frame.contains(screenPoint)
    }

    @MainActor
    private func setPreviewVisibility(_ isVisible: Bool) {
        guard publishedVisibility != isVisible else { return }
        publishedVisibility = isVisible
        NotificationCenter.default.post(
            name: .clipinPreviewVisibilityDidChange,
            object: self,
            userInfo: ["isVisible": isVisible]
        )
    }

    @MainActor
    private func publishSelectionChange(for index: Int) {
        guard previewEntries.indices.contains(index) else { return }
        NotificationCenter.default.post(
            name: .clipinPreviewSelectionDidChange,
            object: self,
            userInfo: ["clipID": previewEntries[index].clipID]
        )
    }

    @MainActor
    private func stepPreview(delta: Int, in panel: QLPreviewPanel) -> Bool {
        guard !previewEntries.isEmpty else { return false }
        let currentIndex = panel.currentPreviewItemIndex == NSNotFound ? 0 : panel.currentPreviewItemIndex
        let nextIndex = max(0, min(previewEntries.count - 1, currentIndex + delta))
        guard nextIndex != currentIndex else { return false }
        panel.currentPreviewItemIndex = nextIndex
        publishSelectionChange(for: nextIndex)
        return true
    }

    @MainActor
    private func clearPreviewSession() {
        previewEntries = []
    }
}

extension QuickLookPreviewService: QLPreviewPanelDataSource {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        dispatchPrecondition(condition: .onQueue(.main))
        return previewEntries.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        dispatchPrecondition(condition: .onQueue(.main))
        guard previewEntries.indices.contains(index) else { return nil }
        return previewEntries[index].item
    }
}

extension QuickLookPreviewService: QLPreviewPanelDelegate {
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard event.type == .keyDown else { return false }

        // 箭头键自带 .numericPad/.function，只过滤真正的修饰键（shift/ctrl/opt/cmd）
        let significantFlags = event.modifierFlags.intersection([.shift, .control, .option, .command])
        guard significantFlags.isEmpty else { return false }

        switch event.keyCode {
        case KeyCode.arrowLeft, KeyCode.arrowUp:
            Task { @MainActor [weak self] in
                self?.stepPreview(delta: -1, in: panel)
            }
            return true
        case KeyCode.arrowRight, KeyCode.arrowDown:
            Task { @MainActor [weak self] in
                self?.stepPreview(delta: 1, in: panel)
            }
            return true
        default:
            return false
        }
    }

    func previewPanelWillClose(_ panel: QLPreviewPanel!) {
        Task { @MainActor [weak self] in
            self?.clearPreviewSession()
            self?.setPreviewVisibility(false)
        }
    }
}
