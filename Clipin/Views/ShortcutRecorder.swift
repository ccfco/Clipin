import AppKit
import Carbon.HIToolbox
import SwiftUI

struct ShortcutRecorder: View {
    @Binding var shortcut: HotKeyShortcut
    @State private var isCapturing = false

    var body: some View {
        ShortcutRecorderRepresentable(shortcut: $shortcut, isCapturing: $isCapturing)
            .frame(minHeight: 26)
            .clipinChromeGlass(cornerRadius: ClipinChrome.searchCornerRadius)
            // 录制激活态原先靠 AppKit accent 边框表达，迁移后改由 SwiftUI 侧
            // accent 描边覆盖，不再回到 CALayer chrome。
            .overlay(
                RoundedRectangle(cornerRadius: ClipinChrome.searchCornerRadius, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(isCapturing ? 0.55 : 0), lineWidth: 1)
            )
            .animation(ClipinMotion.feedback, value: isCapturing)
    }
}

private struct ShortcutRecorderRepresentable: NSViewRepresentable {
    @Binding var shortcut: HotKeyShortcut
    @Binding var isCapturing: Bool

    func makeNSView(context: Context) -> ShortcutRecorderField {
        let field = ShortcutRecorderField()
        field.onShortcutChange = { newShortcut in
            shortcut = newShortcut
        }
        field.onCapturingChange = { capturing in
            isCapturing = capturing
        }
        field.update(shortcut: shortcut)
        return field
    }

    func updateNSView(_ nsView: ShortcutRecorderField, context: Context) {
        nsView.onShortcutChange = { newShortcut in
            shortcut = newShortcut
        }
        nsView.onCapturingChange = { capturing in
            isCapturing = capturing
        }
        nsView.update(shortcut: shortcut)
    }
}

final class ShortcutRecorderField: NSTextField {
    var onShortcutChange: ((HotKeyShortcut) -> Void)?
    var onCapturingChange: ((Bool) -> Void)?
    private var currentDisplayString = ""
    private var idleTextColor = NSColor.secondaryLabelColor
    private var activeTextColor = NSColor.labelColor
    private var isCapturing = false {
        didSet {
            updateAppearance()
            onCapturingChange?(isCapturing)
        }
    }

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        isEditable = false
        isSelectable = false
        // 字段本身完全透明无边框：玻璃与录制激活态描边交由 SwiftUI 侧负责，
        // 不再在 CALayer 自绘 chrome（否则会与外层玻璃叠边、属半迁移态）。
        isBordered = false
        drawsBackground = false
        backgroundColor = .clear
        focusRingType = .none
        alignment = .center
        font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        lineBreakMode = .byTruncatingTail
        wantsLayer = true
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became {
            isCapturing = true
            stringValue = NSLocalizedString("Press shortcut", comment: "")
        }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            isCapturing = false
            stringValue = currentDisplayString
        }
        return resigned
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isCapturing else { return false }
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            window?.makeFirstResponder(nil)
            return
        }

        guard let shortcut = HotKeyShortcut.capture(from: event) else {
            NSSound.beep()
            return
        }

        onShortcutChange?(shortcut)
        window?.makeFirstResponder(nil)
    }

    func update(shortcut: HotKeyShortcut) {
        currentDisplayString = shortcut.displayString
        if !isCapturing {
            stringValue = currentDisplayString
        }
    }

    private func updateAppearance() {
        // 仅保留文字可读性的前景色变化；边框/背景等 chrome 已下放到 SwiftUI 玻璃层。
        textColor = isCapturing ? activeTextColor : idleTextColor
    }
}
