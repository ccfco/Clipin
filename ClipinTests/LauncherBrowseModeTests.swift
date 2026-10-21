import XCTest
@testable import Clipin

final class LauncherBrowseModeTests: XCTestCase {
    func testSearchDisplayModeDoesNotShowPinnedAsActiveBecauseSearchIsGlobal() {
        XCTAssertEqual(
            LauncherSearchScope.displayedMode(query: "needle", browseMode: .pinned),
            .all
        )
        XCTAssertEqual(
            LauncherSearchScope.displayedMode(query: "needle", browseMode: .image),
            .image
        )
        XCTAssertEqual(
            LauncherSearchScope.displayedMode(query: "", browseMode: .pinned),
            .pinned
        )
    }

    func testFilterOrderOnlyContainsTypeFiltersAndAlwaysCompletesTheSet() {
        XCTAssertEqual(
            LauncherBrowseMode.normalizedFilterOrder([.text, .pinned, .text, .all, .url]),
            [.text, .url, .image, .file]
        )
        XCTAssertEqual(
            LauncherBrowseMode.normalizedFilterOrder([]),
            LauncherBrowseMode.defaultFilterCycleOrder
        )
    }

    func testCyclePutsAllFirstAndExcludesPinned() {
        XCTAssertEqual(
            LauncherBrowseMode.filterCycleModes(order: [.text, .image, .file, .url]),
            [.all, .text, .image, .file, .url]
        )
        XCTAssertEqual(
            LauncherBrowseMode.filterCycleModes(order: [.file, .url, .image, .text]),
            [.all, .file, .url, .image, .text]
        )
        XCTAssertFalse(
            LauncherBrowseMode.filterCycleModes(order: [.pinned, .text]).contains(.pinned)
        )
    }

    func testDefaultOrderPutsTextAfterTheNarrowerTypeFilters() {
        XCTAssertEqual(
            LauncherBrowseMode.defaultFilterCycleOrder.last,
            .text,
            "All 里绝大多数是文本，Text 筛选应排在图片/文件/链接之后"
        )
    }

    @MainActor
    func testFilterOrderPersistsAndConstrainsMovesToBounds() {
        let suiteName = "LauncherBrowseModeTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = SettingsStore(defaults: defaults)
        XCTAssertEqual(settings.filterCycleOrder, LauncherBrowseMode.defaultFilterCycleOrder)

        settings.moveFilter(.text, by: -1)
        XCTAssertEqual(settings.filterCycleOrder, [.image, .file, .text, .url])

        // 边界移动是 no-op：不允许因为多点一下把第一/最后一项卷到另一端。
        settings.moveFilter(.image, by: -1)
        settings.moveFilter(.url, by: 1)
        XCTAssertEqual(settings.filterCycleOrder, [.image, .file, .text, .url])

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.filterCycleOrder, [.image, .file, .text, .url])

        reloaded.resetFilterCycleOrder()
        XCTAssertEqual(reloaded.filterCycleOrder, LauncherBrowseMode.defaultFilterCycleOrder)
    }

    @MainActor
    func testUnnormalizedDirectAssignmentIsNormalizedAndPersisted() {
        let suiteName = "LauncherBrowseModeTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = SettingsStore(defaults: defaults)
        // didSet 内自赋值不会再次触发观察器，归一化结果必须在同一次回调里落盘，
        // 否则内存与下次启动读到的顺序会分叉。
        settings.filterCycleOrder = [.url, .pinned, .url]
        XCTAssertEqual(settings.filterCycleOrder, [.url, .image, .file, .text])

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.filterCycleOrder, [.url, .image, .file, .text])
    }

    @MainActor
    func testFavoritesPresentationDefaultsToMixed() {
        let suiteName = "LauncherBrowseModeTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = SettingsStore(defaults: defaults)
        XCTAssertEqual(settings.pinnedItemsPresentation, .mixed, "默认与最近项目混排")
    }
}
