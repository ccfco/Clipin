import AppKit

/// 语义化 Carbon HID 键码，避免 0x7E / 0x35 这类魔法数字散落各处
enum KeyCode {
    static let arrowLeft: UInt16 = 0x7B
    static let arrowRight: UInt16 = 0x7C
    static let arrowDown: UInt16 = 0x7D
    static let arrowUp: UInt16 = 0x7E
    static let returnKey: UInt16 = 0x24
    static let escape: UInt16 = 0x35
    static let space: UInt16 = 0x31
    static let tab: UInt16 = 0x30
    static let delete: UInt16 = 0x33

    static let letterH: UInt16 = 0x04
    static let letterC: UInt16 = 0x08
    static let letterV: UInt16 = 0x09
    static let letterR: UInt16 = 0x0F
    static let letterO: UInt16 = 0x1F
    static let letterP: UInt16 = 0x23
    static let letterL: UInt16 = 0x25
    static let letterK: UInt16 = 0x28
    static let comma: UInt16 = 0x2B

    /// 字母 / 顶排数字键的 keyCode（用于 ⌥+数字 切换浏览模式）
    static let digit0: UInt16 = 29
    static let digit1: UInt16 = 18
    static let digit2: UInt16 = 19
    static let digit3: UInt16 = 20
    static let digit4: UInt16 = 21
    static let digit5: UInt16 = 23
}

struct PaletteActionShortcut: Equatable {
    let badge: String
    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags

    static let pastePlain = Self(badge: "⇧↵", keyCode: KeyCode.returnKey, modifiers: .shift)
    static let preview = Self(badge: "Space", keyCode: KeyCode.space, modifiers: [])
    static let copy = Self(badge: "⌘C", keyCode: KeyCode.letterC, modifiers: .command)
    static let togglePin = Self(badge: "⌘⇧P", keyCode: KeyCode.letterP, modifiers: [.command, .shift])
    static let open = Self(badge: "⌘O", keyCode: KeyCode.letterO, modifiers: .command)
    static let toggleContinuousPaste = Self(badge: "⌘⇧L", keyCode: KeyCode.letterL, modifiers: [.command, .shift])
    static let settings = Self(badge: "⌘,", keyCode: KeyCode.comma, modifiers: .command)
    static let delete = Self(badge: "⌘⌫", keyCode: KeyCode.delete, modifiers: .command)
    static let pasteAsHTML = Self(badge: "⌥H", keyCode: KeyCode.letterH, modifiers: .option)
    static let pasteAsRTF = Self(badge: "⌥R", keyCode: KeyCode.letterR, modifiers: .option)

    static let all: [Self] = [
        .pastePlain,
        .preview,
        .copy,
        .togglePin,
        .open,
        .toggleContinuousPaste,
        .settings,
        .delete,
        .pasteAsHTML,
        .pasteAsRTF,
    ]

    static func matching(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Self? {
        all.first { $0.matches(keyCode: keyCode, flags: flags) }
    }

    func matches(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        self.keyCode == keyCode && modifiers == LauncherKeyRouting.normalizedFlags(flags)
    }
}

enum LauncherKeyRouting {
    static func normalizedFlags(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags.intersection(.deviceIndependentFlagsMask)
    }

    /// 判断当前键事件是否应该交还给系统的文本编辑路径（不被 launcher 全局快捷键吃掉）。
    /// 目前唯一规则：⌘⌫ 在 NSTextView firstResponder 时是"删到行首"，必须放行；
    /// 在主面板列表 firstResponder 时是"删除当前条目"，由 launcher 处理。
    ///
    /// 抽出纯函数 helper 而不是在 AppDelegate 里 inline，是为了让 ⌘⌫ 的边界条件有
    /// 可单测的"锚点"——之前 inline 写在 AppDelegate 的 `if self.panel?.firstResponder
    /// is NSTextView` 没法被 ActionPaletteShortcutTests 验证，只能靠 UI 集成跑。
    static func shouldPreserveTextEditing(
        keyCode: UInt16,
        flags: NSEvent.ModifierFlags,
        firstResponderIsTextView: Bool
    ) -> Bool {
        guard firstResponderIsTextView else { return false }
        return keyCode == KeyCode.delete && normalizedFlags(flags) == .command
    }
}
