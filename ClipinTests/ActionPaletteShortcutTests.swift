import AppKit
import XCTest
@testable import Clipin

@MainActor
final class ActionPaletteShortcutTests: XCTestCase {
    private var tempRoots: [URL] = []

    override func tearDown() {
        for root in tempRoots {
            try? FileManager.default.removeItem(at: root)
        }
        tempRoots.removeAll()
        super.tearDown()
    }

    func testPaletteShortcutExecutesMatchingVisibleAction() throws {
        let core = try makeCore()
        let item = try core.saveItem(
            content: "copy me",
            clipType: .text,
            sourceApp: nil,
            sourceName: nil,
            imagePath: nil
        )
        let viewModel = ClipboardViewModel(core: core)
        var copiedID: String?
        viewModel.onCopyRequested = { copiedID = $0.id }

        viewModel.loadItems(selectLatest: true)
        viewModel.showActionsPalette()

        XCTAssertTrue(viewModel.executePaletteShortcut(.copy))
        XCTAssertEqual(copiedID, item.id)
        XCTAssertFalse(viewModel.isShowingActions)
    }

    func testPaletteShortcutIgnoresHiddenAction() throws {
        let core = try makeCore()
        let viewModel = ClipboardViewModel(core: core)
        var copiedID: String?
        viewModel.onCopyRequested = { copiedID = $0.id }

        viewModel.loadItems()
        viewModel.showActionsPalette()

        XCTAssertTrue(viewModel.isShowingActions)
        XCTAssertFalse(viewModel.executePaletteShortcut(.copy))
        XCTAssertNil(copiedID)
        XCTAssertTrue(viewModel.isShowingActions)
    }

    func testPaletteShortcutMatchesDisplayedKeyEquivalent() {
        XCTAssertEqual(PaletteActionShortcut.matching(keyCode: 0x08, flags: .command), .copy)
        XCTAssertEqual(PaletteActionShortcut.matching(keyCode: 0x1F, flags: .command), .open)
        XCTAssertEqual(PaletteActionShortcut.matching(keyCode: 0x31, flags: []), .preview)
        XCTAssertEqual(PaletteActionShortcut.matching(keyCode: 0x24, flags: .shift), .pastePlain)
        XCTAssertEqual(PaletteActionShortcut.matching(keyCode: 0x33, flags: .command), .delete)
    }

    func testCommandDeleteInTextInputIsPreservedForTextEditing() {
        XCTAssertTrue(LauncherKeyRouting.shouldPreserveTextEditing(
            keyCode: 0x33,
            flags: .command,
            firstResponderIsTextView: true
        ))
        XCTAssertFalse(LauncherKeyRouting.shouldPreserveTextEditing(
            keyCode: 0x33,
            flags: .command,
            firstResponderIsTextView: false
        ))
        XCTAssertFalse(LauncherKeyRouting.shouldPreserveTextEditing(
            keyCode: 0x33,
            flags: [],
            firstResponderIsTextView: true
        ))
    }

    func testTypingCharacterAcceptsPrintableInput() {
        XCTAssertTrue(LauncherKeyRouting.isTypingCharacter("a"))
        XCTAssertTrue(LauncherKeyRouting.isTypingCharacter("Z"))
        XCTAssertTrue(LauncherKeyRouting.isTypingCharacter("7"))
        XCTAssertTrue(LauncherKeyRouting.isTypingCharacter("中"))
        XCTAssertTrue(LauncherKeyRouting.isTypingCharacter(" "))   // 空格是可打印字符
        XCTAssertTrue(LauncherKeyRouting.isTypingCharacter("?"))
    }

    func testTypingCharacterRejectsControlAndFunctionKeys() {
        XCTAssertFalse(LauncherKeyRouting.isTypingCharacter(nil))
        XCTAssertFalse(LauncherKeyRouting.isTypingCharacter(""))
        XCTAssertFalse(LauncherKeyRouting.isTypingCharacter("\u{7f}"))   // 退格 DEL —— 回归用例：曾被误判为打字
        XCTAssertFalse(LauncherKeyRouting.isTypingCharacter("\u{1b}"))   // Esc
        XCTAssertFalse(LauncherKeyRouting.isTypingCharacter("\t"))       // Tab
        XCTAssertFalse(LauncherKeyRouting.isTypingCharacter("\r"))       // Return
        XCTAssertFalse(LauncherKeyRouting.isTypingCharacter("\u{F704}")) // NSF1FunctionKey
        XCTAssertFalse(LauncherKeyRouting.isTypingCharacter("\u{F700}")) // NSUpArrowFunctionKey
    }

    private func makeCore() throws -> ClipinCore {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipinActionPaletteTests-\(UUID().uuidString)", isDirectory: true)
        let imageURL = rootURL.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: imageURL, withIntermediateDirectories: true)
        tempRoots.append(rootURL)

        return try ClipinCore(
            dbPath: rootURL.appendingPathComponent("test.db").path,
            imageDir: imageURL.path
        )
    }
}
