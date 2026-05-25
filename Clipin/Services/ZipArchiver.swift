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
enum ZipArchiver {
    enum ZipError: LocalizedError {
        case sourceNotFound(URL)
        case destinationAlreadyExists(URL)
        case binaryFailed(exitCode: Int32, stderr: String)

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
            }
        }
    }

    /// 把 `sourceDir` 内**全部内容**（不含 sourceDir 自身名）打包成 `destinationZip`。
    /// destinationZip 必须**不存在**——`/usr/bin/zip` 默认会向已有 zip 追加而非覆盖，
    /// 调用方负责事先 rename 旧文件或写到 .tmp 路径再原子替换。
    static func zipDirectoryContents(at sourceDir: URL, to destinationZip: URL) throws {
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
        try runProcess(
            launchPath: "/usr/bin/zip",
            arguments: ["-0", "-q", "-X", "-r", destinationZip.path, "."],
            currentDirectoryURL: sourceDir
        )
    }

    /// 把 zip 解到 `destinationDir`（必须已存在）。同名文件**覆盖**（`-o`）。
    static func unzipArchive(at zipURL: URL, to destinationDir: URL) throws {
        guard FileManager.default.fileExists(atPath: zipURL.path) else {
            throw ZipError.sourceNotFound(zipURL)
        }

        try runProcess(
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
    ) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launchPath)
        task.arguments = arguments
        if let cwd = currentDirectoryURL {
            task.currentDirectoryURL = cwd
        }

        let stderrPipe = Pipe()
        task.standardError = stderrPipe
        task.standardOutput = Pipe()

        try task.run()
        task.waitUntilExit()

        if task.terminationStatus != 0 {
            // readToEnd() -> Data?；try? 把它包成 Data??（外层 try 失败 / 内层 EOF）
            let stderrData = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? nil
            let stderr = stderrData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            throw ZipError.binaryFailed(exitCode: task.terminationStatus, stderr: stderr)
        }
    }
}
