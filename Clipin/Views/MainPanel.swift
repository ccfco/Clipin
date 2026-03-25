import SwiftUI

// MARK: - 品牌色（Raycast 风格淡紫，深浅色自适应）

private let panelShell = Color(nsColor: NSColor(name: nil) { app in
    app.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        ? NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1)
        : NSColor(srgbRed: 0.972, green: 0.968, blue: 0.988, alpha: 1)
})

private let chromeSurface = Color(nsColor: NSColor(name: nil) { app in
    app.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        ? NSColor(srgbRed: 0.14, green: 0.14, blue: 0.15, alpha: 0.6)
        : NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.36)
})

private let sidebarSurface = Color(nsColor: NSColor(name: nil) { app in
    app.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        ? NSColor(srgbRed: 0.16, green: 0.16, blue: 0.17, alpha: 0.85)
        : NSColor(srgbRed: 0.944, green: 0.938, blue: 0.974, alpha: 0.96)
})

private let detailSurface = Color(nsColor: NSColor(name: nil) { app in
    app.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        ? NSColor(srgbRed: 0.18, green: 0.18, blue: 0.19, alpha: 0.95)
        : NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.99)
})

private let shellGlow = LinearGradient(
    colors: [
        Color.white.opacity(0.20),
        Color.white.opacity(0.05),
        Color.clear
    ],
    startPoint: .topLeading,
    endPoint: .bottomTrailing
)

private let panelWash = LinearGradient(
    colors: [
        Color.white.opacity(0.18),
        Color.white.opacity(0.05),
        Color.clear
    ],
    startPoint: .top,
    endPoint: .bottom
)

/// 主面板 — 偏原生 macOS 的双栏布局
struct MainPanel: View {
    @ObservedObject var viewModel: ClipboardViewModel
    var onOpenSettings: () -> Void = {}

    init(viewModel: ClipboardViewModel, onOpenSettings: @escaping () -> Void = {}) {
        self.viewModel = viewModel
        self.onOpenSettings = onOpenSettings
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            contentArea
            bottomBar
        }
        .frame(width: 800, height: 540)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [panelShell, panelShell.opacity(0.985)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(panelWash)
                .overlay(shellGlow.opacity(0.72))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        )
        .overlay(alignment: .top) {
            if viewModel.isPanelPinned {
                LinearGradient(
                    colors: [Color.accentColor.opacity(0.65), Color.accentColor.opacity(0.25)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(height: 2)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: viewModel.isPanelPinned)
        .overlay(alignment: .bottomTrailing) {
            if viewModel.isShowingActions {
                ActionPalette(
                    isPresented: Binding(
                        get: { viewModel.isShowingActions },
                        set: { presented in
                            if presented {
                                viewModel.showActionsPalette()
                            } else {
                                viewModel.hideActionsPalette(restoreFocus: true)
                            }
                        }
                    ),
                    query: viewModel.actionQuery,
                    actions: viewModel.filteredPaletteActions,
                    selectedIndex: $viewModel.selectedActionIndex,
                    onSelect: { index in
                        viewModel.executePaletteAction(at: index)
                    }
                )
                .transition(
                    .asymmetric(
                        insertion: .scale(scale: 0.98, anchor: .bottomTrailing).combined(with: .opacity),
                        removal: .opacity
                    )
                )
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.16), radius: 48, y: 24)
        .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
        .onAppear {
            viewModel.loadItems()
        }
    }

    private var headerBar: some View {
        SearchBar(
            query: $viewModel.searchQuery,
            typeFilter: $viewModel.typeFilter,
            onNavigate: { delta in
                if delta > 0 { viewModel.selectNext() }
                else { viewModel.selectPrev() }
            },
            onSubmit: { viewModel.pasteSelected() },
            onEscape: {
                if !viewModel.clearActiveQueryAndFilters() {
                    viewModel.close()
                }
            },
            onCycleTypeFilter: { reverse in
                viewModel.cycleTypeFilter(reverse: reverse)
            }
        )
        .padding(.horizontal, 2)
        .padding(.top, 6)
    }

    private var contentArea: some View {
        HStack(spacing: 14) {
            itemList
                .frame(width: 292)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(sidebarSurface)
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.05), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.1), radius: 20, y: 10)
                )

            PreviewPane(item: viewModel.selectedItem, searchQuery: viewModel.searchQuery)
                .environmentObject(viewModel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(detailSurface)
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.05), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.12), radius: 24, y: 12)
                )
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var itemList: some View {
        ItemListView(
            sections: viewModel.sections,
            isEmpty: viewModel.isEmpty,
            hasActiveFilter: viewModel.hasActiveFilter,
            searchQuery: viewModel.searchQuery,
            selection: Binding(
                get: { viewModel.selectedItemID },
                set: { viewModel.selectItem(id: $0) }
            ),
            onActivate: { item in
                viewModel.selectItem(id: item.id)
                viewModel.pasteSelected()
            },
            onPin: { viewModel.togglePin(id: $0.id) },
            onDelete: { viewModel.deleteItem(id: $0.id) }
        )
    }

    private var bottomBar: some View {
        HStack(spacing: 0) {
            if viewModel.selectedListItem != nil {
                Button { viewModel.pasteSelected() } label: {
                    keyBadge(
                        label: viewModel.targetAppName.map { "Paste to \($0)" } ?? "Paste",
                        key: "↵",
                        primary: true
                    )
                }
                .buttonStyle(.plain)

                keyBadge(label: "Plain Text", key: "⇧↵")
                    .padding(.leading, 10)

                keyBadge(
                    label: viewModel.selectedQuickPasteLabel,
                    key: viewModel.selectedQuickPasteKey
                )
                .padding(.leading, 10)

                if viewModel.canQuickLookSelectedItem {
                    keyBadge(label: "Quick Look", key: viewModel.selectedQuickLookKey)
                        .padding(.leading, 10)
                }

                Spacer()

                Button { viewModel.toggleActionsPalette() } label: {
                    keyBadge(label: "Actions", key: "⌘K")
                }
                .buttonStyle(.plain)
            } else {
                Text("Clipboard History")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            Button { viewModel.togglePanelPin() } label: {
                keyBadge(
                    label: viewModel.isPanelPinned ? "Pinned" : "Stay",
                    key: "⌘⇧L",
                    primary: viewModel.isPanelPinned
                )
            }
            .buttonStyle(.plain)
            .padding(.leading, 10)

            Button { onOpenSettings() } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .padding(.leading, 8)
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 12)
        .background(
            Color(nsColor: .windowBackgroundColor).opacity(0.4)
                .overlay(Rectangle().frame(height: 0.5).foregroundColor(Color.primary.opacity(0.05)), alignment: .top)
        )
    }

    private func keyBadge(label: String, key: String, primary: Bool = false) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(primary ? Color.white : Color.secondary)
            Text(key)
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .foregroundStyle(primary ? Color.white.opacity(0.82) : Color(nsColor: .tertiaryLabelColor))
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(primary ? Color.white.opacity(0.14) : Color.primary.opacity(0.06))
                )
        }
        .padding(.horizontal, primary ? 12 : 0)
        .padding(.vertical, primary ? 7 : 0)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(primary ? Color.accentColor.opacity(0.94) : Color.clear)
        )
        .shadow(color: primary ? Color.accentColor.opacity(0.16) : .clear, radius: 12, y: 4)
    }
}

private struct ItemListView: View {
    let sections: [ClipSection]
    let isEmpty: Bool
    let hasActiveFilter: Bool
    let searchQuery: String
    let selection: Binding<String?>
    let onActivate: (ClipListItem) -> Void
    let onPin: (ClipListItem) -> Void
    let onDelete: (ClipListItem) -> Void

    @State private var hoveredID: String?

    /// 预计算 id -> 序号索引，O(n) 构建，O(1) 查找
    private var shortcutIndex: [String: Int] {
        var map: [String: Int] = [:]
        var i = 0
        for section in sections {
            for item in section.items {
                if i < 9 { map[item.id] = i + 1 }
                i += 1
            }
        }
        return map
    }

    var body: some View {
        if isEmpty {
            emptyState
        } else {
            listContent
        }
    }

    private var listContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(sections) { section in
                        sectionHeader(section.title)
                        ForEach(section.items, id: \.id) { item in
                            row(for: item)
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            .onChange(of: selection.wrappedValue) { _, newID in
                guard let newID else { return }
                withAnimation(.easeInOut(duration: 0.12)) {
                    proxy.scrollTo(newID, anchor: .center)
                }
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .tracking(0.35)
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(for item: ClipListItem) -> some View {
        let number = shortcutIndex[item.id]
        let isSelected = selection.wrappedValue == item.id
        let isHovered = hoveredID == item.id

        return ClipItemRow(
            item: item,
            shortcutNumber: number,
            searchQuery: searchQuery,
            isSelected: isSelected,
            isHovered: isHovered
        )
        .id(item.id)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    isSelected
                        ? Color.accentColor.opacity(0.12)
                        : isHovered
                            ? Color.primary.opacity(0.06)
                            : Color.clear
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(
                            isSelected ? Color.accentColor.opacity(0.15) : Color.clear,
                            lineWidth: 0.5
                        )
                )
                .padding(.horizontal, 8)
        )
        .animation(.easeOut(duration: 0.1), value: isSelected)
        .animation(.easeOut(duration: 0.08), value: isHovered)
            .contentShape(Rectangle())
            .onTapGesture { selection.wrappedValue = item.id }
            .onHover { hovered in hoveredID = hovered ? item.id : nil }
            .contextMenu {
                Button("Paste") { onActivate(item) }
                Button(item.isPinned ? "Unpin" : "Pin") { onPin(item) }
                Divider()
                Button("Delete", role: .destructive) { onDelete(item) }
            }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: hasActiveFilter ? "magnifyingglass" : "clipboard")
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)

            Text(hasActiveFilter ? "No results" : "No history yet")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)

            Text(hasActiveFilter
                 ? "Try a different search term or filter."
                 : "Copy something and it will appear here.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 200)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
