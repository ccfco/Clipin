import SwiftUI
import AppKit

private let searchBgInner = Color(nsColor: NSColor(name: nil) { app in
    app.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        ? NSColor(srgbRed: 0.18, green: 0.17, blue: 0.25, alpha: 0.72)
        : NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.88)
})

private let searchBgOuter = Color(nsColor: NSColor(name: nil) { app in
    app.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        ? NSColor(srgbRed: 0.13, green: 0.12, blue: 0.19, alpha: 0.20)
        : NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.14)
})

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
        context.coordinator.field = field
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
        weak var field: InterceptingTextField?
        private var isObservingRestoreFocus = false

        init(_ p: InterceptingTextFieldView) {
            parent = p
            super.init()
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(restoreSearchFocus),
                name: .clipinRestoreSearchFocus,
                object: nil
            )
            isObservingRestoreFocus = true
        }

        deinit {
            if isObservingRestoreFocus {
                NotificationCenter.default.removeObserver(self, name: .clipinRestoreSearchFocus, object: nil)
            }
        }

        @MainActor
        @objc private func restoreSearchFocus() {
            guard let field else { return }
            field.window?.makeFirstResponder(field)
        }

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
                placeholder: "Search...",
                onNavigate: onNavigate,
                onSubmit: onSubmit,
                onEscape: onEscape,
                onTab: { cycleTypeFilter() }
            )
            .frame(height: 18)
            .layoutPriority(-1)  // 让 pills 优先获得空间，textfield 填充剩余

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
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(searchBgInner)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .white.opacity(0.18), radius: 6, y: 1)
        .shadow(color: .black.opacity(0.03), radius: 10, y: 6)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(searchBgOuter)
    }

    private var filterPills: some View {
        HStack(spacing: 3) {
            pill(label: "All",    filter: nil,    shortcut: "⌥1")
            pill(label: "Text",   filter: .text,  shortcut: "⌥2")
            pill(label: "Images", filter: .image, shortcut: "⌥3")
            pill(label: "Files",  filter: .file,  shortcut: "⌥4")
            pill(label: "URLs",   filter: .url,   shortcut: "⌥5")
        }
    }

    private func pill(label: String, filter: ClipType?, shortcut: String) -> some View {
        let isActive = typeFilter == filter

        return Button {
            typeFilter = filter
        } label: {
            HStack(spacing: 3) {
                Text(label)
                    .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? Color.white : Color.secondary.opacity(0.88))
                Text(shortcut)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(isActive ? Color.white.opacity(0.65) : Color(nsColor: .quaternaryLabelColor))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isActive ? Color.accentColor.opacity(0.96) : Color.clear)
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
