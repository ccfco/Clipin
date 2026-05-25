import XCTest
@testable import Clipin

final class ZipArchiverTests: XCTestCase {
    private var tempRoots: [URL] = []

    override func tearDown() {
        for root in tempRoots {
            try? FileManager.default.removeItem(at: root)
        }
        tempRoots.removeAll()
        super.tearDown()
    }

    /// 修 E 防回归：父 Task cancel 时 ZipArchiver 必须 terminate 外部 zip 进程，
    /// 而不是等它跑完。验证：cancel 后调用立即返回（< 1s），cancel 前后总时长
    /// 远小于把目录全部 zip 完所需的时间。
    ///
    /// 制造一个能让 /usr/bin/zip 跑足够长时间的输入：写一个 50MB 的随机文件，
    /// STORED 模式下虽然不压缩，但 zip 仍要读完整 50MB 写到 destination；
    /// 这给我们留出 cancel 窗口。
    func testZipCancellationTerminatesProcessQuickly() async throws {
        let root = try makeTempRoot()
        let sourceDir = root.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        // 50 MB 随机数据：zip -0 仍需读+写完整 50MB，给我们留 cancel 窗口
        // 用 SystemRandomNumberGenerator 避免 APFS clone 优化
        var bytes = Data(count: 50 * 1024 * 1024)
        bytes.withUnsafeMutableBytes { buf in
            _ = SecRandomCopyBytes(kSecRandomDefault, buf.count, buf.baseAddress!)
        }
        try bytes.write(to: sourceDir.appendingPathComponent("blob.bin"))

        let dest = root.appendingPathComponent("out.zip")

        let task = Task {
            try await ZipArchiver.zipDirectoryContents(at: sourceDir, to: dest)
        }
        // 极短延迟后 cancel——给 process.run() 一个机会真正启动
        try await Task.sleep(for: .milliseconds(30))
        let cancelStart = ContinuousClock.now
        task.cancel()

        // cancel 后 task 应该在 < 1 秒内返回（SIGTERM → process 退出 → continuation resume）
        // 如果没有 cancellationHandler，task 会等 zip 完整跑完（数秒）
        var threw = false
        do {
            try await task.value
        } catch {
            threw = true
        }
        let elapsed = cancelStart.duration(to: ContinuousClock.now)
        XCTAssertTrue(threw, "cancelled zip task must throw (cancelled or pipe error)")
        XCTAssertLessThan(
            elapsed, .seconds(1),
            "cancel must terminate zip process quickly, not wait for natural completion"
        )
    }

    // MARK: - Helpers

    private func makeTempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZipArchiverTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        tempRoots.append(root)
        return root
    }
}
