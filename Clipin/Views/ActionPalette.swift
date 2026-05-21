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
                .padding(.trailing, ClipinChrome.shellGap * 2)
                .padding(.bottom, ClipinChrome.shellGap)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }

    private func dismiss() {
        isPresented = false
    }

    private var palettePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            paletteHeader

            if actions.isEmpty {
                emptyState
            } else {
                actionList
            }
        }
        .padding(12)
        .frame(width: 372, alignment: .leading)
        .clipinChromeGlass(cornerRadius: ClipinChrome.paletteCornerRadius)
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
                                .padding(.horizontal, ClipinChrome.listRowOuterInset)
                                .padding(.vertical, 5)
                        }
                        VStack(spacing: 4) {
                            ForEach(group, id: \.self) { index in
                                actionRow(action: actions[index], index: index)
                                    .id(index)
                            }
                        }
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { actionsContentHeight = $0 }
            }
            .frame(height: min(actionsContentHeight, ClipinChrome.paletteMaxHeight))
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
        HStack(spacing: 8) {
            if let item = selectedItem {
                Image(systemName: item.typeIconName)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(ClipinInk.secondary)
                Text(item.displayTitle)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(ClipinInk.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Text("Actions")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(ClipinInk.secondary)
            }

            Spacer(minLength: 8)

            ClipinKeycap(
                key: "Esc",
                foreground: ClipinInk.secondary
            )
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
        .padding(.bottom, 4)
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
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            } icon: {
                Image(systemName: action.systemImage)
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(
                action.isDestructive
                    ? (isSelected ? selectedInk : Color.red)
                    : (isSelected ? selectedInk : ClipinInk.primary)
            )

            Spacer()

            ClipinKeycap(
                key: action.badge,
                foreground: isSelected ? selectedSecondaryInk : ClipinInk.secondary
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
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
        .padding(.horizontal, ClipinChrome.listRowOuterInset)
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
        VStack(spacing: 8) {
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
            // 不带 badge：Paste 是 palette 默认选中的第一项，"选中+Return=执行" 已由
            // selection 高亮表达；行右侧固定画 ↵ 会让用户在切到其它行时仍误以为
            // Return 直接粘贴，违反"展示出来的快捷键必须是真快捷键"约束。
            list.append(PaletteAction("Paste", systemImage: "arrowshape.turn.up.left.fill", section: .primary) {
                viewModel.pasteSelected()
            })

            // HTML/RTF representation actions（仅 text/url 且有对应 UTI 时出现）
            if let item = viewModel.currentSelectedItem() {
                list.append(contentsOf: viewModel.representationActions(for: item))
            }

            list.append(PaletteAction("Paste as Plain Text", systemImage: "textformat", shortcut: .pastePlain, section: .primary) {
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
