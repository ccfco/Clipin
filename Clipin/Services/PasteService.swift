import AppKit

/// 模拟粘贴 — 写回剪贴板 + CGEvent 模拟 Cmd+V
enum PasteService {
    /// 将 ClipItem 写回剪贴板并模拟粘贴
    static func paste(_ item: ClipItem) {
        writeToClipboard(item)
        simulatePaste()
    }

    /// 将 ClipItem 写回剪贴板，成功返回 true
    @discardableResult
    static func writeToClipboard(_ item: ClipItem) -> Bool {
        let pasteboard = NSPasteboard.general

        switch item.clipType {
        case .text, .url:
            pasteboard.clearContents()
            let didWriteString = pasteboard.setString(item.content, forType: .string)
            let didWriteURL = item.clipType == .url
                ? pasteboard.setString(item.content, forType: .URL)
                : true
            return didWriteString && didWriteURL

        case .image:
            guard let path = item.imagePath,
                  let image = NSImage(contentsOfFile: path) else { return false }
            pasteboard.clearContents()
            return pasteboard.writeObjects([image])

        case .file:
            let paths = FileClipboardContent.paths(from: item.content)
            let urls = paths.map { URL(fileURLWithPath: $0) as NSURL }
            guard !urls.isEmpty else { return false }
            pasteboard.clearContents()
            return pasteboard.writeObjects(urls)
        }
    }

    /// 以纯文本写回剪贴板（去除富文本格式，图片/文件转为路径文本），成功返回 true
    @discardableResult
    static func writeAsPlainText(_ item: ClipItem) -> Bool {
        let pasteboard = NSPasteboard.general
        let text: String

        switch item.clipType {
        case .text, .url:
            text = item.content
        case .image:
            guard let path = item.imagePath else { return false }
            text = path
        case .file:
            text = FileClipboardContent.paths(from: item.content).joined(separator: "\n")
        }

        guard !text.isEmpty else { return false }
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    /// 已知终端仿真器的 bundle ID 集合（用于图片粘贴时自动切换到 Ctrl+V）
    static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "org.alacritty",
        "io.alacritty",
        "net.kovidgoyal.kitty",
        "com.mitchellh.ghostty",
        "co.zeit.hyper",
    ]

    static func isTerminalApp(_ app: NSRunningApplication?) -> Bool {
        guard let id = app?.bundleIdentifier else { return false }
        return terminalBundleIDs.contains(id)
    }

    /// 模拟粘贴按键。
    /// - `useCtrlV: true` 发送 Ctrl+V（终端 TUI 图片粘贴），默认发送 Cmd+V
    static func simulatePaste(to pid: pid_t? = nil, useCtrlV: Bool = false) {
        let source = CGEventSource(stateID: .hidSystemState)
        let flags: CGEventFlags = useCtrlV ? .maskControl : .maskCommand

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)  // V key
        keyDown?.flags = flags
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyUp?.flags = flags

        if let pid = pid {
            keyDown?.postToPid(pid)
            keyUp?.postToPid(pid)
        } else {
            keyDown?.post(tap: .cghidEventTap)
            keyUp?.post(tap: .cghidEventTap)
        }
    }
}
