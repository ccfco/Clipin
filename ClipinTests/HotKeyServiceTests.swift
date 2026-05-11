import Carbon.HIToolbox
import XCTest
@testable import Clipin

final class HotKeyServiceTests: XCTestCase {
    func testFailedRegistrationKeepsExistingHotKeyActive() {
        let backend = FakeHotKeyBackend()
        let service = HotKeyService(id: 1, backend: backend)

        XCTAssertEqual(service.start(with: .default), .registered)
        XCTAssertEqual(backend.tokens.count, 1)

        let replacement = HotKeyShortcut(
            keyCode: UInt32(kVK_ANSI_B),
            modifierFlagsRaw: NSEvent.ModifierFlags.command.union(.shift).rawValue,
            key: "B"
        )
        let conflictStatus = OSStatus(eventHotKeyExistsErr)
        backend.nextRegistrationStatus = .failure(conflictStatus)

        XCTAssertEqual(service.start(with: replacement), .failed(conflictStatus))
        XCTAssertEqual(service.activeShortcut, .default)
        XCTAssertFalse(backend.tokens[0].isUnregistered)
    }

    func testSuccessfulRegistrationReplacesOldHotKeyAfterNewOneRegisters() {
        let backend = FakeHotKeyBackend()
        let service = HotKeyService(id: 1, backend: backend)
        let replacement = HotKeyShortcut(
            keyCode: UInt32(kVK_ANSI_B),
            modifierFlagsRaw: NSEvent.ModifierFlags.command.union(.shift).rawValue,
            key: "B"
        )

        XCTAssertEqual(service.start(with: .default), .registered)
        XCTAssertEqual(service.start(with: replacement), .registered)

        XCTAssertEqual(service.activeShortcut, replacement)
        XCTAssertTrue(backend.tokens[0].isUnregistered)
        XCTAssertFalse(backend.tokens[1].isUnregistered)
    }

    func testHotKeyListenerIgnoresInactiveRegistrationIDs() {
        let backend = FakeHotKeyBackend()
        let service = HotKeyService(id: 7, backend: backend)
        var fireCount = 0
        service.onToggle = { fireCount += 1 }

        XCTAssertEqual(service.start(with: .default), .registered)
        let activeID = backend.registeredIDs[0]

        backend.listener?.fire(id: activeID + 1)
        XCTAssertEqual(fireCount, 0)

        backend.listener?.fire(id: activeID)
        XCTAssertEqual(fireCount, 1)
    }
}

private final class FakeHotKeyBackend: HotKeyBackend {
    var nextRegistrationStatus: HotKeyBackendRegistrationResult = .registered(FakeHotKeyToken())
    private(set) var tokens: [FakeHotKeyToken] = []
    private(set) var registeredIDs: [UInt32] = []
    private(set) var listener: FakeHotKeyListener?

    func startListening(onFire: @escaping (UInt32) -> Void) -> HotKeyBackendListenerResult {
        let listener = FakeHotKeyListener(onFire: onFire)
        self.listener = listener
        return .listening(listener)
    }

    func register(shortcut: HotKeyShortcut, signature: OSType, id: UInt32) -> HotKeyBackendRegistrationResult {
        registeredIDs.append(id)
        switch nextRegistrationStatus {
        case .registered:
            let token = FakeHotKeyToken()
            tokens.append(token)
            return .registered(token)
        case let .failure(status):
            return .failure(status)
        }
    }
}

private final class FakeHotKeyToken: HotKeyRegistration {
    private(set) var isUnregistered = false

    func unregister() {
        isUnregistered = true
    }
}

private final class FakeHotKeyListener: HotKeyEventListener {
    private let onFire: (UInt32) -> Void
    private(set) var isStopped = false

    init(onFire: @escaping (UInt32) -> Void) {
        self.onFire = onFire
    }

    func fire(id: UInt32) {
        onFire(id)
    }

    func stop() {
        isStopped = true
    }
}
