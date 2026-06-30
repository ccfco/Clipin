import SwiftUI

extension SettingsView {

    // MARK: - Sidebar

    /// 原生 System Settings 风格侧栏：List(.sidebar) 提供系统 vibrancy 材质 +
    /// 原生圆角选中高亮。selection 绑定 navigation.selectedTab，让 key monitor 的
    /// ↑↓（selectPrev/Next）与鼠标点击共用同一选中状态。
    var sidebar: some View {
        List(selection: selectionBinding) {
            ForEach(SettingsTab.allCases) { tab in
                Label(tab.title, systemImage: tab.icon)
                    .tag(tab)
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 200, ideal: 215, max: 240)
    }
}
