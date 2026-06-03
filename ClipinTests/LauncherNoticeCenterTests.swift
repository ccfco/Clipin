import XCTest
@testable import Clipin

@MainActor
final class LauncherNoticeCenterTests: XCTestCase {
    func testShowEmitsNoticeThroughCallback() {
        var last: LauncherNotice?
        let center = LauncherNoticeCenter { last = $0 }
        center.show("hello", style: .info, actionTitle: nil, duration: .seconds(99), action: nil)
        XCTAssertEqual(last?.text, "hello")
        XCTAssertEqual(last?.style, .info)
    }

    func testDismissEmitsNil() {
        var last: LauncherNotice?
        let center = LauncherNoticeCenter { last = $0 }
        center.show("hello", style: .info, actionTitle: nil, duration: .seconds(99), action: nil)
        center.dismiss()
        XCTAssertNil(last)
    }

    func testPerformActionRunsActionThenClears() {
        var fired = 0
        var last: LauncherNotice?
        let center = LauncherNoticeCenter { last = $0 }
        center.show("u", style: .warning, actionTitle: "Undo", duration: .seconds(99)) { fired += 1 }
        center.performAction()
        XCTAssertEqual(fired, 1)
        XCTAssertNil(last, "performAction 后 notice 应清空")
    }

    func testPerformActionWithoutActionJustClears() {
        var last: LauncherNotice?
        let center = LauncherNoticeCenter { last = $0 }
        center.show("x", style: .info, actionTitle: nil, duration: .seconds(99), action: nil)
        center.performAction()
        XCTAssertNil(last)
    }
}
