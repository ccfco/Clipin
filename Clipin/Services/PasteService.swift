import AppKit

/// 模拟粘贴 — 写回剪贴板 + CGEvent 模拟 Cmd+V
enum PasteService {
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
            let urls = paths
                .map(URL.init(fileURLWithPath:))
                .filter { FileManager.default.fileExists(atPath: $0.path) }
                .map { $0 as NSURL }
            guard !urls.isEmpty, urls.count == paths.count else { return false }
            pasteboard.clearContents()
            return pasteboard.writeObjects(urls)
        }
    }

    /// Return 路径的"全量回放"：把所有 representation 写到一个 NSPasteboardItem。
    /// 由调用方（ViewModel/AppDelegate）通过 ClipinCore.getRepresentations 先取出 reps 再传入。
    /// pasteboard 参数仅供测试注入；生产路径走 NSPasteboard.general。
    @discardableResult
    static func writeAllRepresentations(
        _ item: ClipItem,
        representations: [ClipRepresentation],
        to pasteboard: NSPasteboard = .general
    ) -> Bool {
        guard item.clipType == .text || item.clipType == .url else {
            return writeToClipboard(item)
        }

        let pbItem = NSPasteboardItem()

        // plain text 始终存在；先写到 pbItem 验证，再 clearContents
        guard pbItem.setString(item.content, forType: .string) else { return false }

        if item.clipType == .url {
            _ = pbItem.setString(item.content, forType: .URL)
        }

        for rep in representations {
            _ = pbItem.setData(rep.data, forType: .init(rep.uti))
        }

        pasteboard.clearContents()
        return pasteboard.writeObjects([pbItem])
    }

    /// 动作面板 "Paste as X" 入口：仅写一种 UTI。
    /// UTI = public.utf8-plain-text 时从 item.content 重建；其他 UTI 需要 representations 里找得到。
    /// 找不到时返回 false 且 NOT clearContents。
    @discardableResult
    static func writeRepresentation(
        _ item: ClipItem,
        uti: String,
        representations: [ClipRepresentation],
        to pasteboard: NSPasteboard = .general
    ) -> Bool {
        let data: Data
        if uti == NSPasteboard.PasteboardType.string.rawValue || uti == "public.utf8-plain-text" {
            guard let bytes = item.content.data(using: .utf8) else { return false }
            data = bytes
        } else {
            guard let rep = representations.first(where: { $0.uti == uti }) else {
                return false  // 不 clearContents
            }
            data = rep.data
        }

        pasteboard.clearContents()
        return pasteboard.setData(data, forType: .init(uti))
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

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: KeyCode.letterV, keyDown: true)
        keyDown?.flags = flags
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: KeyCode.letterV, keyDown: false)
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
