import SwiftUI

/// 主面板 - 更贴近 macOS 26 的 frosted glass 双栏布局
struct MainPanel: View {
    @ObservedObject var viewModel: ClipboardViewModel
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.colorScheme) private var colorScheme
    /// footer hover 展开辅助命令（Plain Text / Open / Preview），鼠标移开自动收起，
    /// 让平时视觉只剩 CTA + ⌘K 两个核心；键盘用户仍然走全局快捷键，不依赖此 hover 状态。
    @State private var isFooterHovered = false

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
            isFiltered: viewModel.isBrowsingFiltered,
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
        .overlay(alignment: .bottom) {
            if let notice = viewModel.launcherNotice {
                launcherNoticeBanner(notice)
                    .padding(.bottom, ClipinChrome.footerMinHeight + ClipinChrome.shellGap * 3)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(ClipinMotion.panel, value: viewModel.isContinuousPasteEnabled)
        .animation(ClipinMotion.commandReveal, value: viewModel.launcherNotice?.id)
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
            browseMode: $viewModel.browseMode,
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
            onCycleBrowseMode: { reverse in
                viewModel.cycleBrowseMode(reverse: reverse)
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
            hasMore: viewModel.hasMore,
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
            onDelete: { viewModel.deleteItem(id: $0.id) },
            onClearFilters: { _ = viewModel.clearActiveQueryAndFilters() },
            onLoadMore: { viewModel.loadMoreItems() }
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

                // hover 展开的辅助命令簇。平时不占视觉重量，鼠标到 footer 时浮现，
                // 离开 footer 自动收起；键盘用户走全局快捷键不依赖此入口。
                if isFooterHovered {
                    commandCluster {
                        // HTML / RTF pill —— 仅当选中条目存在对应 UTI 时出现，
                        // 鼠标点击等同于 ⌘K 动作面板中的 Paste as HTML / RTF。
                        if viewModel.selectedRepresentationUTIs.contains("public.html") {
                            Button { viewModel.pasteRepresentationSelected(uti: "public.html") } label: {
                                keyBadge(label: "HTML", key: "⌥H")
                            }
                            .buttonStyle(.plain)
                            .help(NSLocalizedString("Paste as HTML", comment: ""))
                        }

                        if viewModel.selectedRepresentationUTIs.contains("public.rtf") {
                            Button { viewModel.pasteRepresentationSelected(uti: "public.rtf") } label: {
                                keyBadge(label: "RTF", key: "⌥R")
                            }
                            .buttonStyle(.plain)
                            .help(NSLocalizedString("Paste as RTF", comment: ""))
                        }

                        Button { viewModel.pastePlainSelected() } label: {
                            keyBadge(label: "Plain Text", key: "⇧↵")
                        }
                        .buttonStyle(.plain)
                        .help(NSLocalizedString("Paste as Plain Text", comment: ""))

                        if viewModel.canOpenSelectedItem {
                            Button { viewModel.openSelected() } label: {
                                keyBadge(label: viewModel.selectedOpenLabel, key: "⌘O")
                            }
                            .buttonStyle(.plain)
                            .help(viewModel.selectedOpenLabel)
                        }

                        if viewModel.canPreviewSelectedItem {
                            Button { _ = viewModel.previewSelected() } label: {
                                keyBadge(label: viewModel.isPreparingPreview ? "Preparing…" : "Preview", key: "Space")
                            }
                            .buttonStyle(.plain)
                            .help(NSLocalizedString("Preview", comment: ""))
                        }
                    }
                    .padding(.leading, 8)
                    .transition(.opacity.combined(with: .move(edge: .leading)))
                }

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

            if viewModel.isContinuousPasteEnabled {
                continuousPastePill
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }

            // footer 只保留 ⌘K Actions 作为常驻全局入口。
            // 设置入口、Continuous Paste 开关、Plain Text/Open/Preview 已经在 ⌘K 面板内可触达，
            // 不再在 footer 里重复展示，避免命令条信息过载。
            commandCluster {
                Button { viewModel.toggleActionsPalette() } label: {
                    keyBadge(label: "Actions", key: "⌘K")
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, 10)
        }
        .padding(.horizontal, ClipinChrome.footerContentInset)
        .padding(.vertical, ClipinChrome.footerContentInset)
        .frame(minHeight: ClipinChrome.footerMinHeight)
        .onHover { hovering in
            withAnimation(ClipinMotion.commandReveal) {
                isFooterHovered = hovering
            }
        }
        .animation(ClipinMotion.commandReveal, value: isFooterHovered)
        .background(
            ClipinSurfaceBackground(
                role: .strip,
                cornerRadius: ClipinChrome.sectionCornerRadius,
                glass: glass
            )
        )
        .scaleEffect(sceneState.stripScale)
        .padding(.horizontal, ClipinChrome.shellGap)
        .padding(.top, ClipinChrome.shellGap)
        .padding(.bottom, ClipinChrome.shellGap)
        .animation(ClipinMotion.focusShift, value: sceneState)
    }

    private var continuousPastePill: some View {
        Button { viewModel.toggleContinuousPaste() } label: {
            HStack(spacing: 7) {
                Image(systemName: "repeat.circle.fill")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(glass.emphasisInk)

                Text("Continuous Paste")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(glass.emphasisInk)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                ClipinKeycap(
                    key: "Esc",
                    foreground: glass.emphasisInk.opacity(0.82),
                    background: glass.controlFill
                )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: ClipinChrome.badgeCornerRadius, style: .continuous)
                    .fill(hierarchy.selection.fill)
                    .overlay(
                        RoundedRectangle(cornerRadius: ClipinChrome.badgeCornerRadius, style: .continuous)
                            .strokeBorder(hierarchy.selection.stroke, lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(.plain)
        .help(NSLocalizedString("Press Esc to exit Continuous Paste.", comment: ""))
        .accessibilityLabel(Text("Continuous Paste"))
        .accessibilityHint(Text("Press Esc to exit Continuous Paste."))
    }

    private func commandCluster<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            content()
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            ClipinSurfaceBackground(
                role: .grouped,
                cornerRadius: ClipinChrome.badgeCornerRadius + 2,
                glass: glass
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
                shadowColor: .black.opacity(colorScheme == .dark ? 0.14 : 0.04),
                shadowRadius: colorScheme == .dark ? 8 : 5,
                shadowYOffset: colorScheme == .dark ? 3 : 2
            )
        )
    }

    private func keyBadge(label: String, key: String, emphasized: Bool = false) -> some View {
        HStack(spacing: 5) {
            Text(LocalizedStringKey(label))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(emphasized ? glass.emphasisInk : hierarchy.support.subduedInk)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
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

    private func launcherNoticeBanner(_ notice: LauncherNotice) -> some View {
        HStack(spacing: 9) {
            Image(systemName: noticeIcon(for: notice.style))
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(noticeTint(for: notice.style))

            Text(notice.text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hierarchy.support.subduedInk)
                .lineLimit(2)

            if let actionTitle = notice.actionTitle {
                Button(actionTitle) {
                    viewModel.performNoticeAction()
                }
                .font(.system(size: 11.5, weight: .semibold))
                .buttonStyle(.borderless)
            }

            Button {
                viewModel.dismissNotice()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(hierarchy.support.smallLabelInk)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.borderless)
            .help(NSLocalizedString("Dismiss", comment: ""))
            .accessibilityLabel(Text("Dismiss"))
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 9)
        .frame(maxWidth: 430)
        .background(
            ClipinSurfaceBackground(
                role: .floating,
                cornerRadius: ClipinChrome.searchCornerRadius,
                glass: glass
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: ClipinChrome.searchCornerRadius, style: .continuous)
                .strokeBorder(noticeTint(for: notice.style).opacity(0.22), lineWidth: 0.6)
        )
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.22 : 0.10), radius: 14, y: 6)
    }

    private func noticeIcon(for style: LauncherNoticeStyle) -> String {
        switch style {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    private func noticeTint(for style: LauncherNoticeStyle) -> Color {
        switch style {
        case .info: return glass.emphasisInk
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
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
    /// ViewModel 预计算的 ⌘1-9 序列（按当前可见列表；搜索结果可包含 pinned 项）
    let shortcutOrder: [ClipListItem]
    let isEmpty: Bool
    let hasActiveFilter: Bool
    let hasMore: Bool
    let searchQuery: String
    let sceneState: ClipinSceneState
    let selection: Binding<String?>
    let onActivate: (ClipListItem) -> Void
    let onPin: (ClipListItem) -> Void
    let onDelete: (ClipListItem) -> Void
    let onClearFilters: () -> Void
    let onLoadMore: () -> Void

    @State private var hoveredID: String?

    private var glass: ClipinGlassPalette {
        .make(theme: settings.visualTheme, colorScheme: colorScheme)
    }

    private var hierarchy: ClipinPanelHierarchy {
        .make(glass: glass, colorScheme: colorScheme)
    }

    /// 预计算 id -> ⌘N 序号，直接从 ViewModel 的 shortcutOrder 构建
    /// ⌘1-9 始终映射当前可见列表中的前 9 项
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
                    // 滚到底时触发加载下一页；hasMore=false 时不渲染，避免重复触发
                    if hasMore {
                        Color.clear.frame(height: 1)
                            .onAppear { onLoadMore() }
                    }
                }
                .padding(.vertical, 6)
            }
            .onChange(of: selection.wrappedValue) { _, newID in
                hoveredID = nil
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
                hoverStroke: glass.hoverStroke,
                showsSelectionAccent: true,
                isPinned: item.isPinned
            )
        )
        .padding(.horizontal, ClipinChrome.listRowOuterInset)
        .scaleEffect(isSelected ? sceneState.selectedRowScale : 1.0)
        .offset(y: isSelected ? sceneState.selectedRowLift : 0)
        .opacity(!isSelected ? sceneState.listRestingOpacity : 1.0)
        .animation(ClipinMotion.selection, value: isSelected)
        .animation(ClipinMotion.feedback, value: isHovered)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onActivate(item) }
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

            if hasActiveFilter {
                Button("Clear Search & Filters") {
                    onClearFilters()
                }
                .font(.system(size: 11.5, weight: .medium))
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.top, 4)
            }
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
