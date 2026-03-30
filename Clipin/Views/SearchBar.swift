import SwiftUI
import AppKit

// MARK: - Key-intercepting NSTextField

/// NSTextField 子类：拦截 ↑↓/Return/Escape/Tab，传给回调而非默认文本行为
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
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.colorScheme) private var colorScheme
    @Binding var query: String
    @Binding var typeFilter: ClipType?
    @Binding var isPinnedView: Bool
    let sceneState: ClipinSceneState
    var onNavigate: (Int) -> Void = { _ in }
    var onSubmit: () -> Void = {}
    var onEscape: () -> Void = {}
    var onCycleTypeFilter: (Bool) -> Void = { _ in }

    private var glass: ClipinGlassPalette {
        .make(theme: settings.visualTheme, colorScheme: colorScheme)
    }

    private var hierarchy: ClipinPanelHierarchy {
        .make(glass: glass, colorScheme: colorScheme)
    }

    private var idlePillStroke: Color {
        glass.hoverStroke.opacity(colorScheme == .dark ? 0.95 : 0.75)
    }

    private var filterRailFill: Color {
        glass.controlFill.opacity(colorScheme == .dark ? 0.68 : 0.52)
    }

    private var filterRailStroke: Color {
        glass.controlStroke.opacity(colorScheme == .dark ? 0.68 : 0.46)
    }

    var body: some View {
        HStack(spacing: 8) {
            searchGlyph

            InterceptingTextFieldView(
                text: $query,
                placeholder: NSLocalizedString("Search…  · Tab", comment: ""),
                onNavigate: onNavigate,
                onSubmit: onSubmit,
                onEscape: onEscape,
                onTab: onCycleTypeFilter
            )
            .frame(height: 18)
            .layoutPriority(-1)

            filterRail

            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(hierarchy.support.hintInk)
                        .frame(width: 24, height: 24)
                        .background(
                            Circle()
                                .fill(glass.keycapTint.opacity(colorScheme == .dark ? 0.86 : 0.94))
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            ClipinSurfaceBackground(
                role: .control,
                cornerRadius: ClipinChrome.searchCornerRadius,
                glass: glass
            )
        )
        .overlay {
            RoundedRectangle(cornerRadius: ClipinChrome.searchCornerRadius, style: .continuous)
                .strokeBorder(glass.emphasisStroke.opacity(sceneState.headerAccentOpacity), lineWidth: 0.6)
        }
        .shadow(
            color: glass.emphasisStrongFill.opacity(sceneState.headerGlowOpacity),
            radius: 12,
            y: 2
        )
        .animation(ClipinMotion.focusShift, value: sceneState)
    }

    private var searchGlyph: some View {
        ZStack {
            Circle()
                .fill(glass.keycapTint.opacity(colorScheme == .dark ? 0.92 : 1.0))
            Image(systemName: "magnifyingglass")
                .foregroundStyle(hierarchy.support.subduedInk)
                .font(.system(size: 13, weight: .medium))
        }
        .frame(width: 28, height: 28)
    }

    private var filterRail: some View {
        filterPills
            .padding(.horizontal, 5)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(filterRailFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(filterRailStroke, lineWidth: 0.5)
                    )
            )
    }

    private var filterPills: some View {
        HStack(spacing: 3) {
            pinnedPill
            pill(label: "Text",   filter: .text,  shortcut: "⌥2")
            pill(label: "Images", filter: .image, shortcut: "⌥3")
            pill(label: "Files",  filter: .file,  shortcut: "⌥4")
            pill(label: "URLs",   filter: .url,   shortcut: "⌥5")
        }
    }

    /// 固定视图专用 pill，与类型 pills 互斥激活
    private var pinnedPill: some View {
        let isActive = isPinnedView
        return Button {
            isPinnedView = true
            typeFilter = nil
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(isActive ? hierarchy.scope.ink : hierarchy.support.subduedInk)
                Text("⌥1")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(isActive ? hierarchy.scope.shortcutInk : hierarchy.support.hintInk)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isActive ? hierarchy.scope.fill : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(
                                isActive ? hierarchy.scope.stroke : idlePillStroke,
                                lineWidth: 0.5
                            )
                    )
            )
        }
        .buttonStyle(.plain)
        .animation(ClipinMotion.feedback, value: isActive)
    }

    private func pill(label: LocalizedStringKey, filter: ClipType?, shortcut: String) -> some View {
        // 固定视图激活时，类型 pills 全部不高亮
        let isActive = !isPinnedView && typeFilter == filter

        return Button {
            isPinnedView = false
            typeFilter = filter
        } label: {
            HStack(spacing: 3) {
                Text(label)
                    .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? hierarchy.scope.ink : hierarchy.support.subduedInk)
                Text(shortcut)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(isActive ? hierarchy.scope.shortcutInk : hierarchy.support.hintInk)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isActive ? hierarchy.scope.fill : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(
                                isActive ? hierarchy.scope.stroke : idlePillStroke,
                                lineWidth: 0.5
                            )
                    )
            )
        }
        .buttonStyle(.plain)
        .animation(ClipinMotion.feedback, value: isActive)
    }

}
