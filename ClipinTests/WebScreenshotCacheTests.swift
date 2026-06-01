import XCTest
import AppKit
@testable import Clipin

@MainActor
final class WebScreenshotCacheTests: XCTestCase {
    private func solidImage(white: CGFloat, side: Int = 64) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        NSColor(white: white, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: side, height: side).fill()
        image.unlockFocus()
        return image
    }

    func testQualityGateRejectsSolidColors() {
        // 纯白/纯黑/纯灰 = 加载中骨架、登录墙底色、cookie 遮罩的典型形态，方差≈0 应判无意义。
        XCTAssertFalse(WebScreenshotCache.isMeaningful(solidImage(white: 1.0)))
        XCTAssertFalse(WebScreenshotCache.isMeaningful(solidImage(white: 0.0)))
        XCTAssertFalse(WebScreenshotCache.isMeaningful(solidImage(white: 0.5)))
    }

    func testQualityGateAcceptsHighContrastContent() {
        // 黑白棋盘 = 高方差，代表"有文字/图的真实页面"。
        let side = 64
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        for y in 0..<side {
            for x in 0..<side {
                let on = (x / 8 + y / 8) % 2 == 0
                (on ? NSColor.white : NSColor.black).setFill()
                NSRect(x: x, y: y, width: 1, height: 1).fill()
            }
        }
        image.unlockFocus()
        XCTAssertTrue(WebScreenshotCache.isMeaningful(image))
    }
}
