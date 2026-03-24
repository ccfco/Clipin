import SwiftUI

/// 搜索框 + 类型过滤
struct SearchBar: View {
    @Binding var query: String
    @Binding var typeFilter: ClipType?

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 14))

                TextField("Type to filter entries...", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))

                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.quaternary.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            // 类型过滤
            Menu {
                Button("All Types") { typeFilter = nil }
                Divider()
                Button("Text") { typeFilter = .text }
                Button("Images") { typeFilter = .image }
                Button("Files") { typeFilter = .file }
                Button("URLs") { typeFilter = .url }
            } label: {
                HStack(spacing: 4) {
                    Text(filterLabel)
                        .font(.system(size: 12))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.quaternary.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var filterLabel: String {
        guard let filter = typeFilter else { return "All Types" }
        switch filter {
        case .text: return "Text"
        case .image: return "Images"
        case .file: return "Files"
        case .url: return "URLs"
        }
    }
}
