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
            stringValue = "Press shortcut"
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
        layer.borderWidth = 1
        layer.borderColor = isCapturing
            ? NSColor.controlAccentColor.cgColor
            : NSColor.separatorColor.cgColor
        layer.backgroundColor = isCapturing
            ? NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
            : NSColor.quaternaryLabelColor.withAlphaComponent(0.06).cgColor
    }
}
