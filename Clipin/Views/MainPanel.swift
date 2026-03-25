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

            Divider()

            HStack(spacing: 0) {
                itemList
                    .frame(width: 260)
                    .background(Color(nsColor: .controlBackgroundColor))

                Divider()

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
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.10), radius: 18, y: 10)
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
        HStack(spacing: 6) {
            if viewModel.selectedListItem != nil {
                if let appName = viewModel.targetAppName {
                    ShortcutHint(keys: ["↵"], label: "Paste to \(appName)")
                } else {
                    ShortcutHint(keys: ["↵"], label: "Paste")
                }
                ShortcutHint(keys: ["⇧", "↵"], label: "Plain")
                ShortcutHint(keys: ["⌘", "C"], label: "Copy")
                ShortcutHint(keys: ["⌘", "⇧", "P"], label: pinLabel)
                ShortcutHint(keys: ["⌘", "⌫"], label: "Delete")

                if let item = viewModel.selectedItem,
                   item.clipType == .url || item.clipType == .file {
                    ShortcutHint(keys: ["⌘", "O"], label: "Open")
                }
            } else {
                Text("Clipboard History")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                onOpenSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var pinLabel: String {
        viewModel.selectedListItem?.isPinned == true ? "Unpin" : "Pin"
    }
}

/// 快捷键提示胶囊 — 模仿 Raycast 底部 action bar 风格
private struct ShortcutHint: View {
    let keys: [String]
    let label: String

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Text(key)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.3))
                    )
            }
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
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
            List(selection: selection) {
                ForEach(sections) { section in
                    Section {
                        ForEach(section.items, id: \.id) { item in
                            row(for: item)
                        }
                    } header: {
                        Text(section.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .textCase(nil)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .onChange(of: selection.wrappedValue) { _, newID in
                guard let newID else { return }
                withAnimation(.easeInOut(duration: 0.12)) {
                    proxy.scrollTo(newID, anchor: .center)
                }
            }
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

    private func row(for item: ClipListItem) -> some View {
        let number = shortcutIndex[item.id]

        return ClipItemRow(item: item, isSelected: selection.wrappedValue == item.id, shortcutNumber: number, searchQuery: searchQuery)
            .tag(item.id)
            .id(item.id)
            .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    onActivate(item)
                }
            )
            .contextMenu {
                Button("Paste") { onActivate(item) }
                Button(item.isPinned ? "Unpin" : "Pin") { onPin(item) }
                Divider()
                Button("Delete", role: .destructive) { onDelete(item) }
            }
    }
}
