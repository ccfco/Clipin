import SwiftUI
import AppKit

// MARK: - Key-intercepting NSTextField

/// NSTextField 子类：拦截 ↑↓/Return/Escape/Tab，传给回调而非默认文本行为
private final class InterceptingTextField: NSTextField {
    var onNavigate: ((Int) -> Void)?
    var onSubmit: (() -> Void)?
    var onEscape: (() -> Void)?
    var onTab: (() -> Void)?
}

/// SwiftUI 包装层
private struct InterceptingTextFieldView: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onNavigate: (Int) -> Void
    var onSubmit: () -> Void
    var onEscape: () -> Void
    var onTab: () -> Void = {}

    func makeNSView(context: Context) -> InterceptingTextField {
        let field = InterceptingTextField()
        field.isBordered = false
        field.backgroundColor = .clear
        field.font = .systemFont(ofSize: 15)
        field.placeholderString = placeholder
        field.focusRingType = .none
        field.delegate = context.coordinator
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
        nsView.onTab = onTab
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: InterceptingTextFieldView
        init(_ p: InterceptingTextFieldView) { parent = p }

        func controlTextDidChange(_ obj: Notification) {
            guard let f = obj.object as? NSTextField else { return }
            parent.text = f.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard let field = control as? InterceptingTextField else { return false }
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
                field.onTab?(); return true
            default:
                return false
            }
        }
    }
}

// MARK: - SearchBar

/// 搜索框 + 内嵌类型过滤 pill tabs
struct SearchBar: View {
    @Binding var query: String
    @Binding var typeFilter: ClipType?
    var onNavigate: (Int) -> Void = { _ in }
    var onSubmit: () -> Void = {}
    var onEscape: () -> Void = {}

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 14))

            InterceptingTextFieldView(
                text: $query,
                placeholder: "Search clipboard history...",
                onNavigate: onNavigate,
                onSubmit: onSubmit,
                onEscape: onEscape,
                onTab: { cycleTypeFilter() }
            )
            .frame(height: 18)

            // 类型过滤 pill tabs
            filterPills

            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var filterPills: some View {
        HStack(spacing: 3) {
            pill(label: "All", filter: nil)
            pill(label: "Text", filter: .text)
            pill(label: "Images", filter: .image)
            pill(label: "Files", filter: .file)
            pill(label: "URLs", filter: .url)
        }
    }

    private func pill(label: String, filter: ClipType?) -> some View {
        let isActive = typeFilter == filter

        return Button {
            typeFilter = filter
        } label: {
            Text(label)
                .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? Color.white : Color.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isActive ? Color.accentColor : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: isActive)
    }

    /// Tab 键循环切换：All → Text → Images → Files → URLs → All
    private func cycleTypeFilter() {
        switch typeFilter {
        case nil:    typeFilter = .text
        case .text:  typeFilter = .image
        case .image: typeFilter = .file
        case .file:  typeFilter = .url
        case .url:   typeFilter = nil
        }
    }
}
