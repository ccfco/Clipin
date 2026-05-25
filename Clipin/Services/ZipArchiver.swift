import Foundation

/// 调用 macOS 系统二进制 `/usr/bin/zip` / `/usr/bin/unzip` 完成归档读写。
///
/// 为什么走 Process 而不是引第三方 Swift 库：
/// - Swift 端坚持「全 Apple、零 SPM 依赖」（CLAUDE.md：架构纯净度）
/// - macOS 没有公开的 Swift zip API（AppleArchive 主格式是 .aar，写 zip 兼容流程较底层）
/// - `/usr/bin/zip` 是 Apple 修订过的 Info-ZIP，与 NSWorkspace / Vision 同属"系统服务"，
///   调用它不构成第三方依赖
///
/// 为什么用 STORED 而非 DEFLATE：归档体积主要是图片（PNG，已 deflate），manifest.json
/// 也只有几 KB。再压一遍 PNG 不会变小、CPU 白烧；STORED 让 zip 文件大小≈源文件大小总和，
/// 跨设备同步流量与"未压缩文件夹"等价，但获得了原子单文件和分享友好。
///
/// 为什么 async：自动备份大库（100MB+）会让 `/usr/bin/zip` 跑数秒。同步 `waitUntilExit()`
/// 一旦启动就拦不住——AutoBackupService.reconfigure 切换路径时旧 Task 被 cancel 但外部
/// 进程仍占 IO/CPU 到自然结束。改 async + `withTaskCancellationHandler`：cancel 时
/// `process.terminate()` 立即送 SIGTERM，让 zip 进程在 ~ms 内退出。
enum ZipArchiver {
    enum ZipError: LocalizedError {
        case sourceNotFound(URL)
        case destinationAlreadyExists(URL)
        case binaryFailed(exitCode: Int32, stderr: String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .sourceNotFound(let url):
                return "Source not found: \(url.path)"
            case .destinationAlreadyExists(let url):
                return "Destination already exists: \(url.path)"
            case .binaryFailed(let code, let stderr):
                let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty
                    ? "Archive command failed (exit \(code))"
                    : "Archive command failed (exit \(code)): \(trimmed)"
            case .cancelled:
                return nil // 与 Swift 标准取消语义对齐，不展示给用户
            }
        }
    }

    /// 把 `sourceDir` 内**全部内容**（不含 sourceDir 自身名）打包成 `destinationZip`。
    /// destinationZip 必须**不存在**——`/usr/bin/zip` 默认会向已有 zip 追加而非覆盖，
    /// 调用方负责事先 rename 旧文件或写到 .tmp 路径再原子替换。
    static func zipDirectoryContents(at sourceDir: URL, to destinationZip: URL) async throws {
        guard FileManager.default.fileExists(atPath: sourceDir.path) else {
            throw ZipError.sourceNotFound(sourceDir)
        }
        guard !FileManager.default.fileExists(atPath: destinationZip.path) else {
            throw ZipError.destinationAlreadyExists(destinationZip)
        }

        // -0  STORED（不压缩）；图片已是 deflate，元数据 KB 级，再压无收益
        // -q  quiet（错误仍走 stderr）
        // -X  不保留 extra attributes，让 zip 输出 reproducible
        // -r  递归
        // 末尾的 "." 表示打包当前工作目录下全部内容；currentDirectoryURL 设为
        // sourceDir，避免 zip 把 sourceDir 这一层路径写进归档
        try await runProcess(
            launchPath: "/usr/bin/zip",
            arguments: ["-0", "-q", "-X", "-r", destinationZip.path, "."],
            currentDirectoryURL: sourceDir
        )
    }

    /// 把 zip 解到 `destinationDir`（必须已存在）。同名文件**覆盖**（`-o`）。
    static func unzipArchive(at zipURL: URL, to destinationDir: URL) async throws {
        guard FileManager.default.fileExists(atPath: zipURL.path) else {
            throw ZipError.sourceNotFound(zipURL)
        }

        try await runProcess(
            launchPath: "/usr/bin/unzip",
            arguments: ["-q", "-o", zipURL.path, "-d", destinationDir.path],
            currentDirectoryURL: nil
        )
    }

    // MARK: - Process

    private static func runProcess(
        launchPath: String,
        arguments: [String],
        currentDirectoryURL: URL?
    ) async throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launchPath)
        task.arguments = arguments
        if let cwd = currentDirectoryURL {
            task.currentDirectoryURL = cwd
        }

        let stderrPipe = Pipe()
        task.standardError = stderrPipe
        task.standardOutput = Pipe()

        // 上行 cancel 路径：withTaskCancellationHandler 的 onCancel 在父 Task cancel
        // 时立即同步执行——给 process 发 SIGTERM。Process 退出后 terminationHandler 触发
        // continuation.resume，整条 await 链返回 cancelled 错误。
        //
        // 没有用 isolated continuation：terminationHandler 在 Foundation 的后台队列回调，
        // 不能保证 actor 上下文；withCheckedThrowingContinuation 的语义本就支持跨线程
        // resume 一次，这里恰好对应 process 终止只触发一次的语义。
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                task.terminationHandler = { proc in
                    if proc.terminationStatus == 0 {
                        continuation.resume()
                        return
                    }
                    // SIGTERM 退出（signal=15）= 我们主动 terminate，作为 cancelled 上抛
                    // 不当成 binaryFailed 让用户看到红色错误
                    if proc.terminationReason == .uncaughtSignal {
                        continuation.resume(throwing: ZipError.cancelled)
                        return
                    }
                    let stderrData = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? nil
                    let stderr = stderrData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    continuation.resume(throwing: ZipError.binaryFailed(
                        exitCode: proc.terminationStatus,
                        stderr: stderr
                    ))
                }
                do {
                    try task.run()
                } catch {
                    // run 失败：terminationHandler 不会触发，直接 resume
                    task.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            // 父 Task cancel：terminate 是同步调用，发 SIGTERM 后立即返回。
            // process 实际退出由 terminationHandler 在后台异步通知 continuation
            if task.isRunning {
                task.terminate()
            }
        }
    }
}
