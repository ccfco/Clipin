import AppKit
import SwiftUI
import VisionKit

/// 图片预览的 Live Text 覆盖层：拖动选择图片内文字并复制。
///
/// 与下方 OCR 文本块分工：OCR 块给"整段可复制 + 搜索高亮"，覆盖层给"对着图选字"的
/// 直觉操作（与系统预览一致）。覆盖层只负责交互，不重复渲染文字，视觉上无额外负担。
///
/// 约束：
/// - 必须异步分析，禁止在 updateNSView 同步跑 ImageAnalyzer（会卡住选中导航）。
/// - 切换条目必须取消旧分析任务，否则旧图结果可能落到新图上。
/// - `shouldHandleKeyDownEvent` 必须返回 false：↑↓/Esc/Space 的键盘导航由 app 的
///   key monitor 统一负责，覆盖层不能截走。
struct LiveTextOverlay: NSViewRepresentable {
    let image: CGImage
    /// 条目身份（图片路径）。变化即重新分析。
    let identity: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ImageAnalysisOverlayView {
        let view = ImageAnalysisOverlayView(context.coordinator)
        view.preferredInteractionTypes = ImageAnalysisOverlayView.InteractionTypes.textSelection
        context.coordinator.overlay = view
        return view
    }

    func updateNSView(_ view: ImageAnalysisOverlayView, context: Context) {
        context.coordinator.overlay = view
        context.coordinator.analyze(image: image, identity: identity, in: view)
    }

    static func dismantleNSView(_ view: ImageAnalysisOverlayView, coordinator: Coordinator) {
        coordinator.cancel()
    }

    @MainActor
    final class Coordinator: NSObject, ImageAnalysisOverlayViewDelegate {
        weak var overlay: ImageAnalysisOverlayView?
        private var task: Task<Void, Never>?
        private var analyzedIdentity: String?

        func analyze(image: CGImage, identity: String, in view: ImageAnalysisOverlayView) {
            guard analyzedIdentity != identity else { return }
            analyzedIdentity = identity
            task?.cancel()
            view.analysis = nil
            task = Task { [weak view] in
                let analyzer = ImageAnalyzer()
                do {
                    let analysis = try await analyzer.analyze(
                        image,
                        orientation: .up,
                        configuration: ImageAnalyzer.Configuration(.text)
                    )
                    guard !Task.isCancelled else { return }
                    view?.analysis = analysis
                } catch {
                    // 分析失败只意味着没有可选文字；图片本身仍正常显示，不打扰用户。
                    // 复位 identity，让同一张图下次更新时还能重试一次。
                    if analyzedIdentity == identity { analyzedIdentity = nil }
                    ClipinLog.app.debug("Live Text analysis skipped: \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        func cancel() {
            task?.cancel()
            task = nil
        }

        deinit { task?.cancel() }

        // MARK: - ImageAnalysisOverlayViewDelegate

        func overlayView(
            _ overlayView: ImageAnalysisOverlayView,
            shouldBeginAt point: CGPoint,
            forAnalysisType analysisType: ImageAnalysisOverlayView.InteractionTypes
        ) -> Bool {
            true
        }

        /// 覆盖层与图片显示区域完全重合（外层用同一 aspect ratio 约束），
        /// 因此 contentsRect 就是 bounds。
        func contentsRect(for overlayView: ImageAnalysisOverlayView) -> CGRect {
            overlayView.bounds
        }

        func contentView(for overlayView: ImageAnalysisOverlayView) -> NSView? {
            overlayView.superview
        }

        /// 键盘导航归 app 的 key monitor；覆盖层不消费任何按键。
        func overlayView(
            _ overlayView: ImageAnalysisOverlayView,
            shouldHandleKeyDownEvent event: NSEvent
        ) -> Bool {
            false
        }

        func overlayView(
            _ overlayView: ImageAnalysisOverlayView,
            shouldShowMenuForEvent event: NSEvent,
            atPoint point: CGPoint
        ) -> Bool {
            true
        }

        func overlayView(
            _ overlayView: ImageAnalysisOverlayView,
            liveTextButtonDidChangeToVisible visible: Bool
        ) {}

        func overlayView(
            _ overlayView: ImageAnalysisOverlayView,
            highlightSelectedItemsDidChange highlightSelectedItems: Bool
        ) {}

        func textSelectionDidChange(_ overlayView: ImageAnalysisOverlayView) {}

        func overlayView(
            _ overlayView: ImageAnalysisOverlayView,
            updatedMenuFor menu: NSMenu,
            for event: NSEvent,
            at point: CGPoint
        ) -> NSMenu {
            menu
        }

        func overlayView(
            _ overlayView: ImageAnalysisOverlayView,
            needsUpdate menu: NSMenu
        ) {}

        func overlayView(
            _ overlayView: ImageAnalysisOverlayView,
            willOpen menu: NSMenu
        ) {}
    }
}