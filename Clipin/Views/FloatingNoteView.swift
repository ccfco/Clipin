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

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        // 透明背景，让 .regularMaterial 透出
        webView.setValue(false, forKey: "drawsBackground")
        webView.layer?.backgroundColor = .clear
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        webView.loadHTMLString(MarkdownRenderer.shared.renderHTML(from: markdown), baseURL: nil)
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

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(displayPath)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            isSelected ? Color.accentColor.opacity(0.15) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
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

                Divider().opacity(0.3)

                // 文件列表
                let files = viewModel.filteredPickerFiles
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
                                        isSelected: idx == viewModel.filePickerSelectedIndex
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
                        .frame(maxHeight: 260)
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

/// 浮动笔记主界面：工具栏 + Markdown 编辑区 + ⌘P 文件选择器覆盖层。
/// 工具栏默认收起（文件名变淡、按钮隐藏），hover 后展开显示完整控件。
struct FloatingNoteView: View {
    @ObservedObject var viewModel: FloatingNoteViewModel
    @State private var isToolbarHovered = false
    @State private var isContentAtTop = true

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                toolbar
                if viewModel.isPreviewMode {
                    MarkdownPreviewView(markdown: viewModel.content)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    MarkdownTextView(
                        text: $viewModel.content,
                        onSave: viewModel.save,
                        onNaturalHeightChanged: viewModel.onNaturalHeightChanged,
                        onScrollStateChanged: { isAtTop in
                            isContentAtTop = isAtTop
                        },
                        onRegisterFocusHandler: { handler in
                            viewModel.focusEditorHandler = handler
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(noteSurface)
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
            }

            if viewModel.isFilePickerVisible {
                FloatingNoteFilePicker(viewModel: viewModel)
            }
        }
        .onAppear { viewModel.loadFile() }
    }

    // MARK: Toolbar（无分割线，浑然一体）

    private var toolbar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                // 文件名：hover 时正常显示，平时变淡
                Text(viewModel.displayFileName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .opacity(isToolbarHovered ? 0.92 : 0.34)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .animation(.easeInOut(duration: 0.18), value: isToolbarHovered)

                Spacer()

                // 保存状态（hover 时才可见）
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
                }

                // 功能按钮组：整体随 toolbar hover 淡入/淡出
                Group {
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
                        systemName: viewModel.isPreviewMode ? "pencil" : "doc.richtext",
                        shortcut: "⌘⇧P",
                        isActive: viewModel.isPreviewMode
                    ) {
                        viewModel.togglePreview()
                    }
                }
                .opacity(isToolbarHovered ? 1 : 0)
                .animation(.easeInOut(duration: 0.18), value: isToolbarHovered)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 7)

            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 0.5)
                .opacity(isContentAtTop ? 0 : 1)
                .animation(.easeInOut(duration: 0.16), value: isContentAtTop)
        }
        .contentShape(Rectangle())   // 让整个矩形区域响应 hover
        .onHover { isToolbarHovered = $0 }
    }

    private var noteSurface: some View {
        ZStack {
            Rectangle()
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.97))

            Rectangle()
                .fill(.ultraThinMaterial.opacity(0.18))

            LinearGradient(
                colors: [
                    Color.white.opacity(0.30),
                    Color.white.opacity(0.06),
                    Color.clear
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}

// MARK: - FloatingNoteViewModel

@MainActor
final class FloatingNoteViewModel: ObservableObject {
    @Published var content: String = ""
    @Published var isSaving: Bool = false
    @Published var lastSaveError: Error?
    @Published private(set) var fileURL: URL?

    // 预览模式
    @Published var isPreviewMode = false

    // 文件选择器状态
    @Published var isFilePickerVisible = false
    @Published var filePickerQuery = ""
    @Published var filePickerSelectedIndex = 0
    @Published var filePickerFiles: [URL] = []

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
        filePickerFiles = service.listMarkdownFiles(in: root)
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

    func hideFilePicker() {
        isFilePickerVisible = false
        focusEditorHandler?()
    }

    func toggleFilePicker() {
        if isFilePickerVisible { hideFilePicker() } else { showFilePicker() }
    }

    func togglePreview() {
        // 切换预览时关闭文件选择器，避免两层覆盖
        if isFilePickerVisible { hideFilePicker() }
        isPreviewMode.toggle()
        // 切回编辑时恢复 NSTextView 焦点
        if !isPreviewMode { focusEditorHandler?() }
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
