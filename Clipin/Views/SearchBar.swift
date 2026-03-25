import SwiftUI
import AppKit

// MARK: - Key-intercepting NSTextField

/// NSTextField 子类：拦截 ↑↓/Return/Escape，传给回调而非默认文本行为
private final class InterceptingTextField: NSTextField {
    var onNavigate: ((Int) -> Void)?
    var onSubmit: (() -> Void)?
    var onEscape: (() -> Void)?
}

/// SwiftUI 包装层
private struct InterceptingTextFieldView: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onNavigate: (Int) -> Void
    var onSubmit: () -> Void
    var onEscape: () -> Void

    func makeNSView(context: Context) -> InterceptingTextField {
        let field = InterceptingTextField()
        field.isBordered = false
        field.backgroundColor = .clear
        field.font = .systemFont(ofSize: 14)
        field.placeholderString = placeholder
        field.focusRingType = .none
        field.delegate = context.coordinator
        // 面板出现时自动聚焦
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
        }
        return field
    }

    func updateNSView(_ nsView: InterceptingTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.onNavigate = onNavigate
        nsView.onSubmit = onSubmit
        nsView.onEscape = onEscape
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: InterceptingTextFieldView
        init(_ p: InterceptingTextFieldView) { parent = p }

        func controlTextDidChange(_ obj: Notification) {
            guard let f = obj.object as? NSTextField else { return }
            parent.text = f.stringValue
        }

        /// 在 field editor 处理命令前拦截，确保编辑状态下上下键也能导航列表
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard let field = control as? InterceptingTextField else { return false }
            switch selector {
            case #selector(NSResponder.moveDown(_:)):
                field.onNavigate?(1)
                return true
            case #selector(NSResponder.moveUp(_:)):
                field.onNavigate?(-1)
                return true
            case #selector(NSResponder.insertNewline(_:)):
                field.onSubmit?()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                field.onEscape?()
                return true
            default:
                return false
            }
        }
    }
}

// MARK: - SearchBar

/// 搜索框 + 类型过滤（箭头键导航传给列表）
struct SearchBar: View {
    @Binding var query: String
    @Binding var typeFilter: ClipType?
    var onNavigate: (Int) -> Void = { _ in }
    var onSubmit: () -> Void = {}
    var onEscape: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 14))

                InterceptingTextFieldView(
                    text: $query,
                    placeholder: "Type to filter entries...",
                    onNavigate: onNavigate,
                    onSubmit: onSubmit,
                    onEscape: onEscape
                )
                .frame(height: 18)

                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.06), lineWidth: 1)
            )

            Menu {
                Button("All Types") { typeFilter = nil }
                Divider()
                Button("Text")   { typeFilter = .text }
                Button("Images") { typeFilter = .image }
                Button("Files")  { typeFilter = .file }
                Button("URLs")   { typeFilter = .url }
            } label: {
                HStack(spacing: 4) {
                    Text(filterLabel)
                        .font(.system(size: 12))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.06), lineWidth: 1)
                )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var filterLabel: String {
        guard let filter = typeFilter else { return "All Types" }
        switch filter {
        case .text:  return "Text"
        case .image: return "Images"
        case .file:  return "Files"
        case .url:   return "URLs"
        }
    }
}
