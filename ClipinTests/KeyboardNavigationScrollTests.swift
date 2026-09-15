import XCTest

final class KeyboardNavigationScrollTests: XCTestCase {
    func testKeyboardSelectionScrollDoesNotStartSelectionAnimation() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Clipin/Views/MainPanel.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertFalse(
            source.contains("withAnimation(ClipinMotion.selection) {\n                        proxy.scrollTo(scrollID, anchor: .center)"),
            "Keyboard selection must not start a scroll animation: macOS 27 drops scrollTo targets while a previous animated scroll is in flight."
        )
        XCTAssertTrue(
            source.contains("await Task.yield()"),
            "Repeated selection changes must coalesce until LazyVStack has completed the current layout pass."
        )
    }
}
