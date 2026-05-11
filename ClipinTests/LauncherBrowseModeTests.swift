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
}
