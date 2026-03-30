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

    private var sceneState: ClipinSceneState {
        ClipinSceneState(
            hasSelection: viewModel.selectedListItem != nil,
            isSearching: !viewModel.searchQuery.isEmpty,
            isFiltered: viewModel.typeFilter != nil || viewModel.isPinnedView,
            isShowingActions: viewModel.isShowingActions,
            isContinuousPasteEnabled: viewModel.isContinuousPasteEnabled
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            contentArea
            bottomBar
        }
        .frame(width: 800, height: 540)
        .background(ClipinShellBackground(glass: glass, sceneState: sceneState))
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
                    sceneState: sceneState,
                    onSelect: { index in
                        viewModel.executePaletteAction(at: index)
                    }
                )
                .transition(
                    .asymmetric(
                        insertion: .scale(scale: 0.985, anchor: .bottomTrailing).combined(with: .opacity),
                        removal: .opacity
                    )
                )
            }
        }
        .animation(ClipinMotion.commandReveal, value: sceneState.isShowingActions)
        .onAppear { viewModel.loadItems() }
    }

    private var headerBar: some View {
        SearchBar(
            query: $viewModel.searchQuery,
            typeFilter: $viewModel.typeFilter,
            isPinnedView: $viewModel.isPinnedView,
            sceneState: sceneState,
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
        .padding(.horizontal, ClipinChrome.shellGap)
        .padding(.top, ClipinChrome.shellGap)
        .padding(.bottom, 6)
        .offset(y: sceneState.headerLift)
        .animation(ClipinMotion.focusShift, value: sceneState)
    }

    private var contentArea: some View {
        HStack(spacing: ClipinChrome.shellGap) {
            itemList
                .frame(width: 292)
                .background(
                    ClipinSurfaceBackground(
                        role: .sidebar,
                        cornerRadius: ClipinChrome.sectionCornerRadius,
                        glass: glass
                    )
                )
                .scaleEffect(sceneState.isShowingActions ? 0.998 : 1.0)
                .opacity(sceneState.listRestingOpacity)

            PreviewPane(item: viewModel.selectedItem, searchQuery: viewModel.searchQuery, sceneState: sceneState)
                .environmentObject(viewModel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, ClipinChrome.shellGap)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(ClipinMotion.focusShift, value: sceneState)
    }

    private var itemList: some View {
        ItemListView(
            sections: viewModel.sections,
            shortcutOrder: viewModel.shortcutOrder,
            isEmpty: viewModel.isEmpty,
            hasActiveFilter: viewModel.hasActiveFilter,
            searchQuery: viewModel.searchQuery,
            sceneState: sceneState,
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
        HStack(spacing: 8) {
            if viewModel.selectedListItem != nil {
                Button { viewModel.pasteSelected() } label: {
                    pasteCallToAction(
                        label: viewModel.targetAppName.map { String(format: NSLocalizedString("Paste to %@", comment: ""), $0) } ?? NSLocalizedString("Paste", comment: ""),
                        key: "↵"
                    )
                }
                .buttonStyle(PrimaryFooterButtonStyle())

                commandCluster {
                    keyBadge(label: "Plain Text", key: "⇧↵")

                    keyBadge(
                        label: viewModel.selectedQuickPasteLabel,
                        key: viewModel.selectedQuickPasteKey
                    )

                    if viewModel.canOpenSelectedItem {
                        keyBadge(label: viewModel.selectedOpenLabel, key: "⌘O")
                    }
                }
                .padding(.leading, 8)

                Spacer()
            } else {
                Text("Clipboard History")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(hierarchy.support.subduedInk)

                if viewModel.hasActiveFilter {
                    Text("No selection")
                        .font(.system(size: 11))
                        .foregroundStyle(hierarchy.support.hintInk)
                        .padding(.leading, 8)
                }

                Spacer()
            }

            commandCluster {
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

                Button { viewModel.openSettings() } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12))
                        .foregroundStyle(hierarchy.support.subduedInk)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
            }
            .padding(.leading, 10)
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
        .overlay {
            RoundedRectangle(cornerRadius: ClipinChrome.sectionCornerRadius, style: .continuous)
                .strokeBorder(glass.emphasisStroke.opacity(sceneState.stripAccentOpacity), lineWidth: 0.6)
        }
        .shadow(
            color: glass.emphasisStrongFill.opacity(sceneState.stripAccentOpacity * (colorScheme == .dark ? 0.18 : 0.10)),
            radius: 10,
            y: 3
        )
        .scaleEffect(sceneState.stripScale)
        .padding(.horizontal, ClipinChrome.shellGap)
        .padding(.top, ClipinChrome.shellGap)
        .padding(.bottom, ClipinChrome.shellGap)
        .animation(ClipinMotion.focusShift, value: sceneState)
    }

    private func commandCluster<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            content()
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: ClipinChrome.badgeCornerRadius + 2, style: .continuous)
                .fill(glass.controlFill.opacity(colorScheme == .dark ? 0.64 : 0.48))
                .overlay(
                    RoundedRectangle(cornerRadius: ClipinChrome.badgeCornerRadius + 2, style: .continuous)
                        .strokeBorder(glass.controlStroke.opacity(colorScheme == .dark ? 0.64 : 0.42), lineWidth: 0.5)
                )
        )
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
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(emphasized ? glass.emphasisInk : hierarchy.support.subduedInk)
            ClipinKeycap(
                key: key,
                foreground: emphasized ? glass.emphasisInk.opacity(0.82) : hierarchy.support.smallLabelInk,
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
    /// ViewModel 预计算的 ⌘1-9 序列（普通视图=非 pinned 项，固定视图=pinned 项）
    let shortcutOrder: [ClipListItem]
    let isEmpty: Bool
    let hasActiveFilter: Bool
    let searchQuery: String
    let sceneState: ClipinSceneState
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

    /// 预计算 id -> ⌘N 序号，直接从 ViewModel 的 shortcutOrder 构建
    /// 普通视图：非 pinned 项得到 ⌘1-9；固定视图：pinned 项得到 ⌘1-9
    private var shortcutIndex: [String: Int] {
        Dictionary(
            uniqueKeysWithValues: shortcutOrder.prefix(9).enumerated().map { ($1.id, $0 + 1) }
        )
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
            .foregroundStyle(hierarchy.support.smallLabelInk)
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
            sceneState: sceneState,
            glass: glass,
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
        .scaleEffect(isSelected ? sceneState.selectedRowScale : 1.0)
        .offset(y: isSelected ? sceneState.selectedRowLift : 0)
        .opacity(!isSelected ? sceneState.listRestingOpacity : 1.0)
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
                .foregroundStyle(hierarchy.support.placeholderInk)

            Text(hasActiveFilter ? LocalizedStringKey("No results") : LocalizedStringKey("No history yet"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(hierarchy.support.subduedInk)

            Text(hasActiveFilter
                 ? LocalizedStringKey("Try a different search term, or press Command-K for actions.")
                 : LocalizedStringKey("Copy something and it will appear here. Command-K still opens actions."))
                .font(.system(size: 11))
                .foregroundStyle(hierarchy.support.hintInk)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 200)

            HStack(spacing: 6) {
                badgeCapsule("⌘K")
                Text(hasActiveFilter ? LocalizedStringKey("Actions") : LocalizedStringKey("Actions & Settings"))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(hierarchy.support.subduedInk)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func badgeCapsule(_ key: String) -> some View {
        ClipinKeycap(
            key: key,
            foreground: hierarchy.support.smallLabelInk,
            background: glass.keycapTint
        )
    }
}
