import SwiftUI

@main
struct AIChatApp: App {
    /// 后台下载会话 / 后台生成任务续跑代理
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var chatVM = ChatViewModel()
    @StateObject private var settingsVM = SettingsViewModel()
    @StateObject private var modelManager = LocalModelManager.shared
    @StateObject private var store = ConversationStore.shared

    init() {
        // 安装闪退日志记录（自动存储到 Documents/CrashLogs/）
        CrashLogger.shared.install()
        // 强制深色主题
        UITabBar.appearance().scrollEdgeAppearance = UITabBarAppearance().alsoDark()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(chatVM)
                .environmentObject(settingsVM)
                .environmentObject(modelManager)
                .environmentObject(store)
                .preferredColorScheme(.dark)
        }
    }
}

extension UITabBarAppearance {
    func alsoDark() -> UITabBarAppearance {
        let app = UITabBarAppearance()
        app.configureWithOpaqueBackground()
        app.backgroundColor = UIColor(red: 0.05, green: 0.04, blue: 0.08, alpha: 1)
        return app
    }
}