import Foundation
import UIKit

/// 闪退日志记录：捕获未捕获 Objective-C 异常与致命信号，
/// 自动写入 Documents/CrashLogs/ 目录（随 App 自动存储，可在系统「文件」或设置页查看/导出）。
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
            let stack = exception.callStackSymbols.joined(separator: "\n")
            let reason = exception.reason ?? ""
            let name = exception.name.rawValue
            let detail = """
            异常名称: \(name)
            异常原因: \(reason)

            \(stack)
            """
            CrashLogger.writeLog(title: "未捕获异常", detail: detail)
        }

        // 2. 致命信号
        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGPIPE, SIGTRAP] {
            signal(sig, crashSignalHandler)
        }
    }
}

/// 生成崩溃日志内容
private func buildCrashLog(title: String, detail: String) -> String {
    let device = UIDevice.current
    let appName = Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String
        ?? Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "AIChatApp"
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
    return """
    ============================================
    iOS 闪退日志
    时间: \(Date())
    设备: \(device.model) / \(device.systemName) \(device.systemVersion)
    App: \(appName) v\(version) (build \(build))
    类型: \(title)
    --------------------------------------------
    \(detail)
    ============================================
    """
}

/// 写入一条崩溃日志（文件名为 crash_时间戳.log）
private func writeCrashLogFile(_ content: String) {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd_HHmmss"
    let filename = "crash_\(formatter.string(from: Date())).log"
    let path = CrashLogger.logDirectory.appendingPathComponent(filename)
    if let data = content.data(using: .utf8) {
        try? data.write(to: path)
    }
}

extension CrashLogger {
    /// 供异常 / 信号处理器调用：组装并落盘（信号处理器中尽量少做非安全调用，
    /// 这里仅使用 Foundation 基础 API，主流崩溃收集方案均采用此做法）
    static func writeLog(title: String, detail: String) {
        writeCrashLogFile(buildCrashLog(title: title, detail: detail))
    }
}

/// 信号处理器（C 函数指针签名）
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
    CrashLogger.writeLog(title: "致命信号 \(name)",
                         detail: Thread.callStackSymbols.joined(separator: "\n"))
    // 恢复默认处理，让系统走标准崩溃流程（日志已落盘）
    signal(sig, SIG_DFL)
    raise(sig)
}
