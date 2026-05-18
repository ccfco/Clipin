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
    @Binding var query: String
    @Binding var browseMode: LauncherBrowseMode
    let sceneState: ClipinSceneState
    var onNavigate: (Int) -> Void = { _ in }
    var onSubmit: () -> Void = {}
    var onEscape: () -> Void = {}
    var onCycleBrowseMode: (Bool) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 7) {
            searchGlyph

            InterceptingTextFieldView(
                text: $query,
                placeholder: NSLocalizedString("Search clipboard history…", comment: ""),
                onNavigate: onNavigate,
                onSubmit: onSubmit,
                onEscape: onEscape,
                onTab: onCycleBrowseMode
            )
            .frame(height: 16)
            .layoutPriority(-1)

            filterChip

            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10.5))
                        .foregroundStyle(ClipinInk.tertiary)
                        .frame(width: 22, height: 22)
                        .background(
                            Circle()
                                .fill(Color(nsColor: .controlColor))
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .clipinChromeGlass(cornerRadius: ClipinChrome.searchCornerRadius)
        .animation(ClipinMotion.focusShift, value: sceneState)
    }

    private var searchGlyph: some View {
        ZStack {
            Circle()
                .fill(Color(nsColor: .controlColor))
            Image(systemName: "magnifyingglass")
                .foregroundStyle(ClipinInk.secondary)
                .font(.system(size: 12, weight: .medium))
        }
        .frame(width: 24, height: 24)
    }

    /// 单一 filter chip：当前 mode == all 时极简（只显示一个筛选图标 + Tab 提示），
    /// 选中具体类型时显示 icon + label。点击弹出 macOS 原生 Menu 提供完整鼠标路径。
    /// 键盘 Tab/Shift-Tab 循环和 ⌥0-5 直达由 AppDelegate.keyMonitor 处理，不在此控件里。
    private var filterChip: some View {
        let displayedMode = LauncherSearchScope.displayedMode(query: query, browseMode: browseMode)
        let isAll = displayedMode == .all

        return Menu {
            menuItem(.all, key: "0")
            menuItem(.pinned, key: "1")
            Divider()
            menuItem(.text, key: "2")
            menuItem(.image, key: "3")
            menuItem(.file, key: "4")
            menuItem(.url, key: "5")
        } label: {
            HStack(spacing: 5) {
                Image(systemName: iconName(for: displayedMode))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isAll ? ClipinInk.secondary : Color.accentColor)

                if !isAll {
                    Text(chipLabel(for: displayedMode))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }

                Text("⇥")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(isAll ? ClipinInk.tertiary : ClipinSelectionInk.dim)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isAll ? Color.clear : Color.accentColor.opacity(0.14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(
                                isAll ? ClipinHoverInk.stroke : Color.accentColor.opacity(0.40),
                                lineWidth: 0.5
                            )
                    )
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(NSLocalizedString("Filter by type — press Tab to cycle", comment: ""))
        .animation(ClipinMotion.feedback, value: displayedMode)
    }

    /// 给 menu item 绑定真实 keyboard shortcut（NSMenuItem.keyEquivalent），
    /// 否则 Menu 打开期间 ⌥0-5 既不会被 AppDelegate 全局监视器接收（NSMenu 切走 run loop mode），
    /// 也不会被 SwiftUI 自动响应——文本里画了 "⌥0" 也按不动。
    @ViewBuilder
    private func menuItem(_ mode: LauncherBrowseMode, key: String) -> some View {
        Button {
            browseMode = mode
        } label: {
            Label(mode.displayName, systemImage: iconName(for: mode))
        }
        .keyboardShortcut(KeyEquivalent(Character(key)), modifiers: .option)
    }

    private func iconName(for mode: LauncherBrowseMode) -> String {
        switch mode {
        case .all:    return "line.3.horizontal.decrease"
        case .pinned: return "pin.fill"
        case .text:   return "doc.text"
        case .image:  return "photo"
        case .file:   return "folder"
        case .url:    return "link"
        }
    }

    private func chipLabel(for mode: LauncherBrowseMode) -> String {
        switch mode {
        case .all:    return NSLocalizedString("All", comment: "")
        case .pinned: return NSLocalizedString("Pinned", comment: "")
        case .text:   return NSLocalizedString("Text", comment: "")
        case .image:  return NSLocalizedString("Images", comment: "")
        case .file:   return NSLocalizedString("Files", comment: "")
        case .url:    return NSLocalizedString("URLs", comment: "")
        }
    }
}
