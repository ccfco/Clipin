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
        field.font = .systemFont(ofSize: ClipinChrome.searchFieldFontSize)
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
            // 与 fieldEditorTextDidChange 去重：IME 组词期间两条通知都会到达，
            // 无条件赋值会让同一个字符触发两次 binding 更新、把 150ms 搜索去抖重置两次。
            let newText = currentText(for: f)
            if newText != parent.text {
                parent.text = newText
            }
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
    /// 类型筛选顺序，来自设置（All 固定第一、收藏是独立视图不在其中）。
    var filterOrder: [LauncherBrowseMode] = LauncherBrowseMode.defaultFilterCycleOrder
    /// pinnedOnlyView 下 All 只含未固定条目，由 ViewModel 改写为 Recent。
    var allModeTitle: String = NSLocalizedString("All", comment: "")
    /// 收藏数量，仅用于菜单项「收藏 (N)」，不进入 chip 文案（避免宽度随数量变化）。
    var favoriteCount: Int = 0
    var onNavigate: (Int) -> Void = { _ in }
    var onSubmit: () -> Void = {}
    var onEscape: () -> Void = {}
    var onCycleBrowseMode: (Bool) -> Void = { _ in }
    /// 菜单/⌥ 直达的统一入口。ViewModel 里处理「Pinned 需要先退出搜索」，
    /// 不在视图层复制一份选中语义。
    var onSelectBrowseMode: (LauncherBrowseMode) -> Void = { _ in }

    var body: some View {
        HStack(spacing: ClipinChrome.gap) {
            searchGlyph

            InterceptingTextFieldView(
                text: $query,
                placeholder: NSLocalizedString("Search clipboard history…", comment: ""),
                onNavigate: onNavigate,
                onSubmit: onSubmit,
                onEscape: onEscape,
                onTab: onCycleBrowseMode
            )
            .frame(height: 26)
            .layoutPriority(-1)

            filterChip

            // 始终保留清除按钮的槽位（空查询时透明禁用），否则输入第一个字符时
            // 按钮从无到有会把 filter chip 向左顶一下、搜索框宽度突变。
            Button { query = "" } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(ClipinInk.tertiary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .opacity(query.isEmpty ? 0 : 1)
            .disabled(query.isEmpty)
            .accessibilityHidden(query.isEmpty)
        }
        .animation(ClipinMotion.focusShift, value: sceneState)
    }

    /// 搜索栏最左 = app 身份图标(Raycast/Spotlight 同位),取代原放大镜符号。
    /// 用 `NSApplication.applicationIconImage` 复用现有 AppIcon 资源,不新增图片;
    /// 搜索可发现性由占位符 "Search clipboard history…" 承担。
    /// 图标尺寸跟随搜索字号(20pt)放大,与大字保持视觉平衡。
    private var searchGlyph: some View {
        Image(nsImage: NSApplication.shared.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: 22, height: 22)
            .frame(width: 24, height: 26)
    }

    /// 单一 filter chip：始终显示当前筛选名（含 All），并弹出 macOS 原生 Menu 提供鼠标路径。
    /// 键盘 Tab/Shift-Tab 循环和 ⌥直达由 AppDelegate.keyMonitor 处理，不在此控件里。
    ///
    /// 宽度稳定：ZStack 里叠放所有候选模式的同构内容（隐藏），由最宽者决定 chip 宽度。
    /// 否则 Tab 切换时文本从「无」变「Images」、或换成更宽的类型名，会把左侧搜索框挤得
    /// 每次抖动一下——launcher 的高频操作里这是明显的廉价感。
    private var filterChip: some View {
        let displayedMode = LauncherSearchScope.displayedMode(query: query, browseMode: browseMode)
        let isAll = displayedMode == .all
        let allModes: [LauncherBrowseMode] = [.all] + filterOrder + [.pinned]

        return Menu {
            menuItem(.all)
            Divider()
            ForEach(filterOrder, id: \.self) { mode in
                menuItem(mode)
            }
            Divider()
            menuItem(.pinned)
        } label: {
            ZStack {
                ForEach(allModes, id: \.self) { mode in
                    chipContent(for: mode, active: mode != .all)
                        .hidden()
                        .accessibilityHidden(true)
                }

                chipContent(for: displayedMode, active: !isAll)
            }
            .padding(.horizontal, ClipinChrome.gap)
            .padding(.vertical, ClipinChrome.gap)
            .background(
                RoundedRectangle(cornerRadius: ClipinChrome.cornerTile, style: .continuous)
                    .fill(isAll ? Color.clear : Color.accentColor.opacity(0.14))
                    .overlay(
                        RoundedRectangle(cornerRadius: ClipinChrome.cornerTile, style: .continuous)
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
        .help(NSLocalizedString("Filter by type — Tab cycles, ⌥0–4 jumps directly, ⌥F for favorites", comment: ""))
        .animation(ClipinMotion.feedback, value: displayedMode)
    }

    private func chipContent(for mode: LauncherBrowseMode, active: Bool) -> some View {
        HStack(spacing: ClipinChrome.gap) {
            Image(systemName: mode.systemImageName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(active ? Color.accentColor : ClipinInk.secondary)

            Text(title(for: mode))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(active ? Color.accentColor : ClipinInk.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            Text("⇥")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(active ? ClipinSelectionInk.dim : ClipinInk.tertiary)
        }
    }

    /// 菜单项用 Toggle 而非 Button：macOS 原生 Menu 会给选中的 Toggle 画勾，
    /// Button 没有选中态，用户看不出当前筛选是哪一档。
    /// 给 menu item 绑定真实 keyboard shortcut（NSMenuItem.keyEquivalent），
    /// 否则 Menu 打开期间 ⌥ 组合既不会被 AppDelegate 全局监视器接收（NSMenu 切走
    /// run loop mode），也不会被 SwiftUI 自动响应。
    @ViewBuilder
    private func menuItem(_ mode: LauncherBrowseMode) -> some View {
        let isSelected = LauncherSearchScope.displayedMode(query: query, browseMode: browseMode) == mode
        Toggle(isOn: Binding(
            get: { isSelected },
            set: { isOn in
                // 点击已选中的项会传 false；筛选是单选，不能取消，保持原样即可。
                guard isOn else { return }
                onSelectBrowseMode(mode)
            }
        )) {
            Label(menuTitle(for: mode), systemImage: mode.systemImageName)
        }
        .keyboardShortcut(KeyEquivalent(Character(shortcutKey(for: mode))), modifiers: .option)
    }

    /// ⌥ 直达键按类型语义固定，不随自定义循环顺序变化：用户记住的是「⌥1 文本」，
    /// 不是「第 1 个筛选」。顺序只影响 Tab 循环与菜单排列。
    private func shortcutKey(for mode: LauncherBrowseMode) -> String {
        switch mode {
        case .all:    return "0"
        case .text:   return "1"
        case .image:  return "2"
        case .file:   return "3"
        case .url:    return "4"
        case .pinned: return "f"
        }
    }

    private func title(for mode: LauncherBrowseMode) -> String {
        mode == .all ? allModeTitle : mode.displayName
    }

    /// 收藏数量只出现在菜单里：chip 宽度按最宽文案固定，数字变化不能把搜索框挤动。
    private func menuTitle(for mode: LauncherBrowseMode) -> String {
        guard mode == .pinned, favoriteCount > 0 else { return title(for: mode) }
        return String(
            format: NSLocalizedString("%@ (%d)", comment: ""),
            title(for: mode), favoriteCount
        )
    }
}
