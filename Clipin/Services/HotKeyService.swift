import AppKit
import Carbon.HIToolbox

struct HotKeyShortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifierFlagsRaw: UInt
    var key: String

    static let `default` = HotKeyShortcut(
        keyCode: UInt32(kVK_ANSI_V),
        modifierFlagsRaw: NSEvent.ModifierFlags.command.union(.shift).rawValue,
        key: "V"
    )

    var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifierFlagsRaw).intersection(.deviceIndependentFlagsMask)
    }

    var carbonModifiers: UInt32 {
        var modifiers: UInt32 = 0
        if modifierFlags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if modifierFlags.contains(.option) { modifiers |= UInt32(optionKey) }
        if modifierFlags.contains(.control) { modifiers |= UInt32(controlKey) }
        if modifierFlags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        return modifiers
    }

    var displayString: String {
        modifierSymbols + key
    }

    static func capture(from event: NSEvent) -> HotKeyShortcut? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !modifiers.intersection([.command, .option, .control, .shift]).isEmpty else {
            return nil
        }
        guard !Self.ignoredKeyCodes.contains(event.keyCode) else {
            return nil
        }

        let keyCode = UInt32(event.keyCode)
        let key = displayKey(for: keyCode, fallback: event.charactersIgnoringModifiers)
        return HotKeyShortcut(
            keyCode: keyCode,
            modifierFlagsRaw: modifiers.rawValue,
            key: key
        )
    }

    private var modifierSymbols: String {
        var result = ""
        if modifierFlags.contains(.control) { result += "^" }
        if modifierFlags.contains(.option) { result += "⌥" }
        if modifierFlags.contains(.shift) { result += "⇧" }
        if modifierFlags.contains(.command) { result += "⌘" }
        return result
    }

    private static let ignoredKeyCodes: Set<UInt16> = [
        UInt16(kVK_Command),
        UInt16(kVK_RightCommand),
        UInt16(kVK_Shift),
        UInt16(kVK_RightShift),
        UInt16(kVK_Option),
        UInt16(kVK_RightOption),
        UInt16(kVK_Control),
        UInt16(kVK_RightControl),
        UInt16(kVK_CapsLock),
        UInt16(kVK_Function)
    ]

    private static func displayKey(for keyCode: UInt32, fallback: String?) -> String {
        switch Int(keyCode) {
        case kVK_Return: return NSLocalizedString("Return", comment: "")
        case kVK_Tab: return NSLocalizedString("Tab", comment: "")
        case kVK_Space: return NSLocalizedString("Space", comment: "")
        case kVK_Delete: return NSLocalizedString("Delete", comment: "")
        case kVK_Escape: return NSLocalizedString("Esc", comment: "")
        case kVK_ForwardDelete: return NSLocalizedString("Forward Delete", comment: "")
        case kVK_LeftArrow: return NSLocalizedString("Left", comment: "")
        case kVK_RightArrow: return NSLocalizedString("Right", comment: "")
        case kVK_UpArrow: return NSLocalizedString("Up", comment: "")
        case kVK_DownArrow: return NSLocalizedString("Down", comment: "")
        case kVK_Home: return NSLocalizedString("Home", comment: "")
        case kVK_End: return NSLocalizedString("End", comment: "")
        case kVK_PageUp: return NSLocalizedString("Page Up", comment: "")
        case kVK_PageDown: return NSLocalizedString("Page Down", comment: "")
        default:
            if let fallback,
               let first = fallback.trimmingCharacters(in: .whitespacesAndNewlines).first {
                return String(first).uppercased()
            }
            return String(format: NSLocalizedString("Key %d", comment: ""), keyCode)
        }
    }
}

/// 全局快捷键服务 — 使用 Carbon RegisterEventHotKey API
/// 不需要辅助功能权限，是 macOS 注册全局快捷键的标准方式
final class HotKeyService: @unchecked Sendable {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    var onToggle: (() -> Void)?

    func start(with shortcut: HotKeyShortcut) {
        installHandlerIfNeeded()
        register(shortcut)
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let service = Unmanaged<HotKeyService>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async {
                service.onToggle?()
            }
            return noErr
        }, 1, &eventType, selfPtr, &eventHandler)
    }

    private func register(_ shortcut: HotKeyShortcut) {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }

        let hotKeyID = EventHotKeyID(signature: OSType(0x434C5049), id: 1)  // "CLPI"
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if status != noErr {
            print("⚠️ Failed to register hotkey: \(status)")
        }
    }

    func stop() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let handler = eventHandler {
            RemoveEventHandler(handler)
            eventHandler = nil
        }
    }

    deinit {
        stop()
    }
}
