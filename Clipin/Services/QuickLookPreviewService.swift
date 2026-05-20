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
    private(set) var isPresenting = false

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

    @MainActor
    private func setPreviewVisibility(_ isVisible: Bool) {
        guard isPresenting != isVisible else { return }
        isPresenting = isVisible
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
