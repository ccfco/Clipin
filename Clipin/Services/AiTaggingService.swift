import Foundation
import FoundationModels

/// Apple Intelligence 语义标签生成（macOS 26+）。
///
/// 设计要点：
/// - **纯本机**：SystemLanguageModel 是端侧模型，内容不出设备；设置页开关默认开启。
/// - **单一流水线**：`kick` 幂等，同一时刻只有一条 drain 在跑，避免复制高峰并发抢模型。
/// - **可重入失败语义**：单条生成失败不写库（保持 ai_tags = NULL，下轮重试）；
///   成功但无标签写空串哨兵，避免 backfill 对同一批条目无限重跑。
/// - 标签是 content/OCR 的派生数据，不进入备份格式；导入后由 backfill 重新生成。
actor AiTaggingService {
    static let shared = AiTaggingService()

    private static let pageSize: Int32 = 10
    private static let maxInputCharacters = 2_000
    private static let maxTags = 5

    private var isRunning = false
    private var pendingKick = false

    /// 当前机器是否可用：设备支持且 Apple Intelligence 已开启、模型就绪。
    nonisolated static var isAvailable: Bool {
        SystemLanguageModel(useCase: .contentTagging).availability == .available
    }

    /// 触发一轮 backfill。可安全重复调用；运行中只登记"再跑一轮"。
    func kick(core: ClipinCore) {
        guard Self.isAvailable else { return }
        if isRunning {
            pendingKick = true
            return
        }
        isRunning = true
        Task { await drain(core: core) }
    }

    private func drain(core: ClipinCore) async {
        defer { isRunning = false }
        repeat {
            pendingKick = false
            await processPendingItems(core: core)
        } while pendingKick
    }

    /// 分页处理未打标签条目。无 offset：处理完写回 ai_tags，下一批自然前移。
    private func processPendingItems(core: ClipinCore) async {
        var processed = 0
        while !Task.isCancelled {
            let pending: [ClipItem]
            do {
                pending = try core.getUntaggedItems(limit: Self.pageSize)
            } catch {
                ClipinLog.aiTags.error("Tag backfill query failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            if pending.isEmpty { break }

            // 整页零成功必须退出：模型持续失败时 getUntaggedItems 会反复返回同一批。
            var wroteThisPage = 0
            for item in pending {
                if Task.isCancelled { return }
                guard let tags = await Self.generateTags(for: item) else { continue }
                do {
                    try core.updateAiTags(id: item.id, aiTags: tags.joined(separator: ", "))
                    wroteThisPage += 1
                    processed += 1
                    NotificationCenter.default.post(name: .clipboardItemAiTagsUpdated, object: nil)
                } catch {
                    ClipinLog.aiTags.error("Tag write failed id=\(item.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
            if wroteThisPage == 0 {
                ClipinLog.aiTags.error("Tag backfill made no progress on a full page, aborting this round")
                return
            }
        }
        if processed > 0 {
            ClipinLog.aiTags.notice("Tag backfill complete: \(processed, privacy: .public) item(s) tagged")
        }
    }

    /// 生成一条标签；nil = 本次失败（保持未处理），[] = 内容没有可提取标签（写空串哨兵）。
    static func generateTags(for item: ClipItem) async -> [String]? {
        let input = taggingInput(for: item)
        guard !input.isEmpty else { return [] }

        let session = LanguageModelSession(
            model: SystemLanguageModel(useCase: .contentTagging),
            instructions: """
            You label clipboard items so they can be found by meaning, not just exact words.
            Extract 3 to 5 short topical tags (one to three words each) that describe what the \
            content is about, its domain, and the action a user might take with it.
            Use the same language as the content. Do not repeat the whole text, do not add \
            generic tags like "text" or "content", and never include private identifiers.
            """
        )
        do {
            let response = try await session.respond(
                to: "Clipboard item:\n\(input)",
                generating: GeneratedTags.self
            )
            return sanitize(response.content.tags)
        } catch {
            ClipinLog.aiTags.error("Tag generation failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// 送入模型的正文：别名优先并入；图片用 OCR 文本（无文字则空）。
    static func taggingInput(for item: ClipItem) -> String {
        let body: String
        switch item.clipType {
        case .image: body = item.ocrText ?? ""
        default: body = item.content
        }
        var parts: [String] = []
        if let alias = item.alias, !alias.isEmpty { parts.append(alias) }
        parts.append(body)
        return String(parts.joined(separator: "\n").prefix(maxInputCharacters))
    }

    static func sanitize(_ rawTags: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in rawTags {
            let tag = raw
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "#、,，。.;；:："))
            // 标签会拼进 FTS，换行/超长会污染索引与预览 rail
            guard !tag.isEmpty, tag.count <= 40, !tag.contains("\n") else { continue }
            guard seen.insert(tag.lowercased()).inserted else { continue }
            result.append(tag)
            if result.count == maxTags { break }
        }
        return result
    }
}

/// 模型输出结构：只约束"标签数组"，具体措辞交给 instructions。
@Generable
private struct GeneratedTags {
    @Guide(description: "3 to 5 short topical tags, in the same language as the content")
    var tags: [String]
}