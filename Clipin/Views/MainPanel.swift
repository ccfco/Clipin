import SwiftUI

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
    /// hover Paste 或 pills 时显示派生簇;QA 钩子可强制常显(语义见 QAFlags)。
    private var showsDerivedPills: Bool {
        isPasteHovered || isPillsHovered || QAFlags.alwaysShowDerivedPills
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
                RoundedRectangle(cornerRadius: ClipinChrome.cornerShell, style: .continuous)
            )
    }

    private var panelContent: some View {
        VStack(spacing: 0) {
            headerBar
            contentArea
        }
        .frame(width: 800, height: 540)
        .overlay(alignment: .top) {
            ZStack(alignment: .top) {
                // 加载流光横跨整个面板顶边(launcher 通用「顶部加载条」心智)。
                if viewModel.isLauncherLoading || QAFlags.forceLauncherLoading {
                    LauncherLoadingGlow()
                        .transition(.opacity)
                }
                // 连续粘贴是全局模式状态，同样横跨顶边。
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
            .allowsHitTesting(false)
        }
        .overlay(alignment: .bottom) {
            bottomBar
                .opacity(viewModel.isShowingActions ? 0 : 1)
                .allowsHitTesting(!viewModel.isShowingActions)
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
                        // 6pt 视觉缝下沉到 pills 视图内部底 padding,而不是用 .offset 减 6:
                        // 后者会在 Paste 顶边和 pills 底边之间留一段「真空 hover 死区」,
                        // 鼠标从 Paste 经过这 6pt 缝去点 pills 时 isPasteHovered/Pills 全 false,
                        // showsDerivedPills 立刻收掉,点击根本来不及触发。
                        // padding + .contentShape(Rectangle()) 让 padding 区域参与 hit
                        // testing,鼠标穿过缝时仍命中 pills overlay,hover 持续 → 点击有效。
                        .padding(.bottom, ClipinChrome.gap)
                        .contentShape(Rectangle())
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { derivedPillsSize = $0 }
                        .onHover { hovering in
                            withAnimation(ClipinMotion.commandReveal) { isPillsHovered = hovering }
                        }
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                        // 右缘对齐 Paste 右缘;pills 底边(含 6pt padding)正好贴 Paste 顶边,
                        // padding 内部提供视觉留缝,命中区连续。
                        .offset(
                            x: pasteRect.maxX - derivedPillsSize.width,
                            y: pasteRect.minY - derivedPillsSize.height
                        )
                }
            }
        }
        .animation(ClipinMotion.commandReveal, value: showsDerivedPills)
        .overlay(alignment: .bottom) {
            if let notice = viewModel.launcherNotice {
                launcherNoticeBanner(notice)
                    .padding(.bottom, ClipinChrome.floatingFooterBand + ClipinChrome.gap)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(ClipinMotion.panel, value: viewModel.isContinuousPasteEnabled)
        .animation(ClipinMotion.feedback, value: viewModel.isLauncherLoading)
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
                    selectedItem: viewModel.selectedListItem,
                    onSelect: { index in
                        viewModel.executePaletteAction(at: index)
                    },
                    subActions: viewModel.subPaletteActions,
                    selectedSubIndex: $viewModel.selectedSubActionIndex,
                    onSelectSub: { index in
                        viewModel.executeSubPaletteAction(at: index)
                    }
                )
                .transition(
                    .asymmetric(
                        insertion: .scale(scale: 0.90, anchor: .bottomTrailing).combined(with: .opacity),
                        removal: .scale(scale: 0.93, anchor: .bottomTrailing).combined(with: .opacity)
                    )
                )
            }
        }
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
        // headerBar 是搜索区边距的唯一 owner（SearchBar 自身不再带 padding）。
        // 横向 groupGap=16 让搜索图标与列表 section header / 行图标都落在 16pt。
        // 不设 .bottom：搜索区↔列表的间距由首个 section header 的 groupGap 单独表达。
        .padding(.horizontal, ClipinChrome.groupGap)
        .padding(.top, ClipinChrome.groupGap)
        .offset(y: sceneState.headerLift)
        .animation(ClipinMotion.focusShift, value: sceneState)
    }

    private var contentArea: some View {
        HStack(spacing: ClipinChrome.gap) {
            itemList
                .frame(width: 292)
                .opacity(sceneState.listRestingOpacity)

            previewColumn
        }
        .padding(.horizontal, ClipinChrome.gap)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(ClipinMotion.focusShift, value: sceneState)
    }

    @ViewBuilder
    private var previewColumn: some View {
        // 预览与导航解耦:PreviewPane 不观察 vm,只吃这里注入的值 + `.equatable()`。
        // 导航连按时 selectedItem 被去抖压住 → itemRevision 不变、其余值不变 → SwiftUI 跳过整棵
        // 预览重渲染,按键路径不被预览占住(预览渲染是 ↑↓ 卡顿的确凿主因,实测占残留卡顿绝大部分)。
        PreviewPane(
            item: viewModel.displayedItem,
            searchQuery: viewModel.searchQuery,
            sceneState: sceneState,
            itemRevision: viewModel.selectedItemRevision,
            editingItemID: viewModel.editingContentItemID,
            representationUTIs: viewModel.selectedRepresentationUTIs,
            hasSelection: viewModel.selectedListItem != nil,
            fileAttachmentIndex: viewModel.fileAttachmentPreviewIndex,
            editingDraft: viewModel.editingContentDraft,
            vm: viewModel
        )
        .equatable()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var itemList: some View {
        ItemListView(
            shortcutIndex: viewModel.shortcutIndexByID,
            sections: viewModel.sections,
            isEmpty: viewModel.isEmpty,
            hasActiveFilter: viewModel.hasActiveFilter,
            hasMore: viewModel.hasMore,
            searchQuery: viewModel.searchQuery,
            showsShortcutHint: viewModel.isShortcutHintVisible,
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
        .environmentObject(viewModel)
    }

    private var bottomBar: some View {
        // 命令簇坐在窗体玻璃上、无独立玻璃外壳(见 bottomBarRow),故不再需要 GlassEffectContainer
        // ——它仅用于把多个 .glassEffect 元件融成连续玻璃,而这里已无任何 glassEffect。
        bottomBarRow
    }

    private var bottomBarRow: some View {
        HStack(spacing: ClipinChrome.gap) {
            // 左侧留空:app 身份已上移到搜索栏左侧图标,条目来源在右侧预览 metadata
            // rail 已显示,底栏只承担右对齐命令簇(去掉伪按钮式来源胶囊)。
            Spacer()

            // 右侧命令簇:每颗命令(Paste / Actions)是坐在窗体玻璃上的「文字 + 键帽」,无独立
            // 材质外壳。ClipinFooterSegmentStyle 只负责 hover/press 的极淡内缩底板 + 微缩放
            // (与列表选中底板同一套交互语言),不再承担任何玻璃。
            HStack(spacing: ClipinChrome.gap) {
                if viewModel.selectedListItem != nil {
                    Button { viewModel.pasteSelected() } label: {
                        pasteCallToAction(
                            label: viewModel.targetAppName.map { String(format: NSLocalizedString("Paste to %@", comment: ""), $0) } ?? NSLocalizedString("Paste", comment: ""),
                            key: "↵"
                        )
                    }
                    .buttonStyle(ClipinFooterSegmentStyle())
                    .onHover { hovering in
                        withAnimation(ClipinMotion.commandReveal) { isPasteHovered = hovering }
                    }
                    .anchorPreference(key: PasteButtonAnchorKey.self, value: .bounds) { $0 }
                }

                if viewModel.isContinuousPasteEnabled {
                    continuousPastePill
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }

                Button { viewModel.toggleActionsPalette() } label: {
                    keyBadge(label: "Actions", key: "⌘K")
                }
                .buttonStyle(ClipinFooterSegmentStyle())
            }
            // 命令直接坐窗体玻璃,不套盒子——与搜索栏 / 列表 / 预览同一套语法(内容靠 vibrancy
            // 坐在那块唯一的 NSGlassEffectView 上)。底栏曾是全 app 唯一套了玻璃外壳的内容,反而
            // 最突兀;删掉外壳,可点/选中反馈交给 ClipinFooterSegmentStyle 的极淡内缩底板(与列表
            // 选中底板同源),Paste 主操作靠字重强调,不靠材质。同心/圆角/悬浮问题随外壳一并消失。
        }
        .animation(ClipinMotion.commandReveal, value: showsDerivedPills)
        // 命令簇在底部避让带(floatingFooterBand)内垂直居中。前提:预览 metadata 也归位到避让线
        // (见 PreviewPane.contentStage 已删旧胶囊遗留的 8pt 下内距),metadata 底 = 避让线 = 52,
        // 命令簇在 52 带内居中 → 距 metadata、距窗口底严格相等(各 ~9),且命令簇扎实贴底不飘。
        .frame(height: ClipinChrome.floatingFooterBand)
        .padding(.trailing, ClipinChrome.gap)
        .animation(ClipinMotion.focusShift, value: sceneState)
    }


    private var continuousPastePill: some View {
        Button { viewModel.toggleContinuousPaste() } label: {
            HStack(spacing: ClipinChrome.gap) {
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
        .buttonStyle(ClipinFooterSegmentStyle())
        .help(NSLocalizedString("Press Esc to exit Continuous Paste.", comment: ""))
        .accessibilityLabel(Text("Continuous Paste"))
        .accessibilityHint(Text("Press Esc to exit Continuous Paste."))
    }

    /// hover Paste 时其正上方派生的次级动作胶囊数据(随选中条目能力动态)。
    /// 动作与旧"横向展开簇"字节不变,仅呈现位置从"Paste 左侧横排"改"Paste 正上方派生"。
    /// 不变量:每个 pill 的 `label+shortcut` 必须全局唯一——FooterDerivedPill.id 由二者拼成,
    /// 重复会让 ForEach 把不同动作当同一元素、hover/过渡整组重建闪动(故勿加同名项)。
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
            pills.append(FooterDerivedPill(
                label: viewModel.isPreparingPreview ? "Preparing…" : "Preview",
                shortcut: "Space",
                // Quick Look 内能用方向键在可见列表里翻上/下一条是隐形能力,tooltip surface 给鼠标用户。
                help: "Space to preview · arrow keys flip through items in the preview"
            ) {
                _ = viewModel.previewSelected()
            })
        }
        return pills
    }

    private func pasteCallToAction(label: String, key: String) -> some View {
        HStack(spacing: ClipinChrome.gap) {
            Text(label)
                // Paste 是底栏主操作:纯黑 + semibold 字重双重强调(该黑的黑、该重的重);
                // Actions 等次级命令走柔化灰 + medium,主次分明。
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .truncationMode(.tail)

            // 全 app 唯一 accent 焦点:Paste 的 ↵ 键帽点亮(CLAUDE.md「accent 仅余 Paste 主键帽」)。
            ClipinKeycap(
                key: key,
                foreground: ClipinInk.secondary,
                accent: true
            )
        }
    }

    private func keyBadge(label: String, key: String) -> some View {
        HStack(spacing: ClipinChrome.gap) {
            Text(LocalizedStringKey(label))
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.82))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            ClipinKeycap(key: key, foreground: ClipinInk.secondary)
        }
    }

    private func launcherNoticeBanner(_ notice: LauncherNotice) -> some View {
        HStack(spacing: ClipinChrome.gap) {
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
        .padding(.horizontal, ClipinChrome.groupGap)
        .padding(.vertical, ClipinChrome.gap)
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

private struct LauncherLoadingGlow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let cycleDuration: TimeInterval = 1.35

    var body: some View {
        TimelineView(.animation) { timeline in
            GeometryReader { geo in
                let width = max(geo.size.width, 1)
                let band = max(width * 0.42, 220)
                let rawPhase = timeline.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: cycleDuration) / cycleDuration
                let phase = reduceMotion ? 0.5 : rawPhase
                let x = phase * (width + band) - band

                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill(Color.white.opacity(0.22))
                        .frame(width: width, height: 1)

                    Capsule(style: .continuous)
                        .fill(Color.accentColor.opacity(0.28))
                        .frame(width: band, height: 4)
                        .blur(radius: 10)
                        .offset(x: x)

                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.62))
                        .frame(width: band * 0.34, height: 1.8)
                        .blur(radius: 3)
                        .offset(x: x + band * 0.22)
                }
                .frame(width: width, height: 18, alignment: .topLeading)
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black, location: 0.08),
                            .init(color: .black, location: 0.92),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .blendMode(.plusLighter)
            }
        }
        .frame(height: 18)
        // +1pt 让流光避开面板物理顶边的 shell 圆角顶点 + window frame hairline，落在玻璃内侧第一排干净像素。
        .offset(y: 1)
    }
}

private struct ItemListView: View {
    /// ViewModel 预派生的 id -> ⌘N 序号（1..9）。
    /// 旧实现把 shortcutOrder 传进来在 view body 里 prefix(9).enumerated() 重建字典，
    /// hover 抖动触发整个 ItemListView 重渲染时会重复 N 次。改为 VM 单次派生 + 透传。
    let shortcutIndex: [String: Int]
    let sections: [ClipSection]
    let isEmpty: Bool
    let hasActiveFilter: Bool
    let hasMore: Bool
    let searchQuery: String
    /// 「长按 ⌘」是否已触发 — 决定是否在前 9 行浮出快速粘贴数字徽标。
    let showsShortcutHint: Bool
    let sceneState: ClipinSceneState
    let selection: Binding<String?>
    let onActivate: (ClipListItem) -> Void
    let onPin: (ClipListItem) -> Void
    let onDelete: (ClipListItem) -> Void
    let onClearFilters: () -> Void
    let onLoadMore: () -> Void

    @State private var hoveredID: String?
    @EnvironmentObject private var vm: ClipboardViewModel

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
                // 仅留底部 inset(末行不贴滚动边)。顶部留白交给首个 section header 的
                // groupGap 单独表达,避免「列表内距 + header 顶距」再次双层叠加。
                .padding(.bottom, ClipinChrome.gap)
            }
            // launcher 心智:列表是无 chrome 的纯内容流,与动作面板/引导页/预览滚动区
            // 一致隐藏滚动指示器(否则「始终显示滚动条」系统设置或鼠标用户下会常驻出现)。
            .scrollIndicators(.never)
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
        // 左缘 = edge，与行内图标/文字对齐（选中底板已填满整列，行文字内缩 edge）。
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(ClipinInk.secondary)
            .tracking(0.35)
            .padding(.horizontal, ClipinChrome.gap)
            .padding(.top, ClipinChrome.groupGap)
            .padding(.bottom, ClipinChrome.gap)
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
            showsShortcutHint: showsShortcutHint,
            sceneState: sceneState,
            isRenaming: vm.renamingItemID == item.id,
            renameDraft: vm.renameDraft,
            onCommitRename: { vm.commitRenaming() }
        )
        // .equatable():行不再观察整个 vm 后,本视图每次按键仍会被 ItemListView 重跑而重建每行 struct;
        // EquatableView 用 == 拦下未变行的整 body(JSONDecode/AttributedString 全跳过),
        // 每次 ↑↓ 只有旧选中 + 新选中两行真重算。详见 ClipItemRow 的 Equatable 扩展。
        .equatable()
        .id(item.id)
        // 选中底板填满整列：左 edge 距窗口、右 edge 距预览，均由 contentArea/列间距提供，
        // 不再额外加 listRowOuterInset（去掉旧的「列内距 + 行外距」双层叠加）。
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
        .scaleEffect(isSelected ? sceneState.selectedRowScale : 1.0)
        .offset(y: isSelected ? sceneState.selectedRowLift : 0)
        .opacity(!isSelected ? sceneState.listRestingOpacity : 1.0)
        .animation(ClipinMotion.selection, value: isSelected)
        .animation(ClipinMotion.feedback, value: isHovered)
        .contentShape(Rectangle())
        // 单击选中必须用 simultaneousGesture：若与下面的双击手势同为普通 gesture，
        // SwiftUI 会把两者设为互斥，单击需等系统双击间隔（~0.3s）确认"不是双击"
        // 才触发，造成点击条目后选中明显卡顿。声明为 simultaneous 即退出仲裁、
        // 立即选中；双击时第一下照常选中（幂等），第二下再 onActivate 粘贴，
        // 与原生 macOS 列表"每次点击即选中、第二击额外激活"的行为一致。
        .onTapGesture(count: 2) {
            if vm.editingContentItemID == nil { onActivate(item) }
        }
        .simultaneousGesture(TapGesture(count: 1).onEnded {
            if vm.editingContentItemID == nil { selection.wrappedValue = item.id }
        })
        .onHover { hovered in hoveredID = hovered ? item.id : nil }
        .contextMenu {
            Button("Paste") { onActivate(item) }
            Button(item.isPinned ? LocalizedStringKey("Unpin") : LocalizedStringKey("Pin")) { onPin(item) }
            Divider()
            Button("Delete", role: .destructive) { onDelete(item) }
        }
    }

    private var emptyState: some View {
        VStack(spacing: ClipinChrome.gap) {
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

            HStack(spacing: ClipinChrome.gap) {
                badgeCapsule("⌘K")
                Text(hasActiveFilter ? LocalizedStringKey("Actions") : LocalizedStringKey("Actions & Settings"))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(ClipinInk.secondary)
            }
            .padding(.top, ClipinChrome.gap)

            if hasActiveFilter {
                Button("Clear Search & Filters") {
                    onClearFilters()
                }
                .font(.system(size: 11.5, weight: .medium))
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.top, ClipinChrome.gap)
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
