import AppKit
import SwiftUI
import XCTest
@testable import Clipin

@MainActor
final class KeyboardNavigationScrollTests: XCTestCase {
    func testKeyboardNavigationMovesActualScrollViewport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let core = try ClipinCore(dbPath: root.appendingPathComponent("test.db").path, imageDir: root.path)
        for index in 0..<40 {
            _ = try core.importItem(content: "scroll fixture \(index)", clipType: .text,
                                    sourceApp: nil, sourceName: nil, imagePath: nil,
                                    isPinned: false,
                                    createdAt: index < 20 ? 1_000 : Int64(Date().timeIntervalSince1970),
                                    alias: nil)
        }
        let suite = "scroll-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let vm = ClipboardViewModel(core: core, settings: SettingsStore(defaults: defaults))
        let host = ClipinPanelHostingView(rootView: MainPanel(viewModel: vm))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 540),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(400))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(vm.sections.flatMap(\.items).count, 40)
        XCTAssertGreaterThan(vm.sections.count, 1)
        func scrollViews(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews($0) }
        }
        let scroll = try XCTUnwrap(scrollViews(host).first { $0.frame.width < 350 })
        let initial = scroll.contentView.bounds.origin.y
        // 第八行仍在初始视口内；选择不能为了居中而移动整张列表。
        for _ in 0..<7 {
            vm.selectNext()
            try await Task.sleep(for: .milliseconds(25))
        }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(scroll.contentView.bounds.origin.y, initial, accuracy: 1,
                       "Selecting an already visible row must not scroll")
        vm.selectFirst()
        try await Task.sleep(for: .milliseconds(400))
        for _ in 0..<25 {
            vm.selectNext()
            try await Task.sleep(for: .milliseconds(25))
        }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, initial + 200,
                             "Keyboard navigation must move the actual native viewport")
        let middle = scroll.contentView.bounds.origin.y
        vm.selectLast()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, middle)
        vm.selectFirst()
        try await Task.sleep(for: .milliseconds(400))
        // 最小滚动允许首行上方的分组标题移出视口，不要求回到内容原点。
        let firstItemOffset = scroll.contentView.bounds.origin.y
        XCTAssertLessThan(firstItemOffset, middle)
        for _ in 0..<25 { vm.selectNext() }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, initial + 200)
        for _ in 0..<25 { vm.selectPrev() }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(scroll.contentView.bounds.origin.y, firstItemOffset, accuracy: 1,
                       "Repeated navigation to the first item must return to the same viewport")
    }
}
