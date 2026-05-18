import SwiftUI
import AppKit

/// 主面板 - 更贴近 macOS 26 的 frosted glass 双栏布局
struct MainPanel: View {
    @ObservedObject var viewModel: ClipboardViewModel
    /// footer hover 展开辅助命令（HTML/RTF/Plain Text/Open/Preview），鼠标移开自动收起。
    /// 底栏恒为：左 sourceBreadcrumb（选中显来源 app，无选中回退 Clipboard History）/
    /// 右 Paste CTA(仅选中) + Continuous Paste pill(连续粘贴时) + Actions ⌘K。
    /// 键盘用户走全局快捷键，不依赖此 hover 状态。
    @State private var isFooterHovered = false

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
        // 内容层不自带玻璃。窗面是 macOS 26 原生 Liquid Glass(Spotlight 那种),
        // 由 AppDelegate 主 panel 创建处的 NSGlassEffectView(glassSurface)承担,
        // 内容浮其上。SwiftUI 不再加任何背景。仍按 shell 圆角裁剪,保证全宽 top
        // 渐变/notice/ActionPalette overlay 不冲出圆角窗形。
        panelContent
            .clipShape(
                RoundedRectangle(cornerRadius: ClipinChrome.shellCornerRadius, style: .continuous)
            )
    }

    private var panelContent: some View {
        VStack(spacing: 0) {
            headerBar
            contentArea
        }
        .frame(width: 800, height: 540)
        .overlay(alignment: .top) {
            if viewModel.isContinuousPasteEnabled {
                LinearGradient(
                    colors: [Color.accentColor, Color.accentColor.opacity(0.4)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(height: 2)
                .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) {
            bottomBar
        }
        .overlay(alignment: .bottom) {
            if let notice = viewModel.launcherNotice {
                launcherNoticeBanner(notice)
                    .padding(.bottom, ClipinChrome.floatingFooterBand + ClipinChrome.shellGap)
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
        // macOS 26 原生半透明 Liquid Glass 命令条:悬浮在内容上(内容从玻璃后淡淡透出,
        // 即用户说的 iOS26 感)。命令按钮全用原生 .buttonStyle(.glass)——半透明胶囊 +
        // 自带原生 hover/press 交互,装进 GlassEffectContainer 统一融合采样(glass 不能
        // 采样 glass)。不再自绘扁平/不透明 prominent。
        GlassEffectContainer {
        HStack(spacing: 8) {
            // 底栏恒为左对齐的来源面包屑：选中时显条目来源 app，无选中回退 Clipboard History。
            sourceBreadcrumb

            if viewModel.hasActiveFilter && viewModel.selectedListItem == nil {
                Text("No selection")
                    .font(.system(size: 11))
                    .foregroundStyle(ClipinInk.tertiary)
                    .padding(.leading, 8)
            }

            Spacer()

            if viewModel.selectedListItem != nil {
                // hover 展开的辅助命令簇。平时不占视觉重量，鼠标到 footer 时浮现，
                // 离开 footer 自动收起；键盘用户走全局快捷键不依赖此入口。
                // 位于 Spacer 右侧、Paste CTA 左邻；从 Spacer 侧（.leading）滑入滑出，避免与 CTA 对穿。
                if isFooterHovered {
                    commandCluster {
                        // HTML / RTF pill —— 仅当选中条目存在对应 UTI 时出现，
                        // 鼠标点击等同于 ⌘K 动作面板中的 Paste as HTML / RTF。
                        if viewModel.selectedRepresentationUTIs.contains("public.html") {
                            Button { viewModel.pasteRepresentationSelected(uti: "public.html") } label: {
                                keyBadge(label: "HTML", key: "⌥H")
                            }
                            .buttonStyle(.glass)
                            .help(NSLocalizedString("Paste as HTML", comment: ""))
                        }

                        if viewModel.selectedRepresentationUTIs.contains("public.rtf") {
                            Button { viewModel.pasteRepresentationSelected(uti: "public.rtf") } label: {
                                keyBadge(label: "RTF", key: "⌥R")
                            }
                            .buttonStyle(.glass)
                            .help(NSLocalizedString("Paste as RTF", comment: ""))
                        }

                        Button { viewModel.pastePlainSelected() } label: {
                            keyBadge(label: "Plain Text", key: "⇧↵")
                        }
                        .buttonStyle(.glass)
                        .help(NSLocalizedString("Paste as Plain Text", comment: ""))

                        if viewModel.canOpenSelectedItem {
                            Button { viewModel.openSelected() } label: {
                                keyBadge(label: viewModel.selectedOpenLabel, key: "⌘O")
                            }
                            .buttonStyle(.glass)
                            .help(viewModel.selectedOpenLabel)
                        }

                        if viewModel.canPreviewSelectedItem {
                            Button { _ = viewModel.previewSelected() } label: {
                                keyBadge(label: viewModel.isPreparingPreview ? "Preparing…" : "Preview", key: "Space")
                            }
                            .buttonStyle(.glass)
                            .help(NSLocalizedString("Preview", comment: ""))
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .leading)))
                }

                Button { viewModel.pasteSelected() } label: {
                    pasteCallToAction(
                        label: viewModel.targetAppName.map { String(format: NSLocalizedString("Paste to %@", comment: ""), $0) } ?? NSLocalizedString("Paste", comment: ""),
                        key: "↵"
                    )
                }
                .buttonStyle(.glass)
            }

            if viewModel.isContinuousPasteEnabled {
                continuousPastePill
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }

            // footer 右侧常驻命令簇只保留 ⌘K Actions 作为全局入口。
            // 设置入口、Continuous Paste 开关、Plain Text/Open/Preview 已经在 ⌘K 面板内可触达，
            // 不再在 footer 里重复展示，避免命令条信息过载。
            commandCluster {
                Button { viewModel.toggleActionsPalette() } label: {
                    keyBadge(label: "Actions", key: "⌘K")
                }
                .buttonStyle(.glass)
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
        .scaleEffect(sceneState.stripScale)
        .padding(.horizontal, ClipinChrome.shellGap * 2)
        .padding(.bottom, ClipinChrome.shellGap)
        .animation(ClipinMotion.focusShift, value: sceneState)
        }
    }

    /// 来源 app 图标:按 bundle id 解析(镜像 PreviewPane.sourceAppIcon,来源 app 未运行也可用)
    private func sourceAppIcon(bundleId: String?) -> NSImage? {
        guard let bundleId,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private var sourceBreadcrumb: some View {
        HStack(spacing: 7) {
            if let item = viewModel.selectedListItem {
                if let name = item.sourceName {
                    if let icon = sourceAppIcon(bundleId: item.sourceApp) {
                        Image(nsImage: icon).resizable().frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(ClipinInk.secondary)
                    }
                    Text(name)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(ClipinInk.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(ClipinInk.secondary)
                    Text(NSLocalizedString("Unknown Source", comment: ""))
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(ClipinInk.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            } else {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ClipinInk.secondary)
                Text("Clipboard History")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(ClipinInk.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: Capsule(style: .continuous))
        .frame(maxWidth: 220, alignment: .leading)
    }

    private var continuousPastePill: some View {
        Button { viewModel.toggleContinuousPaste() } label: {
            HStack(spacing: 7) {
                Image(systemName: "repeat.circle.fill")
                    .font(.system(size: 12.5, weight: .semibold))

                Text("Continuous Paste")
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                ClipinKeycap(
                    key: "Esc",
                    foreground: ClipinInk.secondary
                )
            }
        }
        .buttonStyle(.glass)
        .help(NSLocalizedString("Press Esc to exit Continuous Paste.", comment: ""))
        .accessibilityLabel(Text("Continuous Paste"))
        .accessibilityHint(Text("Press Esc to exit Continuous Paste."))
    }

    private func commandCluster<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        // Raycast 式扁平命令组:仅排布,不再套玻璃胶囊。
        HStack(spacing: 8) {
            content()
        }
    }

    private func pasteCallToAction(label: String, key: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12.5, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)

            ClipinKeycap(
                key: key,
                foreground: ClipinInk.secondary
            )
        }
    }

    private func keyBadge(label: String, key: String) -> some View {
        HStack(spacing: 5) {
            Text(LocalizedStringKey(label))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(ClipinInk.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            ClipinKeycap(key: key, foreground: ClipinInk.secondary)
        }
    }

    private func launcherNoticeBanner(_ notice: LauncherNotice) -> some View {
        HStack(spacing: 9) {
            Image(systemName: noticeIcon(for: notice.style))
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(noticeTint(for: notice.style))

            Text(notice.text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(ClipinInk.secondary)
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
                    .foregroundStyle(ClipinInk.secondary)
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
        .clipinChromeGlass(cornerRadius: ClipinChrome.searchCornerRadius)
        .overlay(
            RoundedRectangle(cornerRadius: ClipinChrome.searchCornerRadius, style: .continuous)
                .strokeBorder(noticeTint(for: notice.style).opacity(0.22), lineWidth: 0.6)
        )
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
        case .info: return Color.accentColor
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }
}

private struct ItemListView: View {
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
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: ClipinChrome.floatingFooterBand)
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
            .foregroundStyle(ClipinInk.secondary)
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
            sceneState: sceneState
        )
        .padding(.vertical, 2)
        .id(item.id)
        .background(
            ClipinSelectableRowBackground(
                isSelected: isSelected,
                isHovered: isHovered,
                selectionFill: ClipinSelectionInk.fill,
                selectionStroke: ClipinSelectionInk.stroke,
                hoverFill: ClipinHoverInk.fill,
                hoverStroke: ClipinHoverInk.stroke,
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
                .foregroundStyle(ClipinInk.tertiary)

            Text(hasActiveFilter ? LocalizedStringKey("No results") : LocalizedStringKey("No history yet"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(ClipinInk.secondary)

            Text(hasActiveFilter
                 ? LocalizedStringKey("Try a different search term, or press Command-K for actions.")
                 : LocalizedStringKey("Copy something and it will appear here. Command-K still opens actions."))
                .font(.system(size: 11))
                .foregroundStyle(ClipinInk.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 200)

            HStack(spacing: 6) {
                badgeCapsule("⌘K")
                Text(hasActiveFilter ? LocalizedStringKey("Actions") : LocalizedStringKey("Actions & Settings"))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(ClipinInk.secondary)
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
            foreground: ClipinInk.secondary
        )
    }
}
