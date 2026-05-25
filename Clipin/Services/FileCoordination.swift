import Foundation

/// `NSFileCoordinator` 的 throwing 封装，专门用于 iCloud Drive 容器下的读写协调。
///
/// 为什么必须用 `NSFileCoordinator` 而不是 `Data.write(.atomic)`：
/// 本地 APFS 上 atomic rename 是真原子，但 iCloud Drive 文件夹由 user-space daemon
/// 监视，daemon 可能在 atomic rename 的中间状态被触发——产生 `clipin-backup 2.clipin.zip`
/// 这类 conflict 文件。`NSFileCoordinator` 是 Apple 文档里写 iCloud Drive 时的契约：
/// 让协调子系统在我们持有文件期间挂起 daemon 的 upload trigger，写完再放行。
///
/// 我们是单向写入方（没人监听我们写的备份文件），所以 `filePresenter: nil`。
/// 如果将来要在多 Clipin 进程间协调（不太可能），再实现 NSFilePresenter。
enum FileCoordination {
    enum CoordinationError: LocalizedError {
        case coordinatorReturnedError(NSError)

        var errorDescription: String? {
            switch self {
            case .coordinatorReturnedError(let err):
                return err.localizedDescription
            }
        }
    }

    /// 协调式写入。`perform` 收到 coordinator 给出的写入 URL（通常等于传入的 url，
    /// 但 coordinator 保留替换路径的权利，必须用回调里这个 URL）。
    /// `perform` 抛出的错误会原样向外传播。
    static func coordinatedWrite(
        to url: URL,
        options: NSFileCoordinator.WritingOptions = .forReplacing,
        perform: (URL) throws -> Void
    ) throws {
        var coordError: NSError?
        var thrown: Error?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(writingItemAt: url, options: options, error: &coordError) { writeURL in
            do {
                try perform(writeURL)
            } catch {
                thrown = error
            }
        }
        if let e = thrown { throw e }
        if let e = coordError { throw CoordinationError.coordinatorReturnedError(e) }
    }

    /// 协调式读取。同上，`perform` 收到 coordinator 给出的读取 URL。
    static func coordinatedRead(
        at url: URL,
        options: NSFileCoordinator.ReadingOptions = [],
        perform: (URL) throws -> Void
    ) throws {
        var coordError: NSError?
        var thrown: Error?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(readingItemAt: url, options: options, error: &coordError) { readURL in
            do {
                try perform(readURL)
            } catch {
                thrown = error
            }
        }
        if let e = thrown { throw e }
        if let e = coordError { throw CoordinationError.coordinatorReturnedError(e) }
    }
}
