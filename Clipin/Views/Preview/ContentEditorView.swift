import AppKit
import SwiftUI

struct ContentEditorView: View {
    @ObservedObject var draft: EditingDraft
    let onSave: () -> Void
    let onCancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        // 间距/圆角走 ClipinChrome token（CLAUDE.md「统一间距系统」决策、构建期 spacing 守卫强制）。
        VStack(alignment: .leading, spacing: ClipinChrome.gap) {
            TextEditor(text: $draft.text)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .focused($focused)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(
                    RoundedRectangle(cornerRadius: ClipinChrome.cornerTile, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                )

            HStack(spacing: ClipinChrome.gap) {
                Spacer()
                Button(LocalizedStringKey("Cancel")) {
                    onCancel()
                }
                .buttonStyle(.plain)
                .foregroundStyle(ClipinInk.secondary)

                Button {
                    onSave()
                } label: {
                    HStack(spacing: ClipinChrome.gap) {
                        Text(LocalizedStringKey("Save"))
                        ClipinKeycap(key: "⌘↵", foreground: ClipinInk.secondary)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
        }
        .onAppear { focused = true }
    }
}

/// 文件预览主体单独拆出来：承载多文件 icon 异步加载 + mini list。
/// 旧实现把"只显示首文件 + 全路径列表"硬塞到 PreviewPane.content inline，
/// 多选时其余文件只剩纯文本路径行 —— 视觉上完全丢了 Finder 多选语义。
