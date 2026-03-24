import Carbon.HIToolbox

/// 全局快捷键服务 — 使用 Carbon RegisterEventHotKey API
/// 不需要辅助功能权限，是 macOS 注册全局快捷键的标准方式
final class HotKeyService: @unchecked Sendable {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    var onToggle: (() -> Void)?

    func start() {
        // 注册 Carbon event handler
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

        // ⌘+Shift+V → V = kVK_ANSI_V (0x09), modifiers = cmdKey + shiftKey
        let hotKeyID = EventHotKeyID(signature: OSType(0x434C5049), id: 1)  // "CLPI"
        let modifiers = UInt32(cmdKey | shiftKey)
        RegisterEventHotKey(UInt32(kVK_ANSI_V), modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
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
