import XCTest
@testable import Clipin

@MainActor
final class PendingDeletionControllerTests: XCTestCase {
    func testArmSetsPendingID() {
        let c = PendingDeletionController(window: .seconds(7))
        c.arm(id: "a") { }
        XCTAssertEqual(c.pendingID, "a")
    }

    func testCommitNowRunsCommitOnceAndClears() {
        let c = PendingDeletionController(window: .seconds(7))
        var count = 0
        c.arm(id: "a") { count += 1 }
        c.commitNow()
        XCTAssertEqual(count, 1)
        XCTAssertNil(c.pendingID)
        c.commitNow()  // 已无 pending,不重复
        XCTAssertEqual(count, 1)
    }

    func testCommitOtherCommitsWhenDifferent() {
        let c = PendingDeletionController(window: .seconds(7))
        var committed: [String] = []
        c.arm(id: "a") { committed.append("a") }
        c.commitOther(than: "b")
        XCTAssertEqual(committed, ["a"])
        XCTAssertNil(c.pendingID)
    }

    func testCommitOtherSkipsWhenSame() {
        let c = PendingDeletionController(window: .seconds(7))
        var count = 0
        c.arm(id: "a") { count += 1 }
        c.commitOther(than: "a")
        XCTAssertEqual(count, 0)
        XCTAssertEqual(c.pendingID, "a")
    }

    func testCancelDoesNotCommit() {
        let c = PendingDeletionController(window: .seconds(7))
        var count = 0
        c.arm(id: "a") { count += 1 }
        c.cancel()
        XCTAssertEqual(count, 0)
        XCTAssertNil(c.pendingID)
    }

    func testReArmCommitsNothingAutomatically() {
        let c = PendingDeletionController(window: .seconds(7))
        var count = 0
        c.arm(id: "a") { count += 1 }
        c.arm(id: "b") { count += 1 }
        XCTAssertEqual(count, 0)
        XCTAssertEqual(c.pendingID, "b")
    }
}
