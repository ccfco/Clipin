import SwiftUI

/// 主面板 — Raycast 风格双栏布局
struct MainPanel: View {
    @StateObject private var viewModel: ClipboardViewModel

    init(core: ClipinCore) {
        _viewModel = StateObject(wrappedValue: ClipboardViewModel(core: core))
    }

    var body: some View {
        VStack(spacing: 0) {
            // 顶部搜索栏
            SearchBar(query: $viewModel.searchQuery, typeFilter: $viewModel.typeFilter)

            Divider()

            // 双栏内容区
            HSplitView {
                // 左侧列表
                itemList
                    .frame(minWidth: 280, idealWidth: 320, maxWidth: 400)

                // 右侧预览
                PreviewPane(item: viewModel.selectedItem)
                    .frame(minWidth: 300, idealWidth: 400)
            }

            Divider()

            // 底部工具栏
            bottomBar
        }
        .frame(width: 720, height: 480)
        .onAppear {
            viewModel.loadItems()
        }
        .onChange(of: viewModel.searchQuery) {
            viewModel.loadItems()
        }
        .onChange(of: viewModel.typeFilter) {
            viewModel.loadItems()
        }
    }

    // MARK: - 左侧列表

    private var itemList: some View {
        ScrollViewReader { proxy in
            List(selection: Binding(
                get: { viewModel.selectedItem?.id },
                set: { id in
                    viewModel.selectedItem = viewModel.items.first(where: { $0.id == id })
                }
            )) {
                ForEach(viewModel.groupedItems, id: \.0) { group, items in
                    Section(group) {
                        ForEach(items, id: \.id) { item in
                            ClipItemRow(item: item, isSelected: viewModel.selectedItem?.id == item.id)
                                .tag(item.id)
                                .id(item.id)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    // MARK: - 底部工具栏

    private var bottomBar: some View {
        HStack {
            if let item = viewModel.selectedItem {
                Button {
                    viewModel.deleteItem(item)
                } label: {
                    Label("Delete", systemImage: "trash")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)

                Button {
                    viewModel.togglePin(item)
                } label: {
                    Label(item.isPinned ? "Unpin" : "Pin", systemImage: item.isPinned ? "pin.slash" : "pin")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)

                Spacer()

                Text("Clipboard History")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)

                Spacer()

                // 粘贴快捷键提示
                HStack(spacing: 4) {
                    Text("Paste")
                        .font(.system(size: 12))
                    Text("↵")
                        .font(.system(size: 11, design: .monospaced))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(.quaternary)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
            } else {
                Spacer()
                Text("Clipboard History")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
