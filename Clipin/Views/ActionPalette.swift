import SwiftUI
import AppKit

private let paletteBackground = Color(nsColor: NSColor(name: nil) { app in
    app.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        ? NSColor(srgbRed: 0.19, green: 0.18, blue: 0.27, alpha: 0.54)
        : NSColor(srgbRed: 0.994, green: 0.992, blue: 1.0, alpha: 0.54)
})

private let paletteHighlight = Color(nsColor: NSColor(name: nil) { app in
    app.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        ? NSColor(srgbRed: 0.35, green: 0.32, blue: 0.46, alpha: 0.18)
        : NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.46)
})

// MARK: - PaletteAction

enum PaletteActionSection: Int {
    case primary
    case secondary
    case destructive
}

struct PaletteAction: Identifiable {
    let id = UUID()
    let title: String
    let systemImage: String
    let badge: String
    let section: PaletteActionSection
    let isDestructive: Bool
    let handler: () -> Void

    init(
        _ title: String,
        systemImage: String,
        badge: String,
        section: PaletteActionSection = .secondary,
        isDestructive: Bool = false,
        handler: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.badge = badge
        self.section = section
        self.isDestructive = isDestructive
        self.handler = handler
    }
}

// MARK: - ActionPalette
//
// 键盘导航完全由 AppDelegate.keyMonitor 负责（palette 开启时拦截 ↑↓/Enter/Escape），
// 此视图只负责渲染和鼠标交互。

struct ActionPalette: View {
    @Binding var isPresented: Bool
    let actions: [PaletteAction]
    @Binding var selectedIndex: Int
    let onSelect: (Int) -> Void

    private var groupedActionIndices: [[Int]] {
        var groups: [[Int]] = []
        for (index, action) in actions.enumerated() {
            if let last = groups.indices.last,
               let firstIndex = groups[last].first,
               actions[firstIndex].section == action.section {
                groups[last].append(index)
            } else {
                groups.append([index])
            }
        }
        return groups
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }

            palettePanel
                .padding(.trailing, 18)
                .padding(.bottom, 62)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }

    private func dismiss() {
        isPresented = false
    }

    private var palettePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(groupedActionIndices.enumerated()), id: \.offset) { _, group in
                VStack(spacing: 4) {
                    ForEach(group, id: \.self) { index in
                        actionRow(action: actions[index], index: index)
                    }
                }
            }
        }
        .padding(10)
        .frame(width: 372, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(paletteBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [paletteHighlight, Color.clear],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
        )
        .shadow(color: .black.opacity(0.12), radius: 34, y: 18)
        .shadow(color: .black.opacity(0.04), radius: 10, y: 3)
        .onAppear { selectedIndex = 0 }
    }

    private func actionRow(action: PaletteAction, index: Int) -> some View {
        let isSelected = selectedIndex == index

        return HStack(spacing: 0) {
            Label {
                Text(action.title)
                    .font(.system(size: 15, weight: .medium))
            } icon: {
                Image(systemName: action.systemImage)
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(
                action.isDestructive
                    ? (isSelected ? Color.white : Color.red)
                    : (isSelected ? Color.white : Color.primary)
            )

            Spacer()

            Text(action.badge)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(isSelected ? Color.white.opacity(0.68) : Color.secondary.opacity(0.88))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isSelected ? Color.white.opacity(0.14) : Color.white.opacity(0.08))
                )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    isSelected
                        ? (action.isDestructive ? Color.red.opacity(0.84) : Color.accentColor.opacity(0.78))
                        : Color.clear
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selectedIndex = index
            onSelect(index)
        }
        .onHover { hovered in
            if hovered { selectedIndex = index }
        }
        .animation(.easeOut(duration: 0.08), value: isSelected)
    }
}

// MARK: - ActionPaletteBuilder

struct ActionPaletteBuilder {
    @MainActor
    static func actions(for viewModel: ClipboardViewModel) -> [PaletteAction] {
        guard let selected = viewModel.selectedListItem else { return [] }

        var list: [PaletteAction] = []

        list.append(PaletteAction("Paste", systemImage: "arrowshape.turn.up.left.fill", badge: "↵", section: .primary) {
            viewModel.pasteSelected()
        })

        if selected.clipType == .text || selected.clipType == .url {
            list.append(PaletteAction("Paste as Plain Text", systemImage: "textformat", badge: "⇧↵", section: .primary) {
                viewModel.pastePlainSelected()
            })
        }

        list.append(PaletteAction("Copy to Clipboard", systemImage: "doc.on.doc", badge: "⌘C", section: .primary) {
            viewModel.copySelected()
        })

        list.append(PaletteAction("Quick Look", systemImage: "space", badge: "Space", section: .primary) {
            viewModel.quickLookSelected()
        })

        list.append(PaletteAction(selected.isPinned ? "Unpin" : "Pin", systemImage: selected.isPinned ? "pin.slash" : "pin", badge: "⌘⇧P") {
            viewModel.togglePinSelected()
        })

        if selected.clipType == .url || selected.clipType == .file {
            list.append(PaletteAction("Open", systemImage: "arrow.up.right.square", badge: "⌘O") {
                viewModel.openSelected()
            })
        }

        list.append(PaletteAction("Delete", systemImage: "trash", badge: "⌘⌫", section: .destructive, isDestructive: true) {
            viewModel.deleteSelected()
        })

        return list
    }
}
