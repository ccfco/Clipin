import SwiftUI

extension SettingsView {

    // MARK: - Sidebar

    var sidebar: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(SettingsTab.allCases) { tab in
                    sidebarRow(tab)
                }
            }
            // 卡片内壁留 edge：选中底板填满后距卡片边恰为 edge。
            .padding(ClipinChrome.gap)
        }
        .background(
            // 侧栏贴窗口左两角(HStack 整体内缩一个 gap):同心须降一档到 control(16=24−8)。
            ClipinContentSurface(cornerRadius: ClipinChrome.cornerControl)
        )
        .frame(width: 220)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func sidebarRow(_ tab: SettingsTab) -> some View {
        let isSelected = navigation.selectedTab == tab
        let isHovered = hoveredTab == tab

        return HStack(spacing: ClipinChrome.gap) {
            Image(systemName: tab.icon)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(isSelected ? Color.accentColor : ClipinInk.secondary)
                .frame(width: 28, height: 24)
                .background(
                    Group {
                        if isSelected {
                            RoundedRectangle(cornerRadius: ClipinChrome.cornerTile, style: .continuous)
                                .fill(ClipinSelectionInk.fill)
                                .overlay(
                                    RoundedRectangle(cornerRadius: ClipinChrome.cornerTile, style: .continuous)
                                        .strokeBorder(ClipinSelectionInk.stroke.opacity(0.72), lineWidth: 0.5)
                                )
                        } else {
                            Color.clear
                                .clipinChromeGlass(in: RoundedRectangle(cornerRadius: ClipinChrome.cornerTile, style: .continuous))
                        }
                    }
                )

            Text(tab.title)
                .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? Color.accentColor : ClipinInk.secondary)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // 文字↔选中底板 = edge；底板填满卡片内壁（去掉旧 listRowOuterInset）。
        .padding(ClipinChrome.gap)
        .background(
            ClipinSelectableRowBackground(
                isSelected: isSelected,
                isHovered: isHovered,
                selectionFill: ClipinSelectionInk.fill,
                selectionStroke: ClipinSelectionInk.stroke,
                hoverFill: ClipinHoverInk.fill,
                hoverStroke: ClipinHoverInk.stroke
            )
        )
        .contentShape(Rectangle())
        .onTapGesture { navigation.select(tab) }
        .onHover { hovered in hoveredTab = hovered ? tab : nil }
        .animation(ClipinMotion.selection, value: isSelected)
        .animation(ClipinMotion.feedback, value: isHovered)
    }
}
