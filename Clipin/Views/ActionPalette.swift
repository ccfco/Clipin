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
    let keywords: [String]
    let section: PaletteActionSection
    let isDestructive: Bool
    let handler: () -> Void

    init(
        _ title: String,
        systemImage: String,
        badge: String,
        keywords: [String] = [],
        section: PaletteActionSection = .secondary,
        isDestructive: Bool = false,
        handler: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.badge = badge
        self.keywords = keywords
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
    let query: String
    let actions: [PaletteAction]
    @Binding var selectedIndex: Int
    let onSelect: (Int) -> Void

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

            ForEach(Array(groupedActionIndices.enumerated()), id: \.offset) { _, group in
                VStack(spacing: 4) {
                    ForEach(group, id: \.self) { index in
                        actionRow(action: actions[index], index: index)
                    }
                }
                .padding(6)
                .background(
                    ClipinRoundedSurface(
                        cornerRadius: ClipinChrome.cardCornerRadius,
                        material: .thinMaterial,
                        tint: glass.controlFill.opacity(colorScheme == .dark ? 0.96 : 0.9),
                        stroke: glass.hoverStroke,
                        highlight: glass.shellHighlight.opacity(colorScheme == .dark ? 0.04 : 0.18)
                    )
                )
            }

            if actions.isEmpty {
                emptyState
            }
        }
        .padding(12)
        .frame(width: 372, alignment: .leading)
        .background(
            ClipinRoundedSurface(
                cornerRadius: ClipinChrome.paletteCornerRadius,
                material: .regularMaterial,
                tint: glass.detailTint,
                stroke: glass.controlStroke,
                highlight: glass.shellHighlight.opacity(colorScheme == .dark ? 0.10 : 0.28),
                shadowColor: .black.opacity(0.12),
                shadowRadius: 34,
                shadowYOffset: 18
            )
        )
        .shadow(color: .black.opacity(0.04), radius: 10, y: 3)
        .onAppear { selectedIndex = 0 }
    }

    private var paletteHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                Group {
                    if query.isEmpty { Text("Search actions") } else { Text(verbatim: query) }
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(query.isEmpty ? .tertiary : .primary)
                .lineLimit(1)

                Spacer()

                ClipinKeycap(
                    key: "Esc",
                    foreground: Color(nsColor: .secondaryLabelColor),
                    background: glass.keycapTint
                )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(
                ClipinRoundedSurface(
                    cornerRadius: ClipinChrome.searchCornerRadius,
                    material: .regularMaterial,
                    tint: glass.controlFill,
                    stroke: glass.controlStroke,
                    highlight: glass.shellHighlight.opacity(colorScheme == .dark ? 0.16 : 0.34)
                )
            )

            if !query.isEmpty {
                Text(verbatim: {
                    let hint = NSLocalizedString("Esc clears query, Esc again closes", comment: "")
                    let count = actions.count == 1
                        ? NSLocalizedString("1 action", comment: "")
                        : String(format: NSLocalizedString("%d actions", comment: ""), actions.count)
                    return "\(hint) · \(count)"
                }())
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
            }
        }
    }

    private func actionRow(action: PaletteAction, index: Int) -> some View {
        let isSelected = selectedIndex == index
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
            RoundedRectangle(cornerRadius: ClipinChrome.rowCornerRadius, style: .continuous)
                .fill(
                    isSelected
                        ? selectedFill
                        : Color.clear
                )
                .overlay(
                    RoundedRectangle(cornerRadius: ClipinChrome.rowCornerRadius, style: .continuous)
                        .strokeBorder(isSelected ? selectedStroke : Color.clear, lineWidth: 0.5)
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
        .animation(ClipinMotion.feedback, value: isSelected)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "command")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.tertiary)

            Text("No actions found")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            Text(query.isEmpty
                 ? LocalizedStringKey("Keep typing to narrow down available actions, or press Escape to close.")
                 : LocalizedStringKey("No matches yet. Press Escape to clear the filter, then Escape again to close."))
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
            list.append(PaletteAction("Paste", systemImage: "arrowshape.turn.up.left.fill", badge: "↵", keywords: ["insert", "send"], section: .primary) {
                viewModel.pasteSelected()
            })

            if selected.clipType == .text || selected.clipType == .url {
                list.append(PaletteAction("Paste as Plain Text", systemImage: "textformat", badge: "⇧↵", keywords: ["plain", "text only", "strip formatting"], section: .primary) {
                    viewModel.pastePlainSelected()
                })
            }

            list.append(PaletteAction("Copy to Clipboard", systemImage: "doc.on.doc", badge: "⌘C", keywords: ["copy", "clipboard", "yank"], section: .primary) {
                viewModel.copySelected()
            })

            list.append(PaletteAction(selected.isPinned ? "Unpin" : "Pin", systemImage: selected.isPinned ? "pin.slash" : "pin", badge: "⌘⇧P", keywords: ["favorite", "keep", "stay"]) {
                viewModel.togglePinSelected()
            })

            if viewModel.canOpenSelectedItem {
                list.append(PaletteAction(viewModel.selectedOpenLabel, systemImage: viewModel.selectedOpenSystemImage, badge: "⌘O", keywords: ["launch", "reveal", "finder", "visit", "browser", "show"]) {
                    viewModel.openSelected()
                })
            }
        }

        if viewModel.hasActiveFilter {
            list.append(PaletteAction("Clear Search & Filters", systemImage: "line.3.horizontal.decrease.circle", badge: "↵", keywords: ["reset", "clear", "search", "filter", "all"]) {
                _ = viewModel.clearActiveQueryAndFilters()
            })
        }

        list.append(PaletteAction(viewModel.isPanelPinned ? "Disable Stay Open" : "Enable Stay Open", systemImage: viewModel.isPanelPinned ? "pin.slash" : "pin", badge: "⌘⇧L", keywords: ["pin", "stay", "keep open", "panel"]) {
            viewModel.togglePanelPin()
        })

        list.append(PaletteAction("Open Settings", systemImage: "gearshape", badge: "⌘,", keywords: ["preferences", "settings", "config"]) {
            viewModel.openSettings()
        })

        if viewModel.selectedListItem != nil {
            list.append(PaletteAction("Delete", systemImage: "trash", badge: "⌘⌫", keywords: ["remove", "trash"], section: .destructive, isDestructive: true) {
                viewModel.deleteSelected()
            })
        }

        return list
    }
}
