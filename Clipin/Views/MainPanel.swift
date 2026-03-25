import SwiftUI

/// 主面板 — 偏原生 macOS 的双栏布局
struct MainPanel: View {
    @ObservedObject var viewModel: ClipboardViewModel
    var onOpenSettings: () -> Void = {}

    init(viewModel: ClipboardViewModel, onOpenSettings: @escaping () -> Void = {}) {
        self.viewModel = viewModel
        self.onOpenSettings = onOpenSettings
    }

    var body: some View {
        VStack(spacing: 0) {
            // 搜索栏：白色背景 + 底部阴影 → 浮在列表上方
            SearchBar(
                query: $viewModel.searchQuery,
                typeFilter: $viewModel.typeFilter,
                onNavigate: { delta in
                    if delta > 0 { viewModel.selectNext() }
                    else { viewModel.selectPrev() }
                },
                onSubmit: { viewModel.pasteSelected() },
                onEscape: { viewModel.close() }
            )
            .shadow(color: .black.opacity(0.06), radius: 10, y: 4)
            .zIndex(1)

            HStack(spacing: 0) {
                // 左栏 sidebar：base 层，灰色背景
                itemList
                    .frame(width: 260)
                    .background(Color(nsColor: .controlBackgroundColor))

                // 右栏内容：compositingGroup + 左侧阴影 → 浮在 sidebar 上方
                PreviewPane(item: viewModel.selectedItem, searchQuery: viewModel.searchQuery)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .textBackgroundColor))
                    .compositingGroup()
                    .shadow(color: .black.opacity(0.1), radius: 14, x: -10, y: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .zIndex(0)

            // action bar：灰色背景 + 顶部阴影 → 浮在内容上方
            bottomBar
            .shadow(color: .black.opacity(0.05), radius: 8, y: -3)
            .zIndex(1)
        }
        .frame(width: 760, height: 520)
        // 纯实色白背景，不受桌面颜色污染
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(alignment: .bottomLeading) {
            if viewModel.isShowingActions {
                ActionPalette(
                    isPresented: $viewModel.isShowingActions,
                    actions: ActionPaletteBuilder.actions(for: viewModel)
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.12), value: viewModel.isShowingActions)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.04), radius: 64, y: 16)
        .shadow(color: .black.opacity(0.1), radius: 20, y: 8)
        .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
        .onAppear {
            viewModel.loadItems()
        }
    }

    private var itemList: some View {
        ItemListView(
            sections: viewModel.sections,
            isEmpty: viewModel.isEmpty,
            hasActiveFilter: viewModel.hasActiveFilter,
            searchQuery: viewModel.searchQuery,
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
        HStack(spacing: 0) {
            if viewModel.selectedListItem != nil {
                // 主操作：可点击的 key badge
                Button { viewModel.pasteSelected() } label: {
                    keyBadge(
                        label: viewModel.targetAppName.map { "Paste to \($0)" } ?? "Paste",
                        key: "↵",
                        primary: true
                    )
                }
                .buttonStyle(.plain)

                keyBadge(label: "Plain Text", key: "⇧↵")
                    .padding(.leading, 10)

                Spacer()

                // Actions — 点击 or ⌘K 打开 palette
                Button { viewModel.isShowingActions.toggle() } label: {
                    keyBadge(label: "Actions", key: "⌘K")
                }
                .buttonStyle(.plain)
            } else {
                Text("Clipboard History")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            Button { onOpenSettings() } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .padding(.leading, 12)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func keyBadge(label: String, key: String, primary: Bool = false) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(primary ? Color.primary : Color.secondary)
            Text(key)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
        }
    }
}

private struct ItemListView: View {
    let sections: [ClipSection]
    let isEmpty: Bool
    let hasActiveFilter: Bool
    let searchQuery: String
    let selection: Binding<String?>
    let onActivate: (ClipListItem) -> Void
    let onPin: (ClipListItem) -> Void
    let onDelete: (ClipListItem) -> Void

    @State private var hoveredID: String?

    /// 预计算 id -> 序号索引，O(n) 构建，O(1) 查找
    private var shortcutIndex: [String: Int] {
        var map: [String: Int] = [:]
        var i = 0
        for section in sections {
            for item in section.items {
                if i < 9 { map[item.id] = i + 1 }
                i += 1
            }
        }
        return map
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
                withAnimation(.easeInOut(duration: 0.12)) {
                    proxy.scrollTo(newID, anchor: .center)
                }
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .tracking(0.5)
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 3)
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
            isHovered: isHovered
        )
        .id(item.id)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    isSelected
                        ? Color.accentColor.opacity(0.12)
                        : isHovered
                            ? Color.primary.opacity(0.04)
                            : Color.clear
                )
                .padding(.horizontal, 6)
        )
        .animation(.easeOut(duration: 0.1), value: isSelected)
        .animation(.easeOut(duration: 0.08), value: isHovered)
            .contentShape(Rectangle())
            .onTapGesture { selection.wrappedValue = item.id }
            .onHover { hovered in hoveredID = hovered ? item.id : nil }
            .contextMenu {
                Button("Paste") { onActivate(item) }
                Button(item.isPinned ? "Unpin" : "Pin") { onPin(item) }
                Divider()
                Button("Delete", role: .destructive) { onDelete(item) }
            }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: hasActiveFilter ? "magnifyingglass" : "clipboard")
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)

            Text(hasActiveFilter ? "No results" : "No history yet")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)

            Text(hasActiveFilter
                 ? "Try a different search term or filter."
                 : "Copy something and it will appear here.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 200)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
