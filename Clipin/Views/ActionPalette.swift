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
    /// 真实 App 图标(如「粘贴到 XX」行);非 nil 时优先于 systemImage 渲染。
    let appIcon: NSImage?
    let badge: String
    let shortcut: PaletteActionShortcut?
    let section: PaletteActionSection
    let isDestructive: Bool
    let restoresSearchFocus: Bool
    /// 非 nil 时本动作不执行 handler,而是打开由这组子动作组成的子面板(如「粘贴为…」)。
    let submenu: [PaletteAction]?
    let handler: () -> Void

    init(
        _ title: String,
        systemImage: String,
        appIcon: NSImage? = nil,
        badge: String? = nil,
        shortcut: PaletteActionShortcut? = nil,
        section: PaletteActionSection = .secondary,
        isDestructive: Bool = false,
        restoresSearchFocus: Bool = true,
        submenu: [PaletteAction]? = nil,
        handler: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.appIcon = appIcon
        self.badge = badge ?? shortcut?.badge ?? ""
        self.shortcut = shortcut
        self.section = section
        self.isDestructive = isDestructive
        self.restoresSearchFocus = restoresSearchFocus
        self.submenu = submenu
        self.handler = handler
    }
}

// MARK: - ActionPalette
//
// 键盘导航完全由 AppDelegate.keyMonitor 负责（palette 开启时拦截 ↑↓/Enter/Escape），
// 此视图只负责渲染和鼠标交互。

struct ActionPalette: View {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var isPresented: Bool
    let actions: [PaletteAction]
    @Binding var selectedIndex: Int
    let selectedItem: ClipListItem?
    let onSelect: (Int) -> Void
    /// 「粘贴为…」子面板:非空即子面板显示中。
    let subActions: [PaletteAction]
    @Binding var selectedSubIndex: Int
    let onSelectSub: (Int) -> Void
    @State private var hoveredIndex: Int?
    @State private var subHoveredIndex: Int?
    /// 动作行区域的自然高度，用于把面板封顶到 paletteMaxHeight（超出则内层滚动）。
    @State private var actionsContentHeight: CGFloat = 0

    private var isShowingSub: Bool { !subActions.isEmpty }

    /// actionList 的解析高度：内容自然高度封顶到 paletteMaxHeight；
    /// 首个布局 pass 测量结果还是 0 时回退到 paletteMaxHeight，
    /// 避免出现 height=0 的塌陷帧（不依赖入场过渡的 opacity 来遮掩）。
    private var resolvedActionListHeight: CGFloat {
        let natural = actionsContentHeight > 0 ? actionsContentHeight : ClipinChrome.paletteMaxHeight
        return min(natural, ClipinChrome.paletteMaxHeight)
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

            // 子面板打开时主面板退到身后:压暗 + 不可点,把焦点交给子面板。
            palettePanel
                .opacity(isShowingSub ? 0.55 : 1)
                .allowsHitTesting(!isShowingSub)
                .padding(.trailing, ClipinChrome.gap)
                .padding(.bottom, ClipinChrome.gap)

            if isShowingSub {
                subPalettePanel
                    .padding(.trailing, ClipinChrome.gap)
                    .padding(.bottom, ClipinChrome.gap)
                    .transition(
                        .scale(scale: 0.92, anchor: .bottomTrailing).combined(with: .opacity)
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }

    private func dismiss() {
        isPresented = false
    }

    private var palettePanel: some View {
        // spacing 0：表头与动作行各自带 .padding(gap)，间距由两侧 padding 自行拼出，
        // VStack 不再叠加 spacing，使「顶/表头↔列表/行↔行/底」保持统一的 2×edge 节奏。
        VStack(alignment: .leading, spacing: 0) {
            paletteHeader

            if actions.isEmpty {
                emptyState
            } else {
                actionList
            }
        }
        // 面板内距 = edge：选中底板填满面板内壁后，底板距面板边恰为 edge，
        // 与面板距窗口边的 edge 一致（用户要的「选中→面板 = 面板→app」）。
        .padding(ClipinChrome.gap)
        .frame(width: 372, alignment: .leading)
        // 玻璃面与落影独立成层:.shadow 只栅格化这层玻璃+描边圆角矩形(不含文字),
        // 文字留在 background 之外直接合成 → 不被离屏栅格化,保持锐利。
        // 若把 .shadow 直接压在「内容 + 玻璃」整棵子树上,半透明玻璃会逼
        // SwiftUI 连文字一起位图化,文字丢掉像素对齐与次像素抗锯齿 → 发虚。
        .background { paletteGlassBackground }
        .onAppear { selectedIndex = 0 }
    }

    /// 命令面板/子面板共用的玻璃底:半透明玻璃 + 亮色白 tint + hairline 描边 + 落影。
    @ViewBuilder
    private var paletteGlassBackground: some View {
        let shape = RoundedRectangle(cornerRadius: ClipinChrome.cornerSurface, style: .continuous)
        Color.clear
            // 保留半透明玻璃,但亮色给玻璃加明显的白 tint —— 面板比窗体玻璃更白,
            // 一白一灰自然分层(对齐 Raycast:靠面板更白拉开层次,不靠压暗背景)。
            // 暗色不 tint(.regular 玻璃在暗窗体上本就偏亮浮起,已自带层次)。
            .glassEffect(
                colorScheme == .dark ? .regular : .regular.tint(Color.white.opacity(0.55)),
                in: shape
            )
            // hairline 描边勾出面板边缘,玻璃叠玻璃时也能看清边界。
            .overlay(
                shape.strokeBorder(
                    Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.10),
                    lineWidth: 0.5
                )
            )
            .shadow(color: paletteShadowColor, radius: 28, x: 0, y: 14)
    }

    /// 「粘贴为…」子面板:浮在主面板右下角、比主面板窄一档,主面板从其左上方露出。
    private var subPalettePanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            subPaletteHeader

            VStack(spacing: 0) {
                ForEach(Array(subActions.enumerated()), id: \.offset) { index, action in
                    actionRow(
                        action: action,
                        isSelected: selectedSubIndex == index,
                        isHovered: subHoveredIndex == index,
                        onTap: {
                            selectedSubIndex = index
                            onSelectSub(index)
                        },
                        onHoverChange: { subHoveredIndex = $0 ? index : nil }
                    )
                }
            }
        }
        .padding(ClipinChrome.gap)
        .frame(width: 320, alignment: .leading)
        .background { paletteGlassBackground }
    }

    private var subPaletteHeader: some View {
        HStack(spacing: ClipinChrome.gap) {
            Text("Paste as…")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(ClipinInk.secondary)

            Spacer(minLength: ClipinChrome.gap)

            ClipinKeycap(key: "Esc", foreground: ClipinInk.secondary)
        }
        .padding(ClipinChrome.gap)
    }

    /// 动作行区域：分组之间插 hairline 分隔线；包进内层 ScrollView 并按
    /// 自然高度封顶到 paletteMaxHeight；键盘移动选中时把选中行滚进可见区。
    private var actionList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(groupedActionIndices.enumerated()), id: \.offset) { groupOrdinal, group in
                        if groupOrdinal > 0 {
                            Rectangle()
                                .fill(ClipinInk.tertiary.opacity(0.55))
                                .frame(height: 1)
                                .padding(.horizontal, ClipinChrome.gap)
                                .padding(.vertical, ClipinChrome.gap)
                        }
                        VStack(spacing: 0) {
                            ForEach(group, id: \.self) { index in
                                actionRow(
                                    action: actions[index],
                                    isSelected: selectedIndex == index,
                                    isHovered: hoveredIndex == index,
                                    onTap: {
                                        selectedIndex = index
                                        onSelect(index)
                                    },
                                    onHoverChange: { hoveredIndex = $0 ? index : nil }
                                )
                                .id(index)
                            }
                        }
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { actionsContentHeight = $0 }
            }
            .frame(height: resolvedActionListHeight)
            .onChange(of: selectedIndex) { _, newIndex in
                withAnimation(ClipinMotion.feedback) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
        }
    }

    /// native glassEffect 只给发丝 rim、不给落影；底栏淡出后右下角无第二层玻璃，
    /// 这层落影让面板干净地浮在内容之上。dark 模式窗体暗、需更深的影才立得住。
    private var paletteShadowColor: Color {
        Color.black.opacity(colorScheme == .dark ? 0.40 : 0.22)
    }

    private var paletteHeader: some View {
        HStack(spacing: ClipinChrome.gap) {
            if let item = selectedItem {
                Image(systemName: item.typeIconName)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(ClipinInk.secondary)
                Text(item.displayTitle)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(ClipinInk.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Text("Actions")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(ClipinInk.secondary)
            }

            Spacer(minLength: ClipinChrome.gap)

            ClipinKeycap(
                key: "Esc",
                foreground: ClipinInk.secondary
            )
        }
        // 四边 = edge：与动作行同样的 .padding(gap)，表头文字四边都距面板内壁 edge，
        // 叠加面板自身 .padding(gap) 后为 2×edge，与行文字、面板上下边距完全一致。
        .padding(ClipinChrome.gap)
    }

    private func actionRow(
        action: PaletteAction,
        isSelected: Bool,
        isHovered: Bool,
        onTap: @escaping () -> Void,
        onHoverChange: @escaping (Bool) -> Void
    ) -> some View {
        let selectedFill = action.isDestructive ? Color.red.opacity(colorScheme == .dark ? 0.18 : 0.12) : ClipinSelectionInk.fill
        let selectedStroke = action.isDestructive ? Color.red.opacity(colorScheme == .dark ? 0.30 : 0.22) : ClipinSelectionInk.stroke
        let selectedInk = action.isDestructive ? Color.red.opacity(colorScheme == .dark ? 0.92 : 0.82) : Color.accentColor
        let selectedSecondaryInk = action.isDestructive ? Color.red.opacity(colorScheme == .dark ? 0.72 : 0.64) : ClipinInk.secondary

        // 该黑的黑(对齐 Raycast):未选中动作标题用纯 primary,选中走 accent/红。
        let foreground: Color = action.isDestructive
            ? (isSelected ? selectedInk : Color.red)
            : (isSelected ? selectedInk : Color.primary)

        return HStack(spacing: ClipinChrome.gap) {
            // 固定图标列:真 App 图标(满色)或 SF Symbol(随文字着色),
            // 所有动作行图标在同一列对齐(对齐 Raycast)。
            actionIcon(action, tint: foreground)
                .frame(width: 18, height: 18)

            Text(action.localizedTitle)
                .font(.system(size: 13.5, weight: .regular))
                .foregroundStyle(foreground)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: ClipinChrome.gap)

            if !action.badge.isEmpty {
                ClipinKeycap(
                    key: action.badge,
                    foreground: isSelected ? selectedSecondaryInk : ClipinInk.secondary
                )
            }
        }
        // 文字↔选中底板 = edge（四边一致）。
        .padding(.horizontal, ClipinChrome.gap)
        .padding(.vertical, ClipinChrome.gap)
        // 选中底板填满面板内壁，不再额外加 listRowOuterInset。
        .background(
            ClipinSelectableRowBackground(
                isSelected: isSelected,
                isHovered: isHovered,
                selectionFill: selectedFill,
                selectionStroke: selectedStroke,
                hoverFill: ClipinHoverInk.fill,
                hoverStroke: ClipinHoverInk.stroke
            )
        )
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .onHover { onHoverChange($0) }
        .animation(ClipinMotion.feedback, value: isSelected)
    }

    /// 动作行图标:有真实 App 图标则满色渲染,否则用 SF Symbol 跟随文字着色。
    @ViewBuilder
    private func actionIcon(_ action: PaletteAction, tint: Color) -> some View {
        if let appIcon = action.appIcon {
            Image(nsImage: appIcon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: action.systemImage)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(tint)
        }
    }

    private var emptyState: some View {
        VStack(spacing: ClipinChrome.gap) {
            Image(systemName: "command")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(ClipinInk.tertiary)

            Text("No actions available")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ClipinInk.secondary)

            Text("Press Escape to close.")
                .font(.system(size: 11))
                .foregroundStyle(ClipinInk.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 220)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, ClipinChrome.groupGap)
    }
}

// MARK: - ActionPaletteBuilder

struct ActionPaletteBuilder {
    @MainActor
    static func actions(for viewModel: ClipboardViewModel) -> [PaletteAction] {
        var list: [PaletteAction] = []

        if let selected = viewModel.selectedListItem {
            // Paste 是 palette 默认选中的首项，↵ 执行的就是它——↵ 是它的真实快捷键。
            // 有目标 App 时文案带 App 名 + 真实 App 图标(对齐 Raycast「Paste to XX」)。
            let pasteTitle = viewModel.targetAppName.map {
                String(format: NSLocalizedString("Paste to %@", comment: ""), $0)
            } ?? NSLocalizedString("Paste", comment: "")
            list.append(PaletteAction(pasteTitle, systemImage: "arrowshape.turn.up.left.fill", appIcon: viewModel.targetAppIcon, badge: "↵", section: .primary) {
                viewModel.pasteSelected()
            })

            // 「粘贴为…」收成子面板(对齐 Raycast):纯文本 + HTML/RTF
            // (后两者仅 text/url 且有对应 UTI 时出现)。子面板各项仍带真实快捷键,
            // ⇧↵/⌥H/⌥R 在命令面板打开时仍可直接命中(executePaletteShortcut 会穿透 submenu)。
            var pasteAsChildren: [PaletteAction] = [
                PaletteAction("Paste as Plain Text", systemImage: "doc.plaintext", shortcut: .pastePlain) {
                    viewModel.pastePlainSelected()
                }
            ]
            if let item = viewModel.currentSelectedItem() {
                pasteAsChildren.append(contentsOf: viewModel.representationActions(for: item))
            }
            list.append(PaletteAction(
                "Paste as…",
                systemImage: "doc.on.clipboard",
                appIcon: viewModel.targetAppIcon,
                section: .primary,
                submenu: pasteAsChildren
            ) {})

            if viewModel.canPreviewSelectedItem {
                list.append(PaletteAction("Preview", systemImage: "eye", shortcut: .preview, section: .primary, restoresSearchFocus: false) {
                    _ = viewModel.previewSelected()
                })
            }

            list.append(PaletteAction("Copy to Clipboard", systemImage: "doc.on.doc", shortcut: .copy, section: .primary) {
                viewModel.copySelected()
            })

            list.append(PaletteAction(selected.isPinned ? "Unpin" : "Pin", systemImage: selected.isPinned ? "pin.slash" : "pin", shortcut: .togglePin) {
                viewModel.togglePinSelected()
            })

            if viewModel.canOpenSelectedItem {
                list.append(PaletteAction(viewModel.selectedOpenLabel, systemImage: viewModel.selectedOpenSystemImage, shortcut: .open, restoresSearchFocus: false) {
                    viewModel.openSelected()
                })
            }
        }

        if viewModel.hasActiveFilter {
            // 同 Paste：Clear 既不是 palette 默认选中项也没有全局快捷键，
            // 行右侧画 ↵ 是欺骗 UI（用户按 Return 实际执行的是当前选中行，不是 Clear）。
            list.append(PaletteAction("Clear Search & Filters", systemImage: "line.3.horizontal.decrease.circle") {
                _ = viewModel.clearActiveQueryAndFilters()
            })
        }

        list.append(PaletteAction(
            viewModel.isContinuousPasteEnabled ? "Disable Continuous Paste" : "Enable Continuous Paste",
            systemImage: viewModel.isContinuousPasteEnabled ? "repeat.circle.fill" : "repeat.circle",
            shortcut: .toggleContinuousPaste
        ) {
            viewModel.toggleContinuousPaste()
        })

        list.append(PaletteAction("Open Settings", systemImage: "gearshape", shortcut: .settings, restoresSearchFocus: false) {
            viewModel.openSettings()
        })

        if viewModel.selectedListItem != nil {
            list.append(PaletteAction("Delete", systemImage: "trash", shortcut: .delete, section: .destructive, isDestructive: true) {
                viewModel.deleteSelected()
            })
        }

        return list
    }
}
