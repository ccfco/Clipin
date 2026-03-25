import SwiftUI
import AppKit

// MARK: - PaletteAction

struct PaletteAction: Identifiable {
    let id = UUID()
    let title: String
    let badge: String
    let isDestructive: Bool
    let handler: () -> Void

    init(_ title: String, badge: String, isDestructive: Bool = false, handler: @escaping () -> Void) {
        self.title = title
        self.badge = badge
        self.isDestructive = isDestructive
        self.handler = handler
    }
}

// MARK: - Invisible keyboard field

/// 透明 NSTextField，仅用于捕获键盘事件（与 SearchBar 中的 InterceptingTextField 同模式）
private final class PaletteKeyField: NSTextField {
    var onNavigate: ((Int) -> Void)?
    var onSubmit: (() -> Void)?
    var onEscape: (() -> Void)?
}

private struct PaletteKeyFieldView: NSViewRepresentable {
    var onNavigate: (Int) -> Void
    var onSubmit: () -> Void
    var onEscape: () -> Void

    func makeNSView(context: Context) -> PaletteKeyField {
        let field = PaletteKeyField()
        field.isBordered = false
        field.backgroundColor = .clear
        field.isEditable = false
        field.isSelectable = false
        field.focusRingType = .none
        field.delegate = context.coordinator
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
        }
        return field
    }

    func updateNSView(_ nsView: PaletteKeyField, context: Context) {
        nsView.onNavigate = onNavigate
        nsView.onSubmit = onSubmit
        nsView.onEscape = onEscape
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PaletteKeyFieldView
        init(_ p: PaletteKeyFieldView) { parent = p }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard let field = control as? PaletteKeyField else { return false }
            switch selector {
            case #selector(NSResponder.moveDown(_:)):
                field.onNavigate?(1); return true
            case #selector(NSResponder.moveUp(_:)):
                field.onNavigate?(-1); return true
            case #selector(NSResponder.insertNewline(_:)):
                field.onSubmit?(); return true
            case #selector(NSResponder.cancelOperation(_:)):
                field.onEscape?(); return true
            default:
                return false
            }
        }
    }
}

// MARK: - ActionPalette

struct ActionPalette: View {
    @Binding var isPresented: Bool
    let actions: [PaletteAction]

    @State private var selectedIndex = 0

    private func dismiss() {
        isPresented = false
        NotificationCenter.default.post(name: .clipinRestoreSearchFocus, object: nil)
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // 点击遮罩关闭
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }

            palettePanel
                .padding(.horizontal, 14)
                .padding(.bottom, 48) // 悬在 bottomBar 上方
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }

    private var palettePanel: some View {
        VStack(spacing: 0) {
            // 不可见键盘捕获 field
            PaletteKeyFieldView(
                onNavigate: { delta in
                    let newIndex = selectedIndex + delta
                    if newIndex >= 0, newIndex < actions.count {
                        selectedIndex = newIndex
                    }
                },
                onSubmit: {
                    guard selectedIndex < actions.count else { return }
                    actions[selectedIndex].handler()
                    dismiss()
                },
                onEscape: { dismiss() }
            )
            .frame(width: 0, height: 0)

            ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                actionRow(action: action, index: index)
                if index < actions.count - 1 {
                    Divider().opacity(0.4).padding(.horizontal, 10)
                }
            }
        }
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.12), radius: 16, y: -4)
        .shadow(color: .black.opacity(0.06), radius: 4, y: -1)
        .onAppear { selectedIndex = 0 }
    }

    private func actionRow(action: PaletteAction, index: Int) -> some View {
        let isSelected = selectedIndex == index

        return HStack(spacing: 0) {
            Text(action.title)
                .font(.system(size: 13))
                .foregroundStyle(
                    action.isDestructive
                        ? (isSelected ? Color.white : Color.red)
                        : (isSelected ? Color.white : Color.primary)
                )
            Spacer()
            Text(action.badge)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(
                    isSelected ? Color.white.opacity(0.7) : Color.secondary
                )
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(isSelected ? Color.white.opacity(0.15) : Color.primary.opacity(0.06))
                )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(
                    isSelected
                        ? (action.isDestructive ? Color.red : Color.accentColor)
                        : Color.clear
                )
                .padding(.horizontal, 4)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selectedIndex = index
            action.handler()
            dismiss()
        }
        .onHover { hovered in
            if hovered { selectedIndex = index }
        }
        .animation(.easeOut(duration: 0.08), value: isSelected)
    }
}

// MARK: - ActionPaletteBuilder

/// 根据 viewModel 当前选中 item 构建操作列表
struct ActionPaletteBuilder {
    @MainActor
    static func actions(for viewModel: ClipboardViewModel) -> [PaletteAction] {
        guard viewModel.selectedListItem != nil else { return [] }

        var list: [PaletteAction] = []

        list.append(PaletteAction("Paste", badge: "↵") {
            viewModel.pasteSelected()
        })

        if let item = viewModel.selectedItem,
           item.clipType == .text || item.clipType == .url {
            list.append(PaletteAction("Paste as Plain Text", badge: "⇧↵") {
                viewModel.pastePlainSelected()
            })
        }

        list.append(PaletteAction("Copy to Clipboard", badge: "⌘C") {
            viewModel.copySelected()
        })

        let isPinned = viewModel.selectedListItem?.isPinned == true
        list.append(PaletteAction(isPinned ? "Unpin" : "Pin", badge: "⌘⇧P") {
            viewModel.togglePinSelected()
        })

        if let item = viewModel.selectedItem,
           item.clipType == .url || item.clipType == .file {
            list.append(PaletteAction("Open", badge: "⌘O") {
                viewModel.openSelected()
            })
        }

        list.append(PaletteAction("Delete", badge: "⌘⌫", isDestructive: true) {
            viewModel.deleteSelected()
        })

        return list
    }
}
