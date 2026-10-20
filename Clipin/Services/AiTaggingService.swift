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

    /// 按 created_at 游标分页处理未打标签条目。
    /// 游标在每条**尝试后**推进（无论成功失败）：生成失败的条目保持 NULL 留待下次重试，
    /// 但不能卡住本轮——否则一页全部失败（guardrail 拒绝、模型持续报错）会让更新的
    /// 条目永远轮不到。失败项在下一轮 kick 时自然重试一次。
    private func processPendingItems(core: ClipinCore) async {
        var processed = 0
        var cursor: (createdAt: Int64, id: String)?
        while !Task.isCancelled {
            let pending: [TaggingCandidate]
            do {
                pending = try core.getTaggingCandidates(
                    limit: Self.pageSize,
                    afterCreatedAt: cursor?.createdAt,
                    afterId: cursor?.id
                )
            } catch {
                ClipinLog.aiTags.error("Tag backfill query failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            if pending.isEmpty { break }

            for item in pending {
                if Task.isCancelled { return }
                cursor = (item.createdAt, item.id)
                guard let tags = await Self.generateTags(for: item) else { continue }
                do {
                    try core.updateAiTags(id: item.id, aiTags: tags.joined(separator: ", "))
                    processed += 1
                    // 带 item id：ViewModel 只刷新真正变化且正被选中的条目，
                    // 避免回填几百条时反复重渲染无关预览。
                    NotificationCenter.default.post(
                        name: .clipboardItemAiTagsUpdated,
                        object: item.id
                    )
                } catch {
                    ClipinLog.aiTags.error("Tag write failed id=\(item.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        if processed > 0 {
            ClipinLog.aiTags.notice("Tag backfill complete: \(processed, privacy: .public) item(s) tagged")
        }
    }

    /// 生成一条标签；nil = 本次失败（保持未处理），[] = 内容没有可提取标签（写空串哨兵）。
    static func generateTags(for candidate: TaggingCandidate) async -> [String]? {
        let input = taggingInput(alias: candidate.alias, text: candidate.text)
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

    /// 送入模型的正文：别名优先并入。候选的 text 已由 SQL 截到 2000 字符。
    static func taggingInput(alias: String?, text: String) -> String {
        var parts: [String] = []
        if let alias, !alias.isEmpty { parts.append(alias) }
        parts.append(text)
        return String(parts.joined(separator: "\n").prefix(maxInputCharacters))
    }

    static func sanitize(_ rawTags: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        // 模型偶尔把多个标签塞进一个字符串（"budget, planning"）。按分隔符拆开，
        // 让存储粒度与预览 rail 的拆分规则一致，也避免 FTS 里出现整串噪声。
        let separators = CharacterSet(charactersIn: ",，、;；")
        for raw in rawTags {
            for piece in raw.components(separatedBy: separators) {
                let tag = piece
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "#。.:："))
                // 标签会拼进 FTS，换行/超长会污染索引与预览 rail
                guard !tag.isEmpty, tag.count <= 40, !tag.contains("\n") else { continue }
                guard seen.insert(tag.lowercased()).inserted else { continue }
                result.append(tag)
                if result.count == maxTags { break }
            }
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