import SwiftUI

extension SettingsView {

    // MARK: - Retention Section
    //
    // v5: 不再是独立 tab——并入 Storage tab 顶部，对外暴露 `retentionSection` 子视图。
    // 内容分两层：规则（picker）+ 当前状态（历史项数 + 上次清理时间）。
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

    var retentionSection: some View {
        contentGroup {
            VStack(alignment: .leading, spacing: ClipinChrome.groupGap) {
                groupHeader("Retention")

                settingFieldRow("Keep unpinned history for", description: "Pinned items are always preserved.") {
                    Picker("", selection: normalizedRetentionDays) {
                        ForEach(Self.retentionOptions, id: \.days) { option in
                            Text(option.label).tag(option.days)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: ClipinChrome.pickerNarrow)
                }

                groupDivider

                settingFieldRow("Max unpinned items", description: "Oldest unpinned items are trimmed first when the limit is reached.") {
                    Picker("", selection: normalizedMaxItems) {
                        ForEach(Self.maxItemsOptions, id: \.count) { option in
                            Text(option.label).tag(option.count)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: ClipinChrome.pickerNarrow)
                }

                groupDivider

                cleanupActionRow
            }
        }
    }

    /// 把 actionRow + last-run 状态合并成一组——按钮在右、状态在左，
    /// 用户先看到"上次清理结果"再决定要不要再点。
    private var cleanupActionRow: some View {
        HStack(alignment: .top, spacing: ClipinChrome.groupGap) {
            VStack(alignment: .leading, spacing: ClipinChrome.gap) {
                Text("Run Cleanup Now")
                    .font(.system(size: 13, weight: .medium))

                Text("Apply the current retention rules immediately and remove outdated unpinned items.")
                    .font(.system(size: 11))
                    .foregroundStyle(ClipinInk.secondary)

                if let statusText = lastCleanupStatusText {
                    Text(statusText)
                        .font(.system(size: 11))
                        .foregroundStyle(ClipinInk.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: runCleanup) {
                progressButtonLabel(
                    title: activeOperation == .cleanup ? "Cleaning…" : "Run Cleanup Now",
                    isBusy: activeOperation == .cleanup
                )
            }
            .buttonStyle(.bordered)
            .disabled(activeOperation != nil)
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
