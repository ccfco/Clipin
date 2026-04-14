import AppKit
import SwiftUI
import Combine

// MARK: - MarkdownTextView

/// NSTextView 的 SwiftUI 包装，用于浮动笔记编辑区。
/// 使用标准 NSScrollView + NSTextView 组合，避免裸 NSTextView 的尺寸协商问题。
struct MarkdownTextView: NSViewRepresentable {
    @Binding var text: String
    var onSave: (String) -> Void
    var onNaturalHeightChanged: ((CGFloat) -> Void)?
    var onRegisterFocusHandler: ((@escaping () -> Void) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(onSave: onSave, onNaturalHeightChanged: onNaturalHeightChanged)
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

        textView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.textContainerInset = NSSize(width: 16, height: 16)
        textView.textContainer?.lineFragmentPadding = 0
        textView.backgroundColor = .clear

        scrollView.backgroundColor = .clear
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        // 只在内容真正不同时才赋值，避免光标跳位
        if textView.string != text {
            textView.string = text
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var textView: NSTextView?
        private let onSave: (String) -> Void
        private let onNaturalHeightChanged: ((CGFloat) -> Void)?
        private var saveTask: Task<Void, Never>?

        init(onSave: @escaping (String) -> Void,
             onNaturalHeightChanged: ((CGFloat) -> Void)?) {
            self.onSave = onSave
            self.onNaturalHeightChanged = onNaturalHeightChanged
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

        func reportNaturalHeight(for tv: NSTextView) {
            guard let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            lm.ensureLayout(for: tc)
            let used = lm.usedRect(for: tc)
            let height = used.height + tv.textContainerInset.height * 2
            onNaturalHeightChanged?(height)
        }
    }
}

// MARK: - FilePickerSearchField

/// NSTextField 子类：拦截 ↑↓/Enter/Esc，避免这些按键被默认文本行为消耗。
/// viewDidMoveToWindow 时主动抢焦点——makeNSView 执行时视图尚未进入窗口层级，
/// 直接调用 makeFirstResponder 会拿到 nil window，必须等到真正进入层级后再请求。
fileprivate final class NavigableTextField: NSTextField {
    var onUpArrow: (() -> Void)?
    var onDownArrow: (() -> Void)?
    var onReturn: (() -> Void)?
    var onEscape: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        // ZStack 条件渲染每次显示都会触发此回调，确保每次弹出都能获焦
        DispatchQueue.main.async { window.makeFirstResponder(self) }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 126: onUpArrow?()        // ↑
        case 125: onDownArrow?()       // ↓
        case 36, 76: onReturn?()       // Return / numpad Enter
        case 53: onEscape?()           // Esc
        default: super.keyDown(with: event)
        }
    }
}

/// 文件搜索框：自动获焦，上下键/Enter/Esc 通过回调上报。
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
        field.onUpArrow = onMoveUp
        field.onDownArrow = onMoveDown
        field.onReturn = onConfirm
        field.onEscape = onCancel
        // 焦点由 NavigableTextField.viewDidMoveToWindow 负责，此处不重复请求
        return field
    }

    func updateNSView(_ field: NavigableTextField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
        field.onUpArrow = onMoveUp
        field.onDownArrow = onMoveDown
        field.onReturn = onConfirm
        field.onEscape = onCancel
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        let parent: FilePickerSearchField
        init(parent: FilePickerSearchField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
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

// MARK: - FloatingNoteView

/// 浮动笔记主界面：工具栏 + Markdown 编辑区 + ⌘P 文件选择器覆盖层。
struct FloatingNoteView: View {
    @ObservedObject var viewModel: FloatingNoteViewModel

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                toolbar
                Divider()
                    .opacity(0.3)
                MarkdownTextView(
                    text: $viewModel.content,
                    onSave: viewModel.save,
                    onNaturalHeightChanged: viewModel.onNaturalHeightChanged,
                    onRegisterFocusHandler: { handler in
                        viewModel.focusEditorHandler = handler
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(.regularMaterial)

            if viewModel.isFilePickerVisible {
                FloatingNoteFilePicker(viewModel: viewModel)
            }
        }
        .onAppear { viewModel.loadFile() }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            fileNameLabel
            Spacer()
            saveStatusLabel
            openInFinderButton
            filePickerButton
            closeButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.03))
    }

    private var fileNameLabel: some View {
        Text(viewModel.displayFileName)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private var saveStatusLabel: some View {
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
    }

    private var openInFinderButton: some View {
        Button {
            viewModel.revealInFinder()
        } label: {
            Image(systemName: "folder")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Reveal in Finder")
        .opacity(viewModel.fileURL == nil ? 0 : 1)
    }

    private var filePickerButton: some View {
        Button {
            viewModel.toggleFilePicker()
        } label: {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(viewModel.isFilePickerVisible ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
        .help("切换文件 (⌘P)")
        .opacity(viewModel.hasRootFolder ? 1 : 0)
    }

    private var closeButton: some View {
        Button {
            viewModel.close()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Close (⌘W)")
        .keyboardShortcut("w", modifiers: .command)
    }
}

// MARK: - FloatingNoteViewModel

@MainActor
final class FloatingNoteViewModel: ObservableObject {
    @Published var content: String = ""
    @Published var isSaving: Bool = false
    @Published var lastSaveError: Error?
    @Published private(set) var fileURL: URL?

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
