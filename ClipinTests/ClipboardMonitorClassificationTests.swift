import AppKit
import XCTest
@testable import Clipin

/// 剪贴板「image vs file」分类判定测试。
///
/// 根因：NSPasteboard 没有「图片 vs 文件」单一类型字段，分类要从 representation 推断。
/// 旧实现读扁平 `pasteboard.types`（把所有 item 拍平 + 系统合成幻影 type），Finder 复制
/// 文件/文件夹时附带的 com.apple.icns 图标(conforms public.image)把整条骗成 image。
/// 现在改读 per-item 结构 + 显式排除 com.apple.icns(图标专用格式)：文件夹/非图片文件在
/// 结构层就没有真实图片信号，无需回文件系统 stat 扩展名。
final class ClipboardMonitorClassificationTests: XCTestCase {

    // MARK: isRealImageType —— 单个 UTI 是否「真实图片内容」(排除图标/file-url)

    private func type(_ raw: String) -> NSPasteboard.PasteboardType {
        NSPasteboard.PasteboardType(raw)
    }

    func testRealImageTypesAreImage() {
        XCTAssertTrue(ClipboardMonitor.isRealImageType(type("public.png")))
        XCTAssertTrue(ClipboardMonitor.isRealImageType(type("public.jpeg")))
        XCTAssertTrue(ClipboardMonitor.isRealImageType(type("public.tiff")))
        XCTAssertTrue(ClipboardMonitor.isRealImageType(type("public.heic")))
    }

    /// 核心：com.apple.icns 是文件图标专用格式，conforms public.image 但不是图片内容，必须排除。
    /// 这是 Finder 复制文件夹/zip/文档被误判成图片的根因。
    func testIconFormatIsNotRealImage() {
        XCTAssertFalse(ClipboardMonitor.isRealImageType(type("com.apple.icns")))
    }

    func testFileURLAndTextAreNotRealImage() {
        XCTAssertFalse(ClipboardMonitor.isRealImageType(type("public.file-url")))
        XCTAssertFalse(ClipboardMonitor.isRealImageType(type("public.utf8-plain-text")))
    }

    // MARK: shouldTreatAsImage —— 基于 per-item 分类的纯决策
    //
    // 入参由 checkClipboard 从 pasteboardItems 派生：
    //   fileItemCount        含 file-url 的 item 数（= 文件集合大小）
    //   singleFileItemIsImage  恰好单个文件项 且 该 item 含真实图片(隔空复制图片/复制图片文件)
    //   hasPureImageItem     存在「无 file-url 但含真实图片」的 item（纯截图）

    /// Finder 复制文件夹/zip/文档：单个文件项，无真实图片(只有 icns 图标) → file。
    func testSingleNonImageFileIsFile() {
        XCTAssertFalse(ClipboardMonitor.shouldTreatAsImage(
            fileItemCount: 1, singleFileItemIsImage: false, hasPureImageItem: false))
    }

    /// 纯截图：无文件项，有纯图片项 → image。
    func testScreenshotIsImage() {
        XCTAssertTrue(ClipboardMonitor.shouldTreatAsImage(
            fileItemCount: 0, singleFileItemIsImage: false, hasPureImageItem: true))
    }

    /// iPhone 隔空复制图片：单文件项(file-url 指向会被清理的 temp) 且该 item 自带真实图片
    /// bytes → image，保住 temp 文件清理后仍可回放。(Finder 本地复制图片文件只挂 file-url、
    /// 无 image bytes，singleFileItemIsImage=false 走 file 分支，那是另一条正确路径。)
    func testHandoffImageIsImage() {
        XCTAssertTrue(ClipboardMonitor.shouldTreatAsImage(
            fileItemCount: 1, singleFileItemIsImage: true, hasPureImageItem: false))
    }

    /// Finder 多选(含图片)：多个文件项 → file，保留完整文件集合，不被其中的图片项升级成 image。
    func testMultiFileSelectionIsFile() {
        XCTAssertFalse(ClipboardMonitor.shouldTreatAsImage(
            fileItemCount: 2, singleFileItemIsImage: false, hasPureImageItem: true))
    }

    /// 无文件项也无图片项（纯文本/URL）→ 不是 image。
    func testNoImageNoFileIsNotImage() {
        XCTAssertFalse(ClipboardMonitor.shouldTreatAsImage(
            fileItemCount: 0, singleFileItemIsImage: false, hasPureImageItem: false))
    }
}
