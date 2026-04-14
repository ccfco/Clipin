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

// MARK: - FloatingNoteView

/// 浮动笔记主界面：工具栏 + Markdown 编辑区。
struct FloatingNoteView: View {
    @ObservedObject var viewModel: FloatingNoteViewModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
                .opacity(0.3)
            MarkdownTextView(
                text: $viewModel.content,
                onSave: viewModel.save,
                onNaturalHeightChanged: viewModel.onNaturalHeightChanged
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.regularMaterial)
        .onAppear { viewModel.loadFile() }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            fileNameLabel
            Spacer()
            saveStatusLabel
            openInFinderButton
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

    var onClose: (() -> Void)?
    var onNaturalHeightChanged: ((CGFloat) -> Void)?

    private let service = FloatingNoteService.shared
    private let settings = SettingsStore.shared

    var displayFileName: String {
        fileURL?.lastPathComponent ?? "No file configured"
    }

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
}
