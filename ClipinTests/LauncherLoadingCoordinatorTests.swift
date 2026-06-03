import XCTest
@testable import Clipin

@MainActor
final class LauncherLoadingCoordinatorTests: XCTestCase {
    func testReferenceCountingKeepsVisibleUntilAllSourcesCleared() {
        var visible = false
        let c = LauncherLoadingCoordinator(minimumVisibleSeconds: 0) { visible = $0 }
        c.set(true, source: .previewNetwork("a"))
        XCTAssertTrue(visible)
        c.set(true, source: .previewNetwork("b"))
        c.set(false, source: .previewNetwork("a"))
        XCTAssertTrue(visible, "仍有 b 占用,不该熄灭")
    }

    func testClearImmediatelyHides() {
        var visible = false
        let c = LauncherLoadingCoordinator(minimumVisibleSeconds: 0) { visible = $0 }
        c.set(true, source: .quickLookPreparation)
        XCTAssertTrue(visible)
        c.clear()
        XCTAssertFalse(visible, "clear 同步熄灭,不走最小可见时长")
    }

    func testOnVisibleChangeFiresOnlyOnFlip() {
        var changes: [Bool] = []
        let c = LauncherLoadingCoordinator(minimumVisibleSeconds: 0) { changes.append($0) }
        c.set(true, source: .previewNetwork("a"))   // → true
        c.set(true, source: .previewNetwork("b"))   // 已 true,不再回调
        XCTAssertEqual(changes, [true])
    }
}
