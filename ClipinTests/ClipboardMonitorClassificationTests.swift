import XCTest
@testable import Clipin

/// 剪贴板「image vs file」分类判定测试。
/// 背景：Finder 复制文件/文件夹时，NSPasteboard 会附带该文件的图标/缩略图(image flavor)，
/// 旧逻辑「有 image flavor 就当图片」把 zip/文件夹/文档误判成 image。此处锁住正确判据。
final class ClipboardMonitorClassificationTests: XCTestCase {

    // MARK: shouldTreatAsImage —— 纯决策核心
    //
    // 不变量：手里有 image bytes 就倾向存 image（bytes 在 pasteboard 上不会失效）；
    // 仅当 file-url 里有「确定的非图片文件」(图标场景证据) 时才降级 file。

    /// 纯截图 / iPhone 隔空复制 image bytes：有图片数据、无非图片文件 file-url → 存 image。
    func testPureImageDataIsImage() {
        XCTAssertTrue(ClipboardMonitor.shouldTreatAsImage(
            hasImageData: true, hasNonImageFileURL: false))
    }

    /// Finder 复制 zip/文件夹/文档（含与图片混选）：file-url 里有确定的非图片文件
    /// → 必须存 file，不能被图标骗成 image，也不能丢掉文件集合里的非图片成员。
    func testNonImageFileURLForcesFile() {
        XCTAssertFalse(ClipboardMonitor.shouldTreatAsImage(
            hasImageData: true, hasNonImageFileURL: true))
    }

    /// 无图片数据 → 不可能是 image。
    func testNoImageDataIsNotImage() {
        XCTAssertFalse(ClipboardMonitor.shouldTreatAsImage(
            hasImageData: false, hasNonImageFileURL: false))
        XCTAssertFalse(ClipboardMonitor.shouldTreatAsImage(
            hasImageData: false, hasNonImageFileURL: true))
    }

    // MARK: isNonImageFileURL —— "file-url 指向确定的非图片文件"(图标场景证据)

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 文件夹：存在 + 无图片扩展名 → 是确定的非图片文件 → 强制 file。
    func testDirectoryIsNonImageFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertTrue(ClipboardMonitor.isNonImageFileURL(dir))
    }

    /// zip：存在 + 非图片扩展名 → 是确定的非图片文件 → 强制 file。
    func testZipIsNonImageFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let zip = dir.appendingPathComponent("archive.zip")
        try Data([0x50, 0x4B, 0x03, 0x04]).write(to: zip)
        XCTAssertTrue(ClipboardMonitor.isNonImageFileURL(zip))
    }

    /// 图片文件：存在 + 图片扩展名 → 不是「非图片」(隔空复制图片/复制图片文件场景) → 保留 image。
    func testImageFileIsNotNonImageFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("shot.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: png)
        XCTAssertFalse(ClipboardMonitor.isNonImageFileURL(png))
    }

    /// 关键回归：file-url 指向的文件已不存在（iPhone Handoff temp 图片被系统清理）
    /// → 无法判定 → 不算「确定的非图片文件」→ 保守存 image，不降级成失效的 file 引用。
    func testMissingFileIsNotNonImageFile() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("gone.heic")
        XCTAssertFalse(ClipboardMonitor.isNonImageFileURL(missing))
    }
}
