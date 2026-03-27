import SwiftUI
import AppKit

// MARK: - PaletteAction

enum PaletteActionSection: Int {
    case primary
    case secondary
    case destructive
}

struct PaletteAction: Identifiable {
    let id = UUID()
    let title: String
    var localizedTitle: LocalizedStringKey { .init(title) }
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
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.colorScheme) private var colorScheme
    @Binding var isPresented: Bool
    let actions: [PaletteAction]
    @Binding var selectedIndex: Int
    let onSelect: (Int) -> Void
    @State private var hoveredIndex: Int?

    private var glass: ClipinGlassPalette {
        .make(theme: settings.visualTheme, colorScheme: colorScheme)
    }

    private var hierarchy: ClipinPanelHierarchy {
        .make(glass: glass, colorScheme: colorScheme)
    }

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
        VStack(alignment: .leading, spacing: 10) {
            paletteHeader

            if actions.isEmpty {
                emptyState
            } else {
                ForEach(Array(groupedActionIndices.enumerated()), id: \.offset) { _, group in
                    VStack(spacing: 4) {
                        ForEach(group, id: \.self) { index in
                            actionRow(action: actions[index], index: index)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 372, alignment: .leading)
        .background(
            ClipinSurfaceBackground(
                role: .floating,
                cornerRadius: ClipinChrome.paletteCornerRadius,
                glass: glass
            )
        )
        .shadow(color: .black.opacity(0.04), radius: 10, y: 3)
        .onAppear { selectedIndex = 0 }
    }

    private var paletteHeader: some View {
        HStack(spacing: 8) {
            Text("Actions")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.secondary)

            Spacer()

            ClipinKeycap(
                key: "Esc",
                foreground: Color(nsColor: .secondaryLabelColor),
                background: glass.keycapTint
            )
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
        .padding(.bottom, 4)
    }

    private func actionRow(action: PaletteAction, index: Int) -> some View {
        let isSelected = selectedIndex == index
        let isHovered = hoveredIndex == index
        let selectedFill = action.isDestructive ? Color.red.opacity(colorScheme == .dark ? 0.18 : 0.12) : hierarchy.selection.fill
        let selectedStroke = action.isDestructive ? Color.red.opacity(colorScheme == .dark ? 0.30 : 0.22) : hierarchy.selection.stroke
        let selectedInk = action.isDestructive ? Color.red.opacity(colorScheme == .dark ? 0.92 : 0.82) : hierarchy.selection.ink
        let selectedSecondaryInk = action.isDestructive ? Color.red.opacity(colorScheme == .dark ? 0.72 : 0.64) : hierarchy.selection.secondaryInk
        let selectedBadgeFill = action.isDestructive ? Color.red.opacity(colorScheme == .dark ? 0.14 : 0.10) : hierarchy.selection.badgeFill

        return HStack(spacing: 0) {
            Label {
                Text(action.localizedTitle)
                    .font(.system(size: 15, weight: .medium))
            } icon: {
                Image(systemName: action.systemImage)
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(
                action.isDestructive
                    ? (isSelected ? selectedInk : Color.red)
                    : (isSelected ? selectedInk : Color.primary)
            )

            Spacer()

            ClipinKeycap(
                key: action.badge,
                foreground: isSelected ? selectedSecondaryInk : Color.secondary.opacity(0.88),
                background: isSelected ? selectedBadgeFill : glass.keycapTint
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            ClipinSelectableRowBackground(
                isSelected: isSelected,
                isHovered: isHovered,
                selectionFill: selectedFill,
                selectionStroke: selectedStroke,
                hoverFill: glass.hoverFill,
                hoverStroke: glass.hoverStroke
            )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selectedIndex = index
            onSelect(index)
        }
        .onHover { hovered in
            hoveredIndex = hovered ? index : nil
        }
        .animation(ClipinMotion.feedback, value: isSelected)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "command")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.tertiary)

            Text("No actions available")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            Text("Press Escape to close.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 220)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }
}

// MARK: - ActionPaletteBuilder

struct ActionPaletteBuilder {
    @MainActor
    static func actions(for viewModel: ClipboardViewModel) -> [PaletteAction] {
        var list: [PaletteAction] = []

        if let selected = viewModel.selectedListItem {
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

            list.append(PaletteAction(selected.isPinned ? "Unpin" : "Pin", systemImage: selected.isPinned ? "pin.slash" : "pin", badge: "⌘⇧P") {
                viewModel.togglePinSelected()
            })

            if viewModel.canOpenSelectedItem {
                list.append(PaletteAction(viewModel.selectedOpenLabel, systemImage: viewModel.selectedOpenSystemImage, badge: "⌘O") {
                    viewModel.openSelected()
                })
            }
        }

        if viewModel.hasActiveFilter {
            list.append(PaletteAction("Clear Search & Filters", systemImage: "line.3.horizontal.decrease.circle", badge: "↵") {
                _ = viewModel.clearActiveQueryAndFilters()
            })
        }

        list.append(PaletteAction(viewModel.isPanelPinned ? "Disable Stay Open" : "Enable Stay Open", systemImage: viewModel.isPanelPinned ? "pin.slash" : "pin", badge: "⌘⇧L") {
            viewModel.togglePanelPin()
        })

        list.append(PaletteAction("Open Settings", systemImage: "gearshape", badge: "⌘,") {
            viewModel.openSettings()
        })

        if viewModel.selectedListItem != nil {
            list.append(PaletteAction("Delete", systemImage: "trash", badge: "⌘⌫", section: .destructive, isDestructive: true) {
                viewModel.deleteSelected()
            })
        }

        return list
    }
}
