import SwiftUI

extension SettingsView {

    // MARK: - Retention Section
    //
    // v5: 不再是独立 tab——并入 Storage tab 顶部，对外暴露 `retentionSection`（一个原生 Section）。
    // 内容分两层：规则（picker）+ 当前状态（上次清理时间 + 实际移除项数）。
    // "当前状态"是 CLAUDE.md「不沉默成功」红线的延伸：用户改了 picker 没法判断
    // 规则有没有真的跑过，必须显式回显证据。

    static let retentionOptions: [(label: LocalizedStringKey, days: Int)] = [
        ("7 days", 7), ("30 days", 30), ("90 days", 90),
        ("1 year", 365), ("3 years", 1095), ("Forever", 0),
    ]
    static let maxItemsOptions: [(label: LocalizedStringKey, count: Int)] = [
        ("500", 500), ("1K", 1_000), ("5K", 5_000),
        ("10K", 10_000), ("50K", 50_000), ("Unlimited", 0),
    ]

    var normalizedRetentionDays: Binding<Int> {
        Binding(
            get: {
                let v = settings.retentionDays
                return Self.retentionOptions.map(\.days).contains(v) ? v
                    : Self.retentionOptions.map(\.days).min(by: { abs($0 - v) < abs($1 - v) }) ?? 30
            },
            set: { settings.retentionDays = $0 }
        )
    }
    var normalizedMaxItems: Binding<Int> {
        Binding(
            get: {
                let v = settings.maxHistoryItems
                return Self.maxItemsOptions.map(\.count).contains(v) ? v
                    : Self.maxItemsOptions.map(\.count).min(by: { abs($0 - v) < abs($1 - v) }) ?? 500
            },
            set: { settings.maxHistoryItems = $0 }
        )
    }

    @ViewBuilder
    var retentionSection: some View {
        Section("Retention") {
            Picker(selection: normalizedRetentionDays) {
                ForEach(Self.retentionOptions, id: \.days) { option in
                    Text(option.label).tag(option.days)
                }
            } label: {
                rowLabel("Keep unpinned history for", "Pinned items are always preserved.")
            }

            Picker(selection: normalizedMaxItems) {
                ForEach(Self.maxItemsOptions, id: \.count) { option in
                    Text(option.label).tag(option.count)
                }
            } label: {
                rowLabel("Max unpinned items", "Oldest unpinned items are trimmed first when the limit is reached.")
            }

            cleanupActionRow
        }
    }

    /// 清理动作行：右侧按钮 + 标题/说明/上次结果。用户先看到"上次清理结果"再决定要不要再点。
    private var cleanupActionRow: some View {
        LabeledContent {
            Button(action: runCleanup) {
                progressButtonLabel(
                    title: activeOperation == .cleanup ? "Cleaning…" : "Run Cleanup Now",
                    isBusy: activeOperation == .cleanup
                )
            }
            .disabled(activeOperation != nil)
        } label: {
            Text("Run Cleanup Now")
            Text("Apply the current retention rules immediately and remove outdated unpinned items.")
                .settingsCaption()
            if let statusText = lastCleanupStatusText {
                Text(statusText)
                    .settingsCaption(.tertiary)
            }
        }
    }

    /// 上次清理摘要：时间 + 上次实际移除项数。
    /// 没跑过 → 隐藏（不写"never"，多余）；刚改完规则但还没跑 → 也隐藏。
    private var lastCleanupStatusText: String? {
        guard let lastRunAt = cleanupService.lastRunAt else { return nil }
        let timeText = relativeString(from: lastRunAt, to: now)
        if let result = cleanupService.lastResult, result.totalRemoved > 0 {
            return String(
                format: NSLocalizedString("Last cleanup: %@ · removed %d items", comment: ""),
                timeText, result.totalRemoved
            )
        }
        return String(
            format: NSLocalizedString("Last cleanup: %@ · nothing to remove", comment: ""),
            timeText
        )
    }
}
