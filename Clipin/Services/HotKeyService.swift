import AppKit
import Carbon.HIToolbox

/// 全局快捷键服务 — ⌘+Shift+V 呼出/隐藏面板
final class HotKeyService: @unchecked Sendable {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    var onToggle: (() -> Void)?

    func start() {
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo -> Unmanaged<CGEvent>? in
                guard type == .keyDown else {
                    return Unmanaged.passRetained(event)
                }

                let flags = event.flags
                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

                // ⌘+Shift+V  (V = keycode 9)
                if keyCode == 9,
                   flags.contains(.maskCommand),
                   flags.contains(.maskShift) {
                    let service = Unmanaged<HotKeyService>.fromOpaque(userInfo!).takeUnretainedValue()
                    DispatchQueue.main.async {
                        service.onToggle?()
                    }
                    return nil  // 吞掉事件
                }

                return Unmanaged.passRetained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("⚠️ Failed to create event tap — check Accessibility permissions")
            return
        }

        self.eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }
}
