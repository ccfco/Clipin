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

            HStack(spacing: 0) {
                itemList
                    .frame(width: 260)
                    .background(Color(nsColor: .controlBackgroundColor))

                PreviewPane(item: viewModel.selectedItem, searchQuery: viewModel.searchQuery)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            bottomBar
        }
        .frame(width: 760, height: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 24, y: 12)
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
                // 主操作：Paste
                Button {
                    viewModel.pasteSelected()
                } label: {
                    HStack(spacing: 5) {
                        Text(viewModel.targetAppName.map { "Paste to \($0)" } ?? "Paste")
                            .font(.system(size: 11, weight: .medium))
                        Text("↵")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.3))
                            )
                    }
                    .foregroundStyle(.primary)
                }
                .buttonStyle(.borderless)

                Spacer()

                // 次操作：Actions 菜单
                Menu {
                    Button("Paste as Plain Text") { viewModel.pastePlainSelected() }
                    Button("Copy to Clipboard") { viewModel.copySelected() }
                    Divider()
                    Button(pinLabel) { viewModel.togglePinSelected() }
                    if let item = viewModel.selectedItem,
                       item.clipType == .url || item.clipType == .file {
                        Button("Open") { viewModel.openSelected() }
                    }
                    Divider()
                    Button("Delete", role: .destructive) { viewModel.deleteSelected() }
                } label: {
                    HStack(spacing: 5) {
                        Text("Actions")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text("⌘K")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.3))
                            )
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            } else {
                Text("Clipboard History")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            Button {
                onOpenSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .padding(.leading, 8)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var pinLabel: String {
        viewModel.selectedListItem?.isPinned == true ? "Unpin" : "Pin"
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
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(for item: ClipListItem) -> some View {
        let number = shortcutIndex[item.id]
        let isSelected = selection.wrappedValue == item.id
        let isHovered = hoveredID == item.id

        return ClipItemRow(item: item, shortcutNumber: number, searchQuery: searchQuery)
            .id(item.id)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        isSelected
                            ? Color(nsColor: .quaternaryLabelColor).opacity(0.6)
                            : isHovered
                                ? Color(nsColor: .quaternaryLabelColor).opacity(0.3)
                                : Color.clear
                    )
                    .padding(.horizontal, 6)
            )
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
