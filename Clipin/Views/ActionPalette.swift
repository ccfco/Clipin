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
    let shortcut: PaletteActionShortcut?
    let section: PaletteActionSection
    let isDestructive: Bool
    let restoresSearchFocus: Bool
    let handler: () -> Void

    init(
        _ title: String,
        systemImage: String,
        badge: String? = nil,
        shortcut: PaletteActionShortcut? = nil,
        section: PaletteActionSection = .secondary,
        isDestructive: Bool = false,
        restoresSearchFocus: Bool = true,
        handler: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.badge = badge ?? shortcut?.badge ?? ""
        self.shortcut = shortcut
        self.section = section
        self.isDestructive = isDestructive
        self.restoresSearchFocus = restoresSearchFocus
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
    @State private var hoveredIndex: Int?
    /// 动作行区域的自然高度，用于把面板封顶到 paletteMaxHeight（超出则内层滚动）。
    @State private var actionsContentHeight: CGFloat = 0

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

            palettePanel
                .padding(.trailing, ClipinChrome.gap)
                .padding(.bottom, ClipinChrome.gap)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }

    private func dismiss() {
        isPresented = false
    }

    private var palettePanel: some View {
        VStack(alignment: .leading, spacing: ClipinChrome.gap) {
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
        .clipinChromeGlass(cornerRadius: ClipinChrome.cornerSurface)
        .shadow(color: paletteShadowColor, radius: 28, x: 0, y: 14)
        .onAppear { selectedIndex = 0 }
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
                                actionRow(action: actions[index], index: index)
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
        // 左缘 = edge：与下方动作行的文字对齐（行文字 = 选中底板内缩 edge）。
        .padding(.horizontal, ClipinChrome.gap)
    }

    private func actionRow(action: PaletteAction, index: Int) -> some View {
        let isSelected = selectedIndex == index
        let isHovered = hoveredIndex == index
        let selectedFill = action.isDestructive ? Color.red.opacity(colorScheme == .dark ? 0.18 : 0.12) : ClipinSelectionInk.fill
        let selectedStroke = action.isDestructive ? Color.red.opacity(colorScheme == .dark ? 0.30 : 0.22) : ClipinSelectionInk.stroke
        let selectedInk = action.isDestructive ? Color.red.opacity(colorScheme == .dark ? 0.92 : 0.82) : Color.accentColor
        let selectedSecondaryInk = action.isDestructive ? Color.red.opacity(colorScheme == .dark ? 0.72 : 0.64) : ClipinInk.secondary

        return HStack(spacing: 0) {
            Label {
                Text(action.localizedTitle)
                    .font(.system(size: 13.5, weight: .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
            } icon: {
                Image(systemName: action.systemImage)
                    .font(.system(size: 13.5, weight: .regular))
            }
            .foregroundStyle(
                action.isDestructive
                    ? (isSelected ? selectedInk : Color.red)
                    : (isSelected ? selectedInk : Color.primary.opacity(0.82))
            )

            Spacer()

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
        .onTapGesture {
            selectedIndex = index
            onSelect(index)
        }
        .onHover { hovered in
            hoveredIndex = hovered ? index : nil
        }
        .animation(ClipinMotion.feedback, value: isSelected)
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
            list.append(PaletteAction("Paste", systemImage: "arrowshape.turn.up.left.fill", badge: "↵", section: .primary) {
                viewModel.pasteSelected()
            })

            // HTML/RTF representation actions（仅 text/url 且有对应 UTI 时出现）
            if let item = viewModel.currentSelectedItem() {
                list.append(contentsOf: viewModel.representationActions(for: item))
            }

            list.append(PaletteAction("Paste as Plain Text", systemImage: "doc.plaintext", shortcut: .pastePlain, section: .primary) {
                viewModel.pastePlainSelected()
            })

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
