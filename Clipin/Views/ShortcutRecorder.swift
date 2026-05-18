import AppKit
import Carbon.HIToolbox
import SwiftUI

struct ShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: HotKeyShortcut

    func makeNSView(context: Context) -> ShortcutRecorderField {
        let field = ShortcutRecorderField()
        field.onShortcutChange = { newShortcut in
            shortcut = newShortcut
        }
        field.update(shortcut: shortcut)
        return field
    }

    func updateNSView(_ nsView: ShortcutRecorderField, context: Context) {
        nsView.onShortcutChange = { newShortcut in
            shortcut = newShortcut
        }
        nsView.update(shortcut: shortcut)
    }
}

final class ShortcutRecorderField: NSTextField {
    var onShortcutChange: ((HotKeyShortcut) -> Void)?
    private var currentDisplayString = ""
    private var idleBorderColor = NSColor.separatorColor.withAlphaComponent(0.5)
    private var activeBorderColor = NSColor.controlAccentColor.withAlphaComponent(0.38)
    private var idleBackgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.72)
    private var activeBackgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.08)
    private var idleTextColor = NSColor.secondaryLabelColor
    private var activeTextColor = NSColor.labelColor
    private var isCapturing = false {
        didSet { updateAppearance() }
    }

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
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
        guard let layer else { return }

        layer.cornerRadius = 8
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        textColor = isCapturing ? activeTextColor : idleTextColor
        layer.borderColor = (isCapturing ? activeBorderColor : idleBorderColor).cgColor
        layer.backgroundColor = (isCapturing ? activeBackgroundColor : idleBackgroundColor).cgColor
    }
}
