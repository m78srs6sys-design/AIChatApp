import SwiftUI
import UIKit

/// 后台下载会话回调代理：
/// URLSession 后台下载在 App 被系统挂起/重启后，系统会把事件重新交回 App，
/// 必须由 AppDelegate 实现 handleEventsForBackgroundURLSession，
/// 否则后台会话任务会一直挂起、下载「卡住不动」。
/// 同时在这里延长后台执行时间，保证所有离线/联网生成任务在切后台后继续跑。
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        // 透传给模型下载管理器（它负责喂给对应 URLSession 并最终调用 completionHandler）
        LocalModelManager.shared.handleBackgroundEvents(identifier: identifier, completion: completionHandler)
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // 进入后台时不做任何「停止生成」动作；生成任务通过 beginBackgroundTask 自动续跑
    }

    func applicationWillTerminate(_ application: UIApplication) {
        // 终止前落盘，避免丢失数据
        ConversationStore.shared.persist()
    }
}