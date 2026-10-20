import AppKit
import SwiftUI

extension AppDelegate {
    /// 打开翻译窗口。复用已有窗口时直接换根视图，保留用户调整过的尺寸/位置。
    func openTranslationWindow(for item: ClipItem) {
        let root = TranslationPanelView(item: item)

        if let existing = translationWindow {
            existing.contentView = ClipinWindowHostingView(rootView: root)
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 440),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = NSLocalizedString("Translate", comment: "")
        window.titleVisibility = .visible
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 420, height: 320)
        window.contentView = ClipinWindowHostingView(rootView: root)
        window.center()
        window.setFrameAutosaveName("ClipinTranslationWindow")
        translationWindow = window

        // 普通 window level：辅助窗口禁止 .floating（挡 System Settings / 抢 Cmd+W）
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}