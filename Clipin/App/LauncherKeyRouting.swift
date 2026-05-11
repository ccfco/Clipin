import AppKit

struct PaletteActionShortcut: Equatable {
    let badge: String
    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags

    static let pastePlain = Self(badge: "⇧↵", keyCode: 0x24, modifiers: .shift)
    static let preview = Self(badge: "Space", keyCode: 0x31, modifiers: [])
    static let copy = Self(badge: "⌘C", keyCode: 0x08, modifiers: .command)
    static let togglePin = Self(badge: "⌘⇧P", keyCode: 0x23, modifiers: [.command, .shift])
    static let open = Self(badge: "⌘O", keyCode: 0x1F, modifiers: .command)
    static let toggleContinuousPaste = Self(badge: "⌘⇧L", keyCode: 0x25, modifiers: [.command, .shift])
    static let settings = Self(badge: "⌘,", keyCode: 0x2B, modifiers: .command)
    static let delete = Self(badge: "⌘⌫", keyCode: 0x33, modifiers: .command)

    static let all: [Self] = [
        .pastePlain,
        .preview,
        .copy,
        .togglePin,
        .open,
        .toggleContinuousPaste,
        .settings,
        .delete,
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

    static func shouldPreserveTextEditing(
        keyCode: UInt16,
        flags: NSEvent.ModifierFlags,
        firstResponderIsTextView: Bool
    ) -> Bool {
        firstResponderIsTextView
            && keyCode == PaletteActionShortcut.delete.keyCode
            && normalizedFlags(flags) == .command
    }
}
