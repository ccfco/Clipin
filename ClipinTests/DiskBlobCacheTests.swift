import XCTest
@testable import Clipin

final class DiskBlobCacheTests: XCTestCase {
    // 独立测试子目录，避免碰生产截图/favicon 缓存。
    private let subdir = "Clipin/test-blobs"
    private var dir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(subdir, isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func writeBlob(_ data: Data, name: String, modified: Date? = nil) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(name).appendingPathExtension("png")
        try? data.write(to: file)
        if let modified {
            try? FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
        }
    }

    func testReadReturnsFreshBlob() async {
        let cache = DiskBlobCache(subdir: subdir, ttl: 3600, nameFor: { $0 })
        let payload = Data([0x01, 0x02, 0x03])
        writeBlob(payload, name: "key1")
        let read = await cache.read("key1")
        XCTAssertEqual(read, payload)
    }

    /// 超 TTL 的文件按未命中处理（read 不返回过期内容）。
    func testReadSkipsExpiredBlob() async {
        let cache = DiskBlobCache(subdir: subdir, ttl: 3600, nameFor: { $0 })
        writeBlob(Data([0x09]), name: "key2", modified: Date(timeIntervalSinceNow: -7200))
        let read = await cache.read("key2")
        XCTAssertNil(read)
    }

    func testReadMissReturnsNil() async {
        let cache = DiskBlobCache(subdir: subdir, ttl: 3600, nameFor: { $0 })
        let read = await cache.read("never-written")
        XCTAssertNil(read)
    }

    /// nameFor 决定文件名：不同 key 经映射落到同一文件名时应读到同一内容。
    func testNameForMapsKeyToFile() async {
        let cache = DiskBlobCache(subdir: subdir, ttl: 3600, nameFor: { String($0.reversed()) })
        let payload = Data([0xAB])
        writeBlob(payload, name: "cba")  // "abc".reversed() == "cba"
        let read = await cache.read("abc")
        XCTAssertEqual(read, payload)
    }
}
