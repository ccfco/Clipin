import AppKit

/// 模拟粘贴 — 写回剪贴板 + CGEvent 模拟 Cmd+V
enum PasteService {
    /// 将 ClipItem 写回剪贴板并模拟粘贴
    static func paste(_ item: ClipItem) {
        writeToClipboard(item)
        simulatePaste()
    }

    /// 仅写回剪贴板（不模拟粘贴）
    static func writeToClipboard(_ item: ClipItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        switch item.clipType {
        case .text, .url:
            pasteboard.setString(item.content, forType: .string)
            if item.clipType == .url {
                pasteboard.setString(item.content, forType: .URL)
            }

        case .image:
            if let path = item.imagePath,
               let image = NSImage(contentsOfFile: path) {
                pasteboard.writeObjects([image])
            }

        case .file:
            let url = URL(fileURLWithPath: item.content)
            pasteboard.writeObjects([url as NSURL])
        }
    }

    /// 模拟 Cmd+V 按键
    private static func simulatePaste() {
        let source = CGEventSource(stateID: .hidSystemState)

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)  // V key
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cghidEventTap)
    }
}
