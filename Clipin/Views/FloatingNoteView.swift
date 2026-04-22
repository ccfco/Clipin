import AppKit
import SwiftUI
import Combine
import WebKit

// MARK: - MarkdownTextView

/// NSTextView 的 SwiftUI 包装，用于浮动笔记编辑区。
/// 使用标准 NSScrollView + NSTextView 组合，避免裸 NSTextView 的尺寸协商问题。
struct MarkdownTextView: NSViewRepresentable {
    @Binding var text: String
    var onSave: (String) -> Void
    var onNaturalHeightChanged: ((CGFloat) -> Void)?
    var onScrollStateChanged: ((Bool) -> Void)?
    var onRegisterFocusHandler: ((@escaping () -> Void) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onSave: onSave,
            onNaturalHeightChanged: onNaturalHeightChanged,
            onScrollStateChanged: onScrollStateChanged
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }

        textView.delegate = context.coordinator
        context.coordinator.textView = textView
        // 初始加载完毕后上报一次高度，让窗口在显示前先调整好尺寸
        DispatchQueue.main.async {
            context.coordinator.reportNaturalHeight(for: textView)
        }

        // 注册"让编辑器重新获焦"的回调，供文件选择器关闭后调用
        onRegisterFocusHandler?({ [weak textView] in
            textView?.window?.makeFirstResponder(textView)
        })

        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false

        textView.insertionPointColor = NSColor(red: 0.80, green: 0.15, blue: 0.38, alpha: 1)
        textView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.textContainerInset = NSSize(width: 16, height: 16)
        textView.textContainer?.lineFragmentPadding = 0
        textView.backgroundColor = .clear

        scrollView.backgroundColor = .clear
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        context.coordinator.startObservingScroll(in: scrollView)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.onScrollStateChanged = onScrollStateChanged
        // 只在内容真正不同时才赋值，避免光标跳位
        if textView.string != text {
            textView.string = text
            // 内容变化后同步上报自然高度，让窗口在显示时即 fit 到正确尺寸
            context.coordinator.reportNaturalHeight(for: textView)
        }
        context.coordinator.reportScrollState(for: scrollView)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var textView: NSTextView?
        weak var observedClipView: NSClipView?
        private let onSave: (String) -> Void
        private let onNaturalHeightChanged: ((CGFloat) -> Void)?
        var onScrollStateChanged: ((Bool) -> Void)?
        private var saveTask: Task<Void, Never>?

        init(onSave: @escaping (String) -> Void,
             onNaturalHeightChanged: ((CGFloat) -> Void)?,
             onScrollStateChanged: ((Bool) -> Void)?) {
            self.onSave = onSave
            self.onNaturalHeightChanged = onNaturalHeightChanged
            self.onScrollStateChanged = onScrollStateChanged
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            let newText = tv.string

            // debounce 500ms 后自动保存
            saveTask?.cancel()
            saveTask = Task {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.onSave(newText)
                }
            }

            // 上报内容自然高度，供窗口自动调整
            reportNaturalHeight(for: tv)
        }

        @MainActor
        func reportNaturalHeight(for tv: NSTextView) {
            guard let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            lm.ensureLayout(for: tc)
            let used = lm.usedRect(for: tc)
            let height = used.height + tv.textContainerInset.height * 2
            onNaturalHeightChanged?(height)
        }

        func startObservingScroll(in scrollView: NSScrollView) {
            if let observedClipView {
                NotificationCenter.default.removeObserver(
                    self,
                    name: NSView.boundsDidChangeNotification,
                    object: observedClipView
                )
            }
            observedClipView = scrollView.contentView
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleClipViewBoundsDidChange(_:)),
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView
            )
            reportScrollState(for: scrollView)
        }

        func reportScrollState(for scrollView: NSScrollView) {
            let isAtTop = scrollView.contentView.bounds.minY <= 1
            onScrollStateChanged?(isAtTop)
        }

        @objc
        private func handleClipViewBoundsDidChange(_ notification: Notification) {
            guard let clipView = notification.object as? NSClipView,
                  let scrollView = clipView.superview as? NSScrollView else { return }
            reportScrollState(for: scrollView)
        }
    }
}

// MARK: - MarkdownPreviewView

/// WKWebView 包装：渲染 Markdown 预览，背景透明以透出面板毛玻璃。
struct MarkdownPreviewView: NSViewRepresentable {
    let markdown: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        // 透明背景，让 .regularMaterial 透出
        webView.setValue(false, forKey: "drawsBackground")
        webView.layer?.backgroundColor = .clear
        webView.navigationDelegate = context.coordinator
        let bodyHTML = MarkdownRenderer.shared.renderBodyHTML(from: markdown)
        context.coordinator.lastBodyHTML = bodyHTML
        webView.loadHTMLString(MarkdownRenderer.shared.previewShellHTML(body: bodyHTML), baseURL: nil)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let bodyHTML = MarkdownRenderer.shared.renderBodyHTML(from: markdown)
        guard bodyHTML != context.coordinator.lastBodyHTML else { return }
        context.coordinator.lastBodyHTML = bodyHTML
        if context.coordinator.isShellReady {
            context.coordinator.apply(bodyHTML: bodyHTML, to: webView)
        } else {
            context.coordinator.pendingBodyHTML = bodyHTML
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastBodyHTML = ""
        var pendingBodyHTML: String?
        var isShellReady = false

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isShellReady = true
            if let pendingBodyHTML, pendingBodyHTML != lastBodyHTML {
                apply(bodyHTML: pendingBodyHTML, to: webView)
            } else if let pendingBodyHTML {
                apply(bodyHTML: pendingBodyHTML, to: webView)
            }
            pendingBodyHTML = nil
        }

        func apply(bodyHTML: String, to webView: WKWebView) {
            let payload = bodyHTML
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
                .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
                .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
            webView.evaluateJavaScript("window.__updateBody(\"\(payload)\")", completionHandler: nil)
        }
    }
}

// MARK: - FilePickerSearchField

/// NSTextField 子类：唯一职责是在进入窗口层级时主动抢焦点。
/// 不 override keyDown——NSTextField 激活后真正的 first responder 是内嵌的
/// field editor（共享 NSTextView），keyDown 压根不会到达 NSTextField 本身。
fileprivate final class NavigableTextField: NSTextField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        DispatchQueue.main.async { window.makeFirstResponder(self) }
    }
}

/// 文件搜索框：自动获焦，↑↓/Enter/Esc 通过 doCommandBy delegate 回调上报。
/// 特殊键必须走 control(_:textView:doCommandBy:)，这才是 field editor 真正的出口。
fileprivate struct FilePickerSearchField: NSViewRepresentable {
    @Binding var text: String
    var onMoveUp: () -> Void
    var onMoveDown: () -> Void
    var onConfirm: () -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NavigableTextField {
        let field = NavigableTextField()
        field.placeholderString = "文件名…"
        field.bezelStyle = .roundedBezel
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 14)
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NavigableTextField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
        // 每次 SwiftUI 更新时同步最新闭包，确保 coordinator 持有的回调不过期
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: FilePickerSearchField   // var：updateNSView 会替换为最新值

        init(parent: FilePickerSearchField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        /// field editor 遇到特殊键时调用此方法（而非 NSTextField.keyDown）。
        /// 返回 true 表示已处理，false 让系统继续默认行为。
        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                parent.onMoveUp(); return true
            case #selector(NSResponder.moveDown(_:)):
                parent.onMoveDown(); return true
            case #selector(NSResponder.insertNewline(_:)):
                parent.onConfirm(); return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel(); return true
            default:
                return false
            }
        }
    }
}

// MARK: - FilePickerRow

private struct FilePickerRow: View {
    let displayPath: String
    let isSelected: Bool
    let isCurrent: Bool
    let metadata: FloatingNoteViewModel.NoteMetadata?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .font(.system(size: 12))
                .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(displayPath)
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if isCurrent {
                        Text("当前")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Color.accentColor, in: Capsule())
                    }
                    Spacer()
                }
                if let meta = metadata {
                    HStack(spacing: 8) {
                        if let date = meta.modifiedDate {
                            Text(relativeTimeString(from: date))
                        }
                        if !meta.fileSizeString.isEmpty {
                            Text(meta.fileSizeString)
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, metadata != nil ? 9 : 7)
        .background(
            isSelected ? Color.accentColor.opacity(0.15) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
    }

    private func relativeTimeString(from date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        switch interval {
        case ..<60:          return "刚刚"
        case ..<3600:        return "\(Int(interval / 60)) 分钟前"
        case ..<86400:       return "\(Int(interval / 3600)) 小时前"
        case ..<604800:      return "\(Int(interval / 86400)) 天前"
        default:             return "\(Int(interval / 604800)) 周前"
        }
    }
}

// MARK: - FloatingNoteFilePicker

/// ⌘P 文件选择器：显示在编辑区上方的模态覆盖层。
struct FloatingNoteFilePicker: View {
    @ObservedObject var viewModel: FloatingNoteViewModel

    var body: some View {
        ZStack(alignment: .top) {
            // 点击背景区域关闭
            Color.black.opacity(0.12)
                .ignoresSafeArea()
                .onTapGesture { viewModel.hideFilePicker() }

            VStack(spacing: 0) {
                // 搜索框
                FilePickerSearchField(
                    text: $viewModel.filePickerQuery,
                    onMoveUp:   { viewModel.movePickerSelection(by: -1) },
                    onMoveDown: { viewModel.movePickerSelection(by: 1) },
                    onConfirm:  { viewModel.confirmPickerSelection() },
                    onCancel:   { viewModel.hideFilePicker() }
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

                // 笔记列表 section header：标题 + 数量
                let files = viewModel.filteredPickerFiles
                let totalCount = viewModel.filePickerFiles.count
                HStack {
                    Text(viewModel.filePickerQuery.isEmpty ? "最近笔记" : "搜索结果")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if viewModel.filePickerQuery.isEmpty {
                        Text("\(totalCount) 个")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    } else {
                        Text("\(files.count) / \(totalCount)")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 6)

                Divider().opacity(0.3)

                // 文件列表
                if files.isEmpty {
                    Text(viewModel.filePickerQuery.isEmpty ? "Root Folder 内没有 Markdown 文件" : "无匹配文件")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(20)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                ForEach(Array(files.enumerated()), id: \.element) { idx, url in
                                    FilePickerRow(
                                        displayPath: viewModel.displayPath(for: url),
                                        isSelected: idx == viewModel.filePickerSelectedIndex,
                                        isCurrent: url == viewModel.fileURL,
                                        metadata: viewModel.fileMetadata[url]
                                    )
                                    .id(idx)
                                    .onTapGesture {
                                        viewModel.openFile(url)
                                        viewModel.hideFilePicker()
                                    }
                                }
                            }
                            .padding(.vertical, 6)
                        }
                        .frame(maxHeight: 280)
                        .onChange(of: viewModel.filePickerSelectedIndex) { _, idx in
                            withAnimation { proxy.scrollTo(idx, anchor: .center) }
                        }
                    }
                }
            }
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 20, y: 8)
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .onChange(of: viewModel.filePickerQuery) { _, _ in
            viewModel.filePickerSelectedIndex = 0
        }
    }
}

// MARK: - TrafficLightCloseButton

/// 仿 Raycast Note 的红色关闭按钮：hover 时亮红 + ✕，非 hover 时灰色圆点。
private struct TrafficLightCloseButton: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(isHovered
                          ? Color(red: 1.0, green: 0.37, blue: 0.34)
                          : Color.primary.opacity(0.18))
                    .frame(width: 12, height: 12)
                if isHovered {
                    Image(systemName: "xmark")
                        .font(.system(size: 6.5, weight: .bold))
                        .foregroundStyle(Color.black.opacity(0.55))
                }
            }
        }
        .buttonStyle(.plain)
        .help("关闭 (⌘W)")
        .onHover { isHovered = $0 }
    }
}

// MARK: - ToolbarIconButton

/// 工具栏图标按钮：hover 时图标微亮，系统 tooltip 显示说明。
private struct ToolbarIconButton: View {
    let systemName: String
    let shortcut: String          // 仅用于 .help() tooltip，不在界面展示
    var isActive: Bool = false
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12))
                .foregroundStyle(isActive ? Color.accentColor : .secondary)
                .opacity(isHovered ? 1 : 0.75)
        }
        .buttonStyle(.plain)
        .help(shortcut.isEmpty ? "" : shortcut)
        .onHover { isHovered = $0 }
    }
}

// MARK: - FloatingNoteView

/// 浮动笔记主界面：工具栏 + Markdown 编辑区 + 实时渲染区 + ⌘P 文件选择器覆盖层。
/// 所见即所得的第一阶段仍以 Markdown 为唯一存储格式，只把实时渲染常驻到编辑过程里。
struct FloatingNoteView: View {
    @ObservedObject var viewModel: FloatingNoteViewModel
    @State private var isToolbarHovered = false
    @State private var isContentAtTop = true

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                toolbar
                contentArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .bottom) { bottomBar }
            }
            .background(noteSurface)

            if viewModel.isFilePickerVisible {
                FloatingNoteFilePicker(viewModel: viewModel)
            }
        }
        .onAppear { viewModel.loadFile() }
    }

    private var contentArea: some View {
        GeometryReader { proxy in
            if viewModel.isWysiwygMode {
                wysiwygWorkspace(for: proxy.size)
            } else {
                editorPane(adjustHeightForWysiwyg: false)
            }
        }
    }

    private func wysiwygWorkspace(for size: CGSize) -> some View {
        Group {
            if size.width >= 680 {
                HStack(spacing: 0) {
                    editorPane(adjustHeightForWysiwyg: true)
                    verticalWorkspaceDivider
                    previewPane
                }
            } else {
                VStack(spacing: 0) {
                    editorPane(adjustHeightForWysiwyg: true)
                    horizontalWorkspaceDivider
                    previewPane
                        .frame(minHeight: 180)
                }
            }
        }
    }

    private func editorPane(adjustHeightForWysiwyg: Bool) -> some View {
        MarkdownTextView(
            text: $viewModel.content,
            onSave: viewModel.save,
            onNaturalHeightChanged: { height in
                let adjustedHeight = adjustHeightForWysiwyg ? max(height, 320) : height
                viewModel.onNaturalHeightChanged?(adjustedHeight)
            },
            onScrollStateChanged: { isAtTop in
                isContentAtTop = isAtTop
            },
            onRegisterFocusHandler: { handler in
                viewModel.focusEditorHandler = handler
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var previewPane: some View {
        VStack(spacing: 0) {
            HStack {
                Label("实时效果", systemImage: "sparkles.rectangle.stack")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            MarkdownPreviewView(markdown: viewModel.content)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(
            LinearGradient(
                colors: [Color.white.opacity(0.20), Color.white.opacity(0.08)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var verticalWorkspaceDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(width: 0.5)
    }

    private var horizontalWorkspaceDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 0.5)
    }

    // MARK: Toolbar（Raycast 三段式：左侧 traffic light / 中间 title / 右侧按钮）

    private var toolbar: some View {
        VStack(spacing: 0) {
            ZStack {
                // ── 中间：文件名居中 ──────────────────────────────────
                Text(viewModel.displayFileName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .opacity(isToolbarHovered ? 0.92 : 0.38)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .animation(.easeInOut(duration: 0.18), value: isToolbarHovered)

                // ── 两侧 HStack，撑满宽度 ────────────────────────────
                HStack(spacing: 0) {
                    // 左侧：traffic light 关闭按钮（hover 区域内始终响应）
                    TrafficLightCloseButton {
                        viewModel.close()
                    }
                    .padding(.leading, 12)

                    Spacer()

                    // 右侧：保存状态 + 功能按钮（hover 时淡入）
                    Group {
                        if viewModel.isSaving {
                            Text("Saving…")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        } else if viewModel.lastSaveError != nil {
                            Text("Save failed")
                                .font(.system(size: 11))
                                .foregroundStyle(.red.opacity(0.8))
                        }

                        ToolbarIconButton(systemName: "folder", shortcut: "") {
                            viewModel.revealInFinder()
                        }
                        .opacity(viewModel.fileURL == nil ? 0 : 1)

                        ToolbarIconButton(
                            systemName: "doc.text.magnifyingglass",
                            shortcut: "⌘P",
                            isActive: viewModel.isFilePickerVisible
                        ) {
                            viewModel.toggleFilePicker()
                        }
                        .opacity(viewModel.hasRootFolder ? 1 : 0)

                        ToolbarIconButton(
                            systemName: viewModel.isWysiwygMode ? "rectangle.split.2x1.fill" : "rectangle.split.2x1",
                            shortcut: "所见即所得 (⌘⇧P)",
                            isActive: viewModel.isWysiwygMode
                        ) {
                            viewModel.togglePreview()
                        }
                    }
                    .opacity(isToolbarHovered ? 1 : 0)
                    .animation(.easeInOut(duration: 0.18), value: isToolbarHovered)
                    .padding(.trailing, 12)
                }
            }
            .padding(.vertical, 9)

            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 0.5)
                .opacity(isContentAtTop ? 0 : 1)
                .animation(.easeInOut(duration: 0.16), value: isContentAtTop)
        }
        .contentShape(Rectangle())   // 让整个矩形区域响应 hover
        .onHover { isToolbarHovered = $0 }
    }

    // MARK: 底部状态栏（Raycast 风格：字数居中，右侧对称图标）

    private var bottomBar: some View {
        ZStack {
            // 字数居中
            Text(viewModel.content.isEmpty ? "0 字符" : "\(viewModel.content.count) 字符")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

            HStack {
                Text(viewModel.isWysiwygMode ? "所见即所得" : "Markdown")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary.opacity(0.78))
                Spacer()
            }
            .padding(.leading, 14)

            // 右侧：保存状态 or 格式图标（视觉平衡）
            HStack {
                Spacer()
                Group {
                    if viewModel.isSaving {
                        Text("保存中…")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    } else if viewModel.lastSaveError != nil {
                        Image(systemName: "exclamationmark.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(.red.opacity(0.7))
                    } else {
                        Image(systemName: viewModel.isWysiwygMode ? "eye.text" : "textformat")
                            .font(.system(size: 11))
                            .foregroundStyle(.quaternary)
                    }
                }
                .padding(.trailing, 14)
            }
        }
        .frame(height: 28)
        .background(
            // 渐变遮罩：让底部文字在内容背景上可读
            LinearGradient(
                colors: [Color.clear, Color.primary.opacity(0.03)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var noteSurface: some View {
        ZStack {
            // regularMaterial：和 preview pane 同款毛玻璃质感，不再是纯实色
            Rectangle().fill(Material.regularMaterial)
            // 轻薄白色蒙层：保持笔记区亮度，防止 material 采样背景色过深
            Color.white.opacity(0.22)
            // 底部 accent 渐变：和 Launcher shell 同一视觉语言
            LinearGradient(
                colors: [Color.clear, Color.accentColor.opacity(0.04)],
                startPoint: UnitPoint(x: 0.5, y: 0.5),
                endPoint: .bottom
            )
        }
    }
}

// MARK: - FloatingNoteViewModel

@MainActor
final class FloatingNoteViewModel: ObservableObject {

    // MARK: - 笔记元数据（文件选择器用）

    struct NoteMetadata {
        let modifiedDate: Date?
        let fileSize: Int   // bytes

        var fileSizeString: String {
            guard fileSize > 0 else { return "" }
            return fileSize < 1024
                ? "\(fileSize) B"
                : String(format: "%.1f KB", Double(fileSize) / 1024.0)
        }
    }

    @Published var content: String = ""
    @Published var isSaving: Bool = false
    @Published var lastSaveError: Error?
    @Published private(set) var fileURL: URL?

    // 所见即所得模式：编辑与渲染同屏，不改变底层 Markdown 文件格式。
    @Published var isWysiwygMode = false

    // 文件选择器状态
    @Published var isFilePickerVisible = false
    @Published var filePickerQuery = ""
    @Published var filePickerSelectedIndex = 0
    @Published var filePickerFiles: [URL] = []
    @Published var fileMetadata: [URL: NoteMetadata] = [:]

    var onClose: (() -> Void)?
    var onNaturalHeightChanged: ((CGFloat) -> Void)?
    /// 文件选择器关闭后，用于恢复 NSTextView 焦点
    var focusEditorHandler: (() -> Void)?

    private let service = FloatingNoteService.shared
    private let settings = SettingsStore.shared

    // MARK: - 基础属性

    var displayFileName: String {
        fileURL?.lastPathComponent ?? "No file configured"
    }

    var hasRootFolder: Bool {
        !(settings.floatingNoteRootFolder ?? "").isEmpty
    }

    var rootFolderURL: URL? {
        guard let root = settings.floatingNoteRootFolder, !root.isEmpty else { return nil }
        return URL(fileURLWithPath: root, isDirectory: true)
    }

    /// 相对于 Root Folder 的显示路径（用于文件选择器列表）
    func displayPath(for url: URL) -> String {
        guard let root = settings.floatingNoteRootFolder, !root.isEmpty else {
            return url.lastPathComponent
        }
        let rootPath = root.hasSuffix("/") ? root : root + "/"
        guard url.path.hasPrefix(rootPath) else { return url.lastPathComponent }
        return String(url.path.dropFirst(rootPath.count))
    }

    // MARK: - 文件加载 / 保存

    func loadFile() {
        guard let root = settings.floatingNoteRootFolder, !root.isEmpty else {
            content = ""
            fileURL = nil
            return
        }
        let url = service.resolveURL(rootFolder: root, pattern: settings.floatingNotePattern)
        fileURL = url
        do {
            try service.ensureFileExists(at: url, template: settings.floatingNoteTemplate)
            content = try service.load(from: url)
        } catch {
            content = ""
            lastSaveError = error
        }
    }

    func save(_ text: String) {
        guard let url = fileURL else { return }
        isSaving = true
        lastSaveError = nil
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            do {
                try self.service.save(content: text, to: url)
                await MainActor.run { self.isSaving = false }
            } catch {
                await MainActor.run {
                    self.isSaving = false
                    self.lastSaveError = error
                }
            }
        }
    }

    func revealInFinder() {
        guard let url = fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func close() {
        onClose?()
    }

    // MARK: - 文件选择器

    var filteredPickerFiles: [URL] {
        guard !filePickerQuery.isEmpty else { return filePickerFiles }
        return filePickerFiles.filter {
            displayPath(for: $0).localizedCaseInsensitiveContains(filePickerQuery)
        }
    }

    func showFilePicker() {
        guard hasRootFolder, let root = settings.floatingNoteRootFolder else { return }
        var files = service.listMarkdownFiles(in: root)
        // 先加载 metadata，再按最近修改时间排序（最新的在前）
        loadFileMetadata(for: files)
        files.sort { a, b in
            let dateA = fileMetadata[a]?.modifiedDate ?? .distantPast
            let dateB = fileMetadata[b]?.modifiedDate ?? .distantPast
            return dateA > dateB
        }
        filePickerFiles = files
        filePickerQuery = ""
        // 预选当前打开的文件
        if let current = fileURL,
           let idx = filePickerFiles.firstIndex(of: current) {
            filePickerSelectedIndex = idx
        } else {
            filePickerSelectedIndex = 0
        }
        isFilePickerVisible = true
    }

    private func loadFileMetadata(for files: [URL]) {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        var result: [URL: NoteMetadata] = [:]
        for url in files {
            if let values = try? url.resourceValues(forKeys: keys) {
                result[url] = NoteMetadata(
                    modifiedDate: values.contentModificationDate,
                    fileSize: values.fileSize ?? 0
                )
            }
        }
        fileMetadata = result
    }

    func hideFilePicker() {
        isFilePickerVisible = false
        focusEditorHandler?()
    }

    func toggleFilePicker() {
        if isFilePickerVisible { hideFilePicker() } else { showFilePicker() }
    }

    func togglePreview() {
        // 切换所见即所得时关闭文件选择器，避免两层覆盖
        if isFilePickerVisible { hideFilePicker() }
        isWysiwygMode.toggle()
        // 两种模式都包含编辑器，切换后立即把焦点还给 NSTextView，保持连续输入。
        DispatchQueue.main.async { [weak self] in
            self?.focusEditorHandler?()
        }
    }

    func movePickerSelection(by delta: Int) {
        let count = filteredPickerFiles.count
        guard count > 0 else { return }
        filePickerSelectedIndex = max(0, min(filePickerSelectedIndex + delta, count - 1))
    }

    func confirmPickerSelection() {
        let files = filteredPickerFiles
        guard filePickerSelectedIndex < files.count else { return }
        openFile(files[filePickerSelectedIndex])
        hideFilePicker()
    }

    /// 打开指定文件（不影响 Root Folder 配置，只切换编辑内容）
    func openFile(_ url: URL) {
        do {
            content = try service.load(from: url)
            fileURL = url
        } catch {
            lastSaveError = error
        }
    }
}
