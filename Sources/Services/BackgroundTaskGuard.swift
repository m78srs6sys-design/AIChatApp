import Foundation
import UIKit

/// 后台任务保护：为「联网/离线生成」申请系统后台执行时间。
/// App 切到后台后，系统默认会挂起进程，正在进行的网络流式请求或本地推理会被打断。
/// 通过 beginBackgroundTask 可以申请一段额外的后台执行时间（通常数分钟）：
/// - 联网模式：URLSession 流式请求在此期间继续接收 token；
/// - 离线模式：llama.cpp 本地推理继续运行；
/// 生成结束后必须调用 end 归还时间，避免被系统计入违规后台运行。
@MainActor
enum BackgroundTaskGuard {
    private static var counter = 0

    /// 申请后台执行时间，返回任务标识
    static func begin(name: String = "ai-generation") -> UIBackgroundTaskIdentifier {
        counter += 1
        return UIApplication.shared.beginBackgroundTask(withName: "\(name)-\(counter)") {
            // 到期回调（系统即将强制挂起）：什么都不做，任务自然暂停，
            // 下次回到前台时若仍在生成，会由调用方继续/结束。
        }
    }

    /// 归还后台执行时间
    static func end(_ task: UIBackgroundTaskIdentifier) {
        if task != .invalid {
            UIApplication.shared.endBackgroundTask(task)
        }
    }
}