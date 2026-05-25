import SwiftUI

extension SettingsView {

    // MARK: - Retention Tab

    private static let retentionOptions: [(label: LocalizedStringKey, days: Int)] = [
        ("7 days", 7), ("30 days", 30), ("90 days", 90),
        ("1 year", 365), ("3 years", 1095), ("Forever", 0),
    ]
    private static let maxItemsOptions: [(label: LocalizedStringKey, count: Int)] = [
        ("500", 500), ("1K", 1_000), ("5K", 5_000),
        ("10K", 10_000), ("50K", 50_000), ("Unlimited", 0),
    ]

    private var normalizedRetentionDays: Binding<Int> {
        Binding(
            get: {
                let v = settings.retentionDays
                return Self.retentionOptions.map(\.days).contains(v) ? v
                    : Self.retentionOptions.map(\.days).min(by: { abs($0 - v) < abs($1 - v) }) ?? 30
            },
            set: { settings.retentionDays = $0 }
        )
    }
    private var normalizedMaxItems: Binding<Int> {
        Binding(
            get: {
                let v = settings.maxHistoryItems
                return Self.maxItemsOptions.map(\.count).contains(v) ? v
                    : Self.maxItemsOptions.map(\.count).min(by: { abs($0 - v) < abs($1 - v) }) ?? 500
            },
            set: { settings.maxHistoryItems = $0 }
        )
    }

    var retentionContent: some View {
        VStack(spacing: contentStackSpacing) {
            contentGroup {
                VStack(alignment: .leading, spacing: ClipinChrome.groupGap) {
                    settingFieldRow("Keep unpinned history for", description: "Pinned items are always preserved.") {
                        Picker("", selection: normalizedRetentionDays) {
                            ForEach(Self.retentionOptions, id: \.days) { option in
                                Text(option.label).tag(option.days)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 120)
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
                        .frame(width: 120)
                    }

                    groupDivider

                    actionRow(
                        "Run Cleanup Now",
                        description: "Apply the current retention rules immediately and remove outdated unpinned items.",
                        buttonTitle: "Run Cleanup Now",
                        busyTitle: "Cleaning…",
                        isBusy: activeOperation == .cleanup,
                        action: runCleanup
                    )
                }
            }
        }
    }
}
