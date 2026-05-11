import AppKit
import Carbon.HIToolbox

enum HotKeyRegistrationResult: Equatable {
    case registered
    case failed(OSStatus)
}

protocol HotKeyRegistration: AnyObject {
    func unregister()
}

protocol HotKeyEventListener: AnyObject {
    func stop()
}

enum HotKeyBackendRegistrationResult {
    case registered(HotKeyRegistration)
    case failure(OSStatus)
}

enum HotKeyBackendListenerResult {
    case listening(HotKeyEventListener)
    case failure(OSStatus)
}

protocol HotKeyBackend {
    func startListening(onFire: @escaping (UInt32) -> Void) -> HotKeyBackendListenerResult
    func register(shortcut: HotKeyShortcut, signature: OSType, id: UInt32) -> HotKeyBackendRegistrationResult
}

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
/// 不需要辅助功能权限，是 macOS 注册全局快捷键的标准方式。
/// 每个实例注册一个独立的 hotKeyID，回调里通过 GetEventParameter 检查实际触发的 id，
/// 避免多实例时所有实例都响应任意热键。
final class HotKeyService: @unchecked Sendable {
    /// Carbon 签名 "CLPI"，所有 Clipin 热键共用同一签名，用 id 区分。
    private static let signature = OSType(0x434C5049)

    private let hotKeyID: UInt32
    private let backend: HotKeyBackend
    private var registration: HotKeyRegistration?
    private var listener: HotKeyEventListener?
    private var registrationGeneration: UInt32 = 0
    private var activeRegistrationID: UInt32?
    private(set) var activeShortcut: HotKeyShortcut?

    var onToggle: (() -> Void)?

    /// - Parameter id: 每个实例必须使用唯一 id（当前仅 1=主面板）
    init(id: UInt32 = 1, backend: HotKeyBackend = CarbonHotKeyBackend()) {
        self.hotKeyID = id
        self.backend = backend
    }

    @discardableResult
    func start(with shortcut: HotKeyShortcut) -> HotKeyRegistrationResult {
        if listener == nil {
            switch backend.startListening(onFire: { [weak self] id in
                self?.handleHotKeyEvent(id: id)
            }) {
            case let .listening(listener):
                self.listener = listener
            case let .failure(status):
                print("⚠️ Failed to install hotkey handler id=\(hotKeyID): \(status)")
                return .failed(status)
            }
        }

        let candidateID = nextRegistrationID()
        switch backend.register(shortcut: shortcut, signature: Self.signature, id: candidateID) {
        case let .registered(newRegistration):
            let previousRegistration = registration
            registration = newRegistration
            activeShortcut = shortcut
            activeRegistrationID = candidateID
            previousRegistration?.unregister()
            return .registered
        case let .failure(status):
            print("⚠️ Failed to register hotkey id=\(hotKeyID): \(status)")
            return .failed(status)
        }
    }

    private func nextRegistrationID() -> UInt32 {
        registrationGeneration = registrationGeneration &+ 1
        return (hotKeyID << 16) &+ registrationGeneration
    }

    private func handleHotKeyEvent(id: UInt32) {
        guard id == activeRegistrationID else { return }
        if Thread.isMainThread {
            onToggle?()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.onToggle?()
            }
        }
    }

    func stop() {
        registration?.unregister()
        registration = nil
        activeRegistrationID = nil
        activeShortcut = nil
        listener?.stop()
        listener = nil
    }

    deinit {
        stop()
    }
}

private final class CarbonHotKeyCallbackBox {
    let onFire: (UInt32) -> Void

    init(onFire: @escaping (UInt32) -> Void) {
        self.onFire = onFire
    }
}

private final class CarbonHotKeyEventListener: HotKeyEventListener {
    private var handler: EventHandlerRef?
    private let callbackBox: CarbonHotKeyCallbackBox

    init(handler: EventHandlerRef, callbackBox: CarbonHotKeyCallbackBox) {
        self.handler = handler
        self.callbackBox = callbackBox
    }

    func stop() {
        if let handler {
            RemoveEventHandler(handler)
            self.handler = nil
        }
        _ = callbackBox
    }

    deinit {
        stop()
    }
}

private final class CarbonHotKeyRegistration: HotKeyRegistration {
    private var ref: EventHotKeyRef?

    init(ref: EventHotKeyRef) {
        self.ref = ref
    }

    func unregister() {
        if let ref {
            UnregisterEventHotKey(ref)
            self.ref = nil
        }
    }

    deinit {
        unregister()
    }
}

private struct CarbonHotKeyBackend: HotKeyBackend {
    func startListening(onFire: @escaping (UInt32) -> Void) -> HotKeyBackendListenerResult {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var eventHandler: EventHandlerRef?
        let callbackBox = CarbonHotKeyCallbackBox(onFire: onFire)

        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let userData, let event else { return OSStatus(eventNotHandledErr) }
            let box = Unmanaged<CarbonHotKeyCallbackBox>.fromOpaque(userData).takeUnretainedValue()

            var firedID = EventHotKeyID()
            let paramStatus = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &firedID
            )
            guard paramStatus == noErr else {
                return OSStatus(eventNotHandledErr)
            }

            box.onFire(firedID.id)
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(callbackBox).toOpaque(), &eventHandler)

        guard status == noErr, let eventHandler else {
            return .failure(status)
        }
        return .listening(CarbonHotKeyEventListener(handler: eventHandler, callbackBox: callbackBox))
    }

    func register(shortcut: HotKeyShortcut, signature: OSType, id: UInt32) -> HotKeyBackendRegistrationResult {
        let carbonID = EventHotKeyID(signature: signature, id: id)
        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            carbonID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        guard status == noErr, let hotKeyRef else {
            return .failure(status)
        }
        return .registered(CarbonHotKeyRegistration(ref: hotKeyRef))
    }
}
