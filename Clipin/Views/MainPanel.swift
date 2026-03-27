import SwiftUI

/// 主面板 - 更贴近 macOS 26 的 frosted glass 双栏布局
struct MainPanel: View {
    @ObservedObject var viewModel: ClipboardViewModel
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.colorScheme) private var colorScheme

    private var glass: ClipinGlassPalette {
        .make(theme: settings.visualTheme, colorScheme: colorScheme)
    }

    private var hierarchy: ClipinPanelHierarchy {
        .make(glass: glass, colorScheme: colorScheme)
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            contentArea
            bottomBar
        }
        .frame(width: 800, height: 540)
        .background(
            RoundedRectangle(cornerRadius: ClipinChrome.shellCornerRadius, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    LinearGradient(
                        colors: [glass.shellTintTop, glass.shellTintBottom],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    LinearGradient(
                        colors: [glass.shellWash, Color.clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    LinearGradient(
                        colors: [glass.shellHighlight, Color.clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: ClipinChrome.shellCornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.24), lineWidth: 0.5)
                )
        )
        .overlay(alignment: .top) {
            if viewModel.isContinuousPasteEnabled {
                LinearGradient(
                    colors: [glass.emphasisStrongFill, glass.emphasisFill],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(height: 2)
                .transition(.opacity)
            }
        }
        .animation(ClipinMotion.panel, value: viewModel.isContinuousPasteEnabled)
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
                    actions: viewModel.paletteActions,
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
        .clipShape(RoundedRectangle(cornerRadius: ClipinChrome.shellCornerRadius, style: .continuous))
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
        .padding(.horizontal, ClipinChrome.shellSectionInset)
        .padding(.top, ClipinChrome.headerTopInset)
        .padding(.bottom, ClipinChrome.headerBottomInset)
    }

    private var contentArea: some View {
        HStack(spacing: ClipinChrome.shellSectionGap) {
            itemList
                .frame(width: 292)
                .background(
                    ClipinSurfaceBackground(
                        role: .sidebar,
                        cornerRadius: ClipinChrome.sectionCornerRadius,
                        glass: glass
                    )
                )

            PreviewPane(item: viewModel.selectedItem, searchQuery: viewModel.searchQuery)
                .environmentObject(viewModel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, ClipinChrome.shellSectionInset)
        .padding(.top, ClipinChrome.contentTopInset)
        .padding(.bottom, ClipinChrome.contentBottomInset)
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
                    pasteCallToAction(
                        label: viewModel.targetAppName.map { String(format: NSLocalizedString("Paste to %@", comment: ""), $0) } ?? NSLocalizedString("Paste", comment: ""),
                        key: "↵"
                    )
                }
                .buttonStyle(PrimaryFooterButtonStyle())

                keyBadge(label: "Plain Text", key: "⇧↵")
                    .padding(.leading, 10)

                keyBadge(
                    label: viewModel.selectedQuickPasteLabel,
                    key: viewModel.selectedQuickPasteKey
                )
                .padding(.leading, 10)

                if viewModel.canOpenSelectedItem {
                    keyBadge(label: viewModel.selectedOpenLabel, key: "⌘O")
                        .padding(.leading, 10)
                }

                Spacer()
            } else {
                Text("Clipboard History")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                if viewModel.hasActiveFilter {
                    Text("No selection")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 8)
                }

                Spacer()
            }

            Button { viewModel.toggleActionsPalette() } label: {
                keyBadge(label: "Actions", key: "⌘K")
            }
            .buttonStyle(.plain)

            Button { viewModel.toggleContinuousPaste() } label: {
                keyBadge(
                    label: "Continuous Paste",
                    key: "⌘⇧L",
                    emphasized: viewModel.isContinuousPasteEnabled
                )
            }
            .buttonStyle(.plain)
            .padding(.leading, 10)

            Button { viewModel.openSettings() } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .padding(.leading, 8)
        }
        .padding(.horizontal, ClipinChrome.footerContentInset)
        .padding(.vertical, ClipinChrome.footerContentInset)
        .frame(minHeight: ClipinChrome.footerMinHeight)
        .background(
            ClipinSurfaceBackground(
                role: .strip,
                cornerRadius: ClipinChrome.sectionCornerRadius,
                glass: glass
            )
        )
        .padding(.horizontal, ClipinChrome.shellSectionInset)
        .padding(.top, ClipinChrome.footerOuterTopInset)
        .padding(.bottom, ClipinChrome.footerOuterBottomInset)
    }

    private func pasteCallToAction(label: String, key: String) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(hierarchy.command.iconFill)
                Image(systemName: "arrow.up.forward.app.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(hierarchy.command.iconInk)
            }
            .frame(width: ClipinChrome.footerCalloutIconSize, height: ClipinChrome.footerCalloutIconSize)

            Text(label)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(hierarchy.command.ink)
                .lineLimit(1)
                .truncationMode(.tail)

            ClipinKeycap(
                key: key,
                foreground: hierarchy.command.ink.opacity(0.76),
                background: hierarchy.command.keycapFill
            )
        }
        .padding(.leading, ClipinChrome.footerCalloutHorizontalLeading)
        .padding(.trailing, ClipinChrome.footerCalloutHorizontalTrailing)
        .padding(.vertical, ClipinChrome.footerCalloutVerticalInset)
        .background(
            ClipinRoundedSurface(
                cornerRadius: ClipinChrome.primaryBadgeCornerRadius,
                material: .ultraThinMaterial,
                tint: hierarchy.command.fill,
                stroke: hierarchy.command.stroke,
                highlight: glass.shellHighlight.opacity(colorScheme == .dark ? 0.18 : 0.34),
                shadowColor: .black.opacity(colorScheme == .dark ? 0.14 : 0.05),
                shadowRadius: 8,
                shadowYOffset: 3
            )
        )
    }

    private func keyBadge(label: String, key: String, emphasized: Bool = false) -> some View {
        HStack(spacing: 5) {
            Text(LocalizedStringKey(label))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(emphasized ? glass.emphasisInk : Color.secondary)
            ClipinKeycap(
                key: key,
                foreground: emphasized ? glass.emphasisInk.opacity(0.82) : Color(nsColor: .tertiaryLabelColor),
                background: emphasized ? glass.controlFill : glass.keycapTint
            )
        }
        .padding(.horizontal, emphasized ? 10 : 0)
        .padding(.vertical, emphasized ? 6 : 0)
        .background(
            RoundedRectangle(cornerRadius: ClipinChrome.badgeCornerRadius, style: .continuous)
                .fill(emphasized ? hierarchy.selection.fill : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: ClipinChrome.badgeCornerRadius, style: .continuous)
                        .strokeBorder(emphasized ? hierarchy.selection.stroke : Color.clear, lineWidth: 0.5)
                )
        )
    }
}

private struct PrimaryFooterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .brightness(configuration.isPressed ? -0.02 : 0)
            .animation(ClipinMotion.feedback, value: configuration.isPressed)
    }
}

private struct ItemListView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.colorScheme) private var colorScheme
    let sections: [ClipSection]
    let isEmpty: Bool
    let hasActiveFilter: Bool
    let searchQuery: String
    let selection: Binding<String?>
    let onActivate: (ClipListItem) -> Void
    let onPin: (ClipListItem) -> Void
    let onDelete: (ClipListItem) -> Void

    @State private var hoveredID: String?

    private var glass: ClipinGlassPalette {
        .make(theme: settings.visualTheme, colorScheme: colorScheme)
    }

    private var hierarchy: ClipinPanelHierarchy {
        .make(glass: glass, colorScheme: colorScheme)
    }

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
                withAnimation(ClipinMotion.selection) {
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
            .padding(.horizontal, ClipinChrome.listRowOuterInset)
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
            isHovered: isHovered,
            hierarchy: hierarchy
        )
        .padding(.vertical, 2)
        .id(item.id)
        .background(
            ClipinSelectableRowBackground(
                isSelected: isSelected,
                isHovered: isHovered,
                selectionFill: hierarchy.selection.fill,
                selectionStroke: hierarchy.selection.stroke,
                hoverFill: glass.hoverFill,
                hoverStroke: glass.hoverStroke
            )
        )
        .padding(.horizontal, ClipinChrome.listRowOuterInset)
        .animation(ClipinMotion.selection, value: isSelected)
        .animation(ClipinMotion.feedback, value: isHovered)
        .contentShape(Rectangle())
        .onTapGesture { selection.wrappedValue = item.id }
        .onHover { hovered in hoveredID = hovered ? item.id : nil }
        .contextMenu {
            Button("Paste") { onActivate(item) }
            Button(item.isPinned ? LocalizedStringKey("Unpin") : LocalizedStringKey("Pin")) { onPin(item) }
            Divider()
            Button("Delete", role: .destructive) { onDelete(item) }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: hasActiveFilter ? "magnifyingglass" : "clipboard")
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)

            Text(hasActiveFilter ? LocalizedStringKey("No results") : LocalizedStringKey("No history yet"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)

            Text(hasActiveFilter
                 ? LocalizedStringKey("Try a different search term, or press Command-K for actions.")
                 : LocalizedStringKey("Copy something and it will appear here. Command-K still opens actions."))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 200)

            HStack(spacing: 6) {
                badgeCapsule("⌘K")
                Text(hasActiveFilter ? LocalizedStringKey("Actions") : LocalizedStringKey("Actions & Settings"))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func badgeCapsule(_ key: String) -> some View {
        ClipinKeycap(
            key: key,
            foreground: Color(nsColor: .secondaryLabelColor),
            background: glass.keycapTint
        )
    }
}
