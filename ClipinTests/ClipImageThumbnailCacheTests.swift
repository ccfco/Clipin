import AppKit
import XCTest
@testable import Clipin

final class ClipImageThumbnailCacheTests: XCTestCase {
    func testThumbnailGenerationCachesBoundedImage() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipinThumbnailTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let imageURL = root.appendingPathComponent("source.png")
        try makePNG(width: 120, height: 80).write(to: imageURL)

        let cache = ClipImageThumbnailCache(maxSize: 4, maxPixelSize: 32)
        let thumbnail = await cache.thumbnail(for: imageURL.path)

        XCTAssertNotNil(thumbnail)
        XCTAssertLessThanOrEqual(thumbnail?.width ?? 999, 32)
        XCTAssertLessThanOrEqual(thumbnail?.height ?? 999, 32)
        XCTAssertNotNil(cache.cachedThumbnail(for: imageURL.path))
    }

    private func makePNG(width: Int, height: Int) throws -> Data {
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return png
    }
}
