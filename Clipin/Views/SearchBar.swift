import SwiftUI
import AppKit

// MARK: - Key-intercepting NSTextField

/// NSTextField 子类：拦截 ↑↓/Return/Escape/Tab，传给回调而非默认文本行为。
/// IME 组词时这些键必须继续交给输入法，所以真正的拦截要看当前是否存在 marked text。
private final class InterceptingTextField: NSTextField {
    var onNavigate: ((Int) -> Void)?
    var onSubmit: (() -> Void)?
    var onEscape: (() -> Void)?
    var onTab: ((Bool) -> Void)?
}

/// SwiftUI 包装层
private struct InterceptingTextFieldView: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onNavigate: (Int) -> Void
    var onSubmit: () -> Void
    var onEscape: () -> Void
    var onTab: (Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> InterceptingTextField {
        let field = InterceptingTextField()
        field.isBordered = false
        field.backgroundColor = .clear
        field.font = .systemFont(ofSize: 14)
        field.placeholderString = placeholder
        field.focusRingType = .none
        field.delegate = context.coordinator
        context.coordinator.field = field
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
        }
        return field
    }

    func updateNSView(_ nsView: InterceptingTextField, context: Context) {
        context.coordinator.syncBindingText(text, into: nsView)
        nsView.onNavigate = onNavigate
        nsView.onSubmit = onSubmit
        nsView.onEscape = onEscape
        nsView.onTab = onTab
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: InterceptingTextFieldView
        weak var field: InterceptingTextField?
        /// 当前正在观察的 field editor，用于 deinit 时精准移除
        private weak var observedEditor: NSTextView?

        init(_ p: InterceptingTextFieldView) {
            parent = p
            super.init()
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(restoreSearchFocus),
                name: .clipinRestoreSearchFocus,
                object: nil
            )
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        @MainActor
        @objc private func restoreSearchFocus() {
            guard let field else { return }
            field.window?.makeFirstResponder(field)
        }

        /// AppKit 在 IME 组词阶段会把实时文本保存在 field editor 的 marked text 中，
        /// `NSTextField.stringValue` 只有在 commit 后才稳定，所以搜索必须优先读取 editor.string。
        @MainActor
        func currentText(for field: NSTextField) -> String {
            if let editor = field.currentEditor() as? NSTextView {
                return editor.string
            }
            return field.stringValue
        }

        /// IME 组词时 field editor 才是唯一真相源，不能再让 SwiftUI binding 反写覆盖 marked text。
        /// 只有在非组词状态下，外部状态（清空搜索、恢复历史 query）才允许同步回控件。
        @MainActor
        func syncBindingText(_ text: String, into field: NSTextField) {
            if let editor = field.currentEditor() as? NSTextView {
                guard !editor.hasMarkedText() else { return }
                if editor.string != text {
                    editor.string = text
                }
                if field.stringValue != text {
                    field.stringValue = text
                }
                return
            }
            if field.stringValue != text {
                field.stringValue = text
            }
        }

        // MARK: - IME preedit 感知

        /// 编辑开始时把 field editor 的文本变更通知也接入，
        /// 使 IME 组词阶段（setMarkedText）触发实时搜索，不等用户选字。
        func controlTextDidBeginEditing(_ obj: Notification) {
            guard let f = obj.object as? NSTextField,
                  let editor = f.currentEditor() as? NSTextView else { return }
            observedEditor = editor
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(fieldEditorTextDidChange(_:)),
                name: NSText.didChangeNotification,
                object: editor
            )
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            if let editor = observedEditor {
                NotificationCenter.default.removeObserver(
                    self, name: NSText.didChangeNotification, object: editor
                )
                observedEditor = nil
            }
        }

        /// field editor 文本变更（含 IME preedit）→ 同步到 binding
        @MainActor
        @objc private func fieldEditorTextDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            let newText = editor.string
            if newText != parent.text {
                parent.text = newText
            }
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let f = obj.object as? NSTextField else { return }
            parent.text = currentText(for: f)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard let field = control as? InterceptingTextField else { return false }
            if textView.hasMarkedText() {
                switch selector {
                case #selector(NSResponder.moveDown(_:)),
                     #selector(NSResponder.moveUp(_:)),
                     #selector(NSResponder.insertNewline(_:)),
                     #selector(NSResponder.cancelOperation(_:)),
                     #selector(NSResponder.insertTab(_:)),
                     #selector(NSResponder.insertBacktab(_:)):
                    return false
                default:
                    break
                }
            }
            switch selector {
            case #selector(NSResponder.moveDown(_:)):
                field.onNavigate?(1); return true
            case #selector(NSResponder.moveUp(_:)):
                field.onNavigate?(-1); return true
            case #selector(NSResponder.insertNewline(_:)):
                field.onSubmit?(); return true
            case #selector(NSResponder.cancelOperation(_:)):
                field.onEscape?(); return true
            case #selector(NSResponder.insertTab(_:)):
                field.onTab?(false); return true
            case #selector(NSResponder.insertBacktab(_:)):
                field.onTab?(true); return true
            default:
                return false
            }
        }
    }
}

// MARK: - SearchBar

/// 搜索框 + 内嵌类型过滤 pill tabs（含固定视图 pill）
struct SearchBar: View {
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.colorScheme) private var colorScheme
    @Binding var query: String
    @Binding var browseMode: LauncherBrowseMode
    let sceneState: ClipinSceneState
    var onNavigate: (Int) -> Void = { _ in }
    var onSubmit: () -> Void = {}
    var onEscape: () -> Void = {}
    var onCycleBrowseMode: (Bool) -> Void = { _ in }

    private var glass: ClipinGlassPalette {
        .make(theme: settings.visualTheme, colorScheme: colorScheme)
    }

    private var hierarchy: ClipinPanelHierarchy {
        .make(glass: glass, colorScheme: colorScheme)
    }

    private var idlePillStroke: Color {
        glass.hoverStroke.opacity(colorScheme == .dark ? 0.95 : 0.75)
    }

    private var filterRailFill: Color {
        glass.controlFill.opacity(colorScheme == .dark ? 0.68 : 0.52)
    }

    private var filterRailStroke: Color {
        glass.controlStroke.opacity(colorScheme == .dark ? 0.68 : 0.46)
    }

    var body: some View {
        HStack(spacing: 7) {
            searchGlyph

            InterceptingTextFieldView(
                text: $query,
                placeholder: NSLocalizedString("Search…  · Tab", comment: ""),
                onNavigate: onNavigate,
                onSubmit: onSubmit,
                onEscape: onEscape,
                onTab: onCycleBrowseMode
            )
            .frame(height: 16)
            .layoutPriority(-1)

            filterRail

            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10.5))
                        .foregroundStyle(hierarchy.support.hintInk)
                        .frame(width: 22, height: 22)
                        .background(
                            Circle()
                                .fill(glass.keycapTint.opacity(colorScheme == .dark ? 0.86 : 0.94))
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            ClipinSurfaceBackground(
                role: .control,
                cornerRadius: ClipinChrome.searchCornerRadius,
                glass: glass
            )
        )
        .overlay {
            RoundedRectangle(cornerRadius: ClipinChrome.searchCornerRadius, style: .continuous)
                .strokeBorder(glass.emphasisStroke.opacity(sceneState.headerAccentOpacity), lineWidth: 0.6)
        }
        .shadow(
            color: glass.emphasisStrongFill.opacity(sceneState.headerGlowOpacity),
            radius: 12,
            y: 2
        )
        .animation(ClipinMotion.focusShift, value: sceneState)
    }

    private var searchGlyph: some View {
        ZStack {
            Circle()
                .fill(glass.keycapTint.opacity(colorScheme == .dark ? 0.92 : 1.0))
            Image(systemName: "magnifyingglass")
                .foregroundStyle(hierarchy.support.subduedInk)
                .font(.system(size: 12, weight: .medium))
        }
        .frame(width: 24, height: 24)
    }

    private var filterRail: some View {
        filterPills
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(filterRailFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(filterRailStroke, lineWidth: 0.5)
                    )
            )
    }

    private var filterPills: some View {
        HStack(spacing: 3) {
            pinnedPill
            pill(label: "Text",   filter: .text,  shortcut: "⌥2")
            pill(label: "Images", filter: .image, shortcut: "⌥3")
            pill(label: "Files",  filter: .file,  shortcut: "⌥4")
            pill(label: "URLs",   filter: .url,   shortcut: "⌥5")
        }
    }

    /// 固定视图专用 pill，与类型 pills 互斥激活
    private var pinnedPill: some View {
        let isActive = browseMode == .pinned
        return Button {
            browseMode = .pinned
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "pin.fill")
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(isActive ? hierarchy.scope.ink : hierarchy.support.subduedInk)
                Text("⌥1")
                    .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(isActive ? hierarchy.scope.shortcutInk : hierarchy.support.hintInk)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isActive ? hierarchy.scope.fill : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(
                                isActive ? hierarchy.scope.stroke : idlePillStroke,
                                lineWidth: 0.5
                            )
                    )
            )
        }
        .buttonStyle(.plain)
        .animation(ClipinMotion.feedback, value: isActive)
    }

    private func pill(label: LocalizedStringKey, filter: ClipType?, shortcut: String) -> some View {
        let mappedMode = LauncherBrowseMode(typeFilter: filter)
        let isActive = browseMode == mappedMode

        return Button {
            browseMode = mappedMode
        } label: {
            HStack(spacing: 2) {
                Text(label)
                    .font(.system(size: 11.5, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? hierarchy.scope.ink : hierarchy.support.subduedInk)
                Text(shortcut)
                    .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(isActive ? hierarchy.scope.shortcutInk : hierarchy.support.hintInk)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isActive ? hierarchy.scope.fill : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(
                                isActive ? hierarchy.scope.stroke : idlePillStroke,
                                lineWidth: 0.5
                            )
                    )
            )
        }
        .buttonStyle(.plain)
        .animation(ClipinMotion.feedback, value: isActive)
    }

}
