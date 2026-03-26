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
    @Binding var isPresented: Bool
    let query: String
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
            paletteHeader

            ForEach(Array(groupedActionIndices.enumerated()), id: \.offset) { _, group in
                VStack(spacing: 4) {
                    ForEach(group, id: \.self) { index in
                        actionRow(action: actions[index], index: index)
                    }
                }
            }

            if actions.isEmpty {
                emptyState
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

                Text("Esc")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                    )
            }

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
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .padding(.bottom, 2)
    }

    private func actionRow(action: PaletteAction, index: Int) -> some View {
        let isSelected = selectedIndex == index

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
