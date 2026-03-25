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
        pasteboard.clearContents()

        switch item.clipType {
        case .text, .url:
            pasteboard.setString(item.content, forType: .string)
            if item.clipType == .url {
                pasteboard.setString(item.content, forType: .URL)
            }
            return true

        case .image:
            guard let path = item.imagePath,
                  let image = NSImage(contentsOfFile: path) else { return false }
            pasteboard.writeObjects([image])
            return true

        case .file:
            let url = URL(fileURLWithPath: item.content)
            pasteboard.writeObjects([url as NSURL])
            return true
        }
    }

    /// 以纯文本写回剪贴板（去除富文本格式，图片/文件转为路径文本）
    static func writeAsPlainText(_ item: ClipItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        switch item.clipType {
        case .text, .url:
            pasteboard.setString(item.content, forType: .string)
        case .image:
            pasteboard.setString(item.imagePath ?? "image", forType: .string)
        case .file:
            pasteboard.setString(item.content, forType: .string)
        }
    }

    /// 模拟 Cmd+V 按键
    static func simulatePaste() {
        let source = CGEventSource(stateID: .hidSystemState)

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)  // V key
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cghidEventTap)
    }
}
