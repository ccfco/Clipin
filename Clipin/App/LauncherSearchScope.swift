import Foundation

enum LauncherSearchScope {
    static func displayedMode(query: String, browseMode: LauncherBrowseMode) -> LauncherBrowseMode {
        let isSearching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if isSearching, browseMode.isPinnedOnly {
            return .all
        }
        return browseMode
    }
}
