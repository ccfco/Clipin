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

                PreviewPane(item: viewModel.selectedItem)
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
            selection: Binding(
                get: { viewModel.selectedItemID },
                set: { viewModel.selectItem(id: $0) }
            ),
            onActivate: { item in
                viewModel.selectItem(id: item.id)
                viewModel.pasteSelected()
            }
        )
    }

    private var bottomBar: some View {
        HStack(spacing: 6) {
            if viewModel.selectedListItem != nil {
                ShortcutHint(keys: ["↵"], label: "Paste")
                ShortcutHint(keys: ["⇧", "↵"], label: "Plain")
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
    let selection: Binding<String?>
    let onActivate: (ClipListItem) -> Void

    var body: some View {
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

    private func row(for item: ClipListItem) -> some View {
        ClipItemRow(item: item, isSelected: selection.wrappedValue == item.id)
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
    }
}
