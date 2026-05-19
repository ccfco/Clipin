import SwiftUI
import AppKit

/// 发布 Paste 按钮在面板坐标系的 bounds,供派生簇精确锚定其正上方
/// (替代硬编码偏移——Paste 文案随目标 app 名/本地化变宽,固定偏移会漂移)。
private struct PasteButtonAnchorKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

/// 主面板 - 更贴近 macOS 26 的 frosted glass 双栏布局
struct MainPanel: View {
    @ObservedObject var viewModel: ClipboardViewModel
    /// hover Paste → 其正上方派生次级动作玻璃胶囊簇(Raycast 式)。命中区必须
    /// 连续:Paste 与 pills 各自维护 hover,OR 起来;pills 视图底边贴 Paste 顶边
    /// (视觉 6pt 缝由 pills 内透明 padding 给),鼠标在两者间移动不穿死区。
    /// 键盘用户走全局快捷键,不依赖此 hover 状态。
    @State private var isPasteHovered = false
    @State private var isPillsHovered = false
    /// 派生簇尺寸(用于按 Paste 真实 bounds 精确定位,替代脆弱的硬编码偏移)。
    @State private var derivedPillsSize: CGSize = .zero
    /// 底栏右侧动作簇共享玻璃命名空间:Paste / Actions 用同一 union id 并成
    /// **一条连续玻璃胶囊**(Raycast 参照效果①),每颗仍各自 .interactive() hover(②)。
    @Namespace private var footerGlassNS
    /// QA 视觉自检:仅当显式 env `CLIPIN_QA_SHOW_PILLS=1` 时强制常显派生簇,
    /// 让自截图能确定性核对(合成鼠标对 nonactivating panel 的 .onHover 不可靠)。
    /// 默认无此 env → 零行为变化(显式 opt-in 测试钩子,非兜底)。
    private var showsDerivedPills: Bool {
        isPasteHovered || isPillsHovered
            || ProcessInfo.processInfo.environment["CLIPIN_QA_SHOW_PILLS"] == "1"
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
        // 内容层不自带玻璃。窗面是 macOS 26 原生整窗 Liquid Glass(导航层,
        // Spotlight/Raycast 那种),由 AppDelegate 主 panel 的 NSGlassEffectView
        // 承担,内容靠 vibrancy 直接坐其上、不套盒子。SwiftUI 不加任何背景。
        // 仍按 shell 圆角裁剪,保证全宽 top 渐变/notice/ActionPalette overlay
        // 不冲出圆角窗形。
        panelContent
            .clipShape(
                RoundedRectangle(cornerRadius: ClipinChrome.shellCornerRadius, style: .continuous)
            )
            // iOS 26 同心圆角根:声明一次 shell 容器几何,内部所有 ClipinConcentric()
            // (选中底板等)curvature 自动随此推导。改 shellCornerRadius 一处全联动。
            .containerShape(
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
        // hover Paste → 其正上方派生次级动作玻璃胶囊簇(真机 Raycast 式)。
        // 必须挂 panelContent 顶层而非底栏内部:底栏是 ~44pt 高的
        // GlassEffectContainer,挂里面会被容器裁掉(自截图实证)。用
        // PasteButtonAnchorKey 读 Paste 真实 bounds 精确锚定其正上方,
        // 替代会随文案宽度漂移的硬编码偏移(Codex 复审抓到)。
        .overlayPreferenceValue(PasteButtonAnchorKey.self) { anchor in
            GeometryReader { proxy in
                if showsDerivedPills, viewModel.selectedListItem != nil, let anchor {
                    let pasteRect = proxy[anchor]
                    FooterHoverDerivedPills(pills: hoverPills())
                        .fixedSize()
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { derivedPillsSize = $0 }
                        .onHover { hovering in
                            withAnimation(ClipinMotion.commandReveal) { isPillsHovered = hovering }
                        }
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                        // 右缘对齐 Paste 右缘、底边距 Paste 顶边 6pt(视觉留缝)。
                        .offset(
                            x: pasteRect.maxX - derivedPillsSize.width,
                            y: pasteRect.minY - derivedPillsSize.height - 6
                        )
                }
            }
        }
        .animation(ClipinMotion.commandReveal, value: showsDerivedPills)
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
        // macOS 26 标准做法(ChatGPT 等同款):GlassEffectContainer 内放多颗
        // .glassEffect(.regular.interactive(), in: Capsule) 元件——容器把相邻胶囊
        // 「融合」成一条连续液态玻璃,四周一圈共享 rim;.interactive() 提供鼠标悬停
        // 时那层灰色高亮(看得见单个按钮轮廓),press 也由系统原生给。
        // 关键前提:每颗 chip 必须先有内边距(body),否则玻璃缩成发丝=看不见。
        GlassEffectContainer(spacing: 6) {
        HStack(spacing: 6) {
            // 左侧来源面包屑:独立一颗玻璃胶囊(Raycast 左侧 `图标+Clipboard History` 同位)。
            sourceBreadcrumb

            if viewModel.hasActiveFilter && viewModel.selectedListItem == nil {
                Text("No selection")
                    .font(.system(size: 11))
                    .foregroundStyle(ClipinInk.tertiary)
                    .padding(.leading, 8)
            }

            Spacer()

            // 右侧动作簇:Paste +(连续粘贴态)+ Actions 紧挨,间距 = 外层
            // GlassEffectContainer 的 spacing(6)→ 系统把它们融成**一条连续
            // 深色玻璃胶囊**、共享一圈 rim(Raycast 参照效果①);每颗仍
            // `.glassEffect(.regular.interactive())`→ hover 单颗内缩灰高亮+微浮
            // (效果②)。中间不放 Spacer / 不加 padding,否则间距 >spacing 就裂开。
            HStack(spacing: 6) {
                if viewModel.selectedListItem != nil {
                    Button { viewModel.pasteSelected() } label: {
                        pasteCallToAction(
                            label: viewModel.targetAppName.map { String(format: NSLocalizedString("Paste to %@", comment: ""), $0) } ?? NSLocalizedString("Paste", comment: ""),
                            key: "↵"
                        )
                    }
                    .buttonStyle(ClipinFooterGlassButtonStyle())
                    .glassEffectUnion(id: "footerActions", namespace: footerGlassNS)
                    .onHover { hovering in
                        withAnimation(ClipinMotion.commandReveal) { isPasteHovered = hovering }
                    }
                    .anchorPreference(key: PasteButtonAnchorKey.self, value: .bounds) { $0 }
                }

                if viewModel.isContinuousPasteEnabled {
                    continuousPastePill
                        .glassEffectUnion(id: "footerActions", namespace: footerGlassNS)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }

                // ⌘K Actions 作为全局入口常驻;与 Paste 同 union id → 融成一条连续胶囊。
                Button { viewModel.toggleActionsPalette() } label: {
                    keyBadge(label: "Actions", key: "⌘K")
                }
                .buttonStyle(ClipinFooterGlassButtonStyle())
                .glassEffectUnion(id: "footerActions", namespace: footerGlassNS)
            }
        }
        .padding(.horizontal, ClipinChrome.footerContentInset)
        .padding(.vertical, ClipinChrome.footerContentInset)
        .frame(minHeight: ClipinChrome.footerMinHeight)
        .animation(ClipinMotion.commandReveal, value: showsDerivedPills)
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
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        // 来源面包屑与命令胶囊同语:同为 Capsule 原生 glass,放进同一 GlassEffectContainer
        // 后与命令胶囊融合成一条连续液态玻璃(共享四周 rim)。它不是按钮故不 interactive。
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
        .buttonStyle(ClipinFooterGlassButtonStyle())
        .help(NSLocalizedString("Press Esc to exit Continuous Paste.", comment: ""))
        .accessibilityLabel(Text("Continuous Paste"))
        .accessibilityHint(Text("Press Esc to exit Continuous Paste."))
    }

    /// hover Paste 时其正上方派生的次级动作胶囊数据(随选中条目能力动态)。
    /// 动作与旧"横向展开簇"字节不变,仅呈现位置从"Paste 左侧横排"改"Paste 正上方派生"。
    private func hoverPills() -> [FooterDerivedPill] {
        var pills: [FooterDerivedPill] = []
        if viewModel.selectedRepresentationUTIs.contains("public.html") {
            pills.append(FooterDerivedPill(label: "HTML", shortcut: "⌥H") {
                viewModel.pasteRepresentationSelected(uti: "public.html")
            })
        }
        if viewModel.selectedRepresentationUTIs.contains("public.rtf") {
            pills.append(FooterDerivedPill(label: "RTF", shortcut: "⌥R") {
                viewModel.pasteRepresentationSelected(uti: "public.rtf")
            })
        }
        pills.append(FooterDerivedPill(label: "Plain Text", shortcut: "⇧↵") {
            viewModel.pastePlainSelected()
        })
        if viewModel.canOpenSelectedItem {
            pills.append(FooterDerivedPill(label: viewModel.selectedOpenLabel, shortcut: "⌘O") {
                viewModel.openSelected()
            })
        }
        if viewModel.canPreviewSelectedItem {
            pills.append(FooterDerivedPill(label: viewModel.isPreparingPreview ? "Preparing…" : "Preview", shortcut: "Space") {
                _ = viewModel.previewSelected()
            })
        }
        return pills
    }

    private func pasteCallToAction(label: String, key: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
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
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(ClipinInk.primary)
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
        // 浮动 notice = iOS 26 玻璃 Capsule toast(不硬编码 searchCornerRadius)。
        .clipinChromeGlass(in: Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous)
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
                isPinned: item.isPinned,
                concentric: true
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
