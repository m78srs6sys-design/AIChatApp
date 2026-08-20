import Foundation
import UIKit
import Darwin

/// 闪退日志记录：捕获未捕获 Objective-C 异常与致命信号，自动写入 Documents/CrashLogs/。
/// 信号/异常处理器中仅使用 async-signal-safe 的 POSIX write，避免在崩溃上下文中再触发新异常。
final class CrashLogger {
    static let shared = CrashLogger()

    /// 崩溃日志目录（Documents/CrashLogs/）
    static var logDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("CrashLogs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 所有崩溃日志文件（按修改时间倒序）
    static var logFiles: [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: logDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        return files
            .filter { $0.pathExtension == "log" }
            .sorted {
                let d0 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let d1 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return d0 > d1
            }
    }

    private init() {}

    /// 安装崩溃捕获（App 启动时调用一次）
    func install() {
        // 1. Objective-C 未捕获异常
        NSSetUncaughtExceptionHandler { exception in
            var symbols: [String] = exception.callStackSymbols
            if symbols.isEmpty { symbols = Thread.callStackSymbols }
            let lines = [
                "类型: 未捕获异常 \(exception.name.rawValue)",
                "原因: \(exception.reason ?? "无")",
                "",
                symbols.joined(separator: "\n")
            ]
            crashWriteSync(title: "未捕获异常", detail: lines.joined(separator: "\n"))
            _exit(1) // 立即退出，避免在异常上下文中继续执行触发二次崩溃
        }

        // 2. 致命信号（仅安装一次，防止重入）
        var action = sigaction()
        action.sa_flags = SA_SIGINFO
        action.__sigaction_u.__sa_handler = crashSignalHandler
        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGPIPE, SIGTRAP] {
            sigaction(sig, &action, nil)
        }
    }
}

// MARK: - Async-signal-safe writer

/// 在崩溃上下文中把日志写入文件。仅使用 POSIX open/write/close 与 time/localtime，
/// 避免 Foundation 的 DateFormatter / FileManager 等可能持锁的 API 在崩溃上下文中死锁。
private func crashWriteSync(title: String, detail: String) {
    var body = """
    ============================================
    iOS 闪退日志
    时间: \(crashTimestamp())
    类型: \(title)
    --------------------------------------------
    \(detail)
    ============================================
    """
    body += "\n"
    guard let data = body.data(using: .utf8) else { return }

    let filename = "crash_\(crashTimestampForFilename()).log"
    let path = CrashLogger.logDirectory.appendingPathComponent(filename).path

    let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    guard fd >= 0 else { return }
    data.withUnsafeBytes { raw in
        if let base = raw.baseAddress {
            _ = write(fd, base, raw.count)
        }
    }
    close(fd)
}

private func crashTimestamp() -> String {
    var t = time(nil)
    guard let tm = localtime(&t) else { return "unknown" }
    var buf = [CChar](repeating: 0, count: 64)
    strftime(&buf, buf.count, "%Y-%m-%d %H:%M:%S", tm)
    return String(cString: buf)
}

private func crashTimestampForFilename() -> String {
    var t = time(nil)
    guard let tm = localtime(&t) else { return "unknown" }
    var buf = [CChar](repeating: 0, count: 64)
    strftime(&buf, buf.count, "%Y%m%d_%H%M%S", tm)
    return String(cString: buf)
}

/// 信号处理器（sa_handler 签名）
private func crashSignalHandler(_ sig: Int32) {
    let name: String
    switch sig {
    case SIGABRT: name = "SIGABRT（程序中止）"
    case SIGSEGV: name = "SIGSEGV（非法内存访问）"
    case SIGBUS:  name = "SIGBUS（总线错误）"
    case SIGILL:  name = "SIGILL（非法指令）"
    case SIGFPE:  name = "SIGFPE（算术异常）"
    case SIGPIPE: name = "SIGPIPE（管道破裂）"
    case SIGTRAP: name = "SIGTRAP（断点陷阱）"
    default:      name = "Signal \(sig)"
    }
    crashWriteSync(title: "致命信号 \(name)",
                   detail: Thread.callStackSymbols.joined(separator: "\n"))
    // 恢复默认处理并重新触发信号，让系统生成标准崩溃报告
    signal(sig, SIG_DFL)
    raise(sig)
}
