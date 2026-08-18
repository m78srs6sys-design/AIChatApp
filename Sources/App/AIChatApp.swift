import SwiftUI

@main
struct AIChatApp: App {
    @StateObject private var chatVM = ChatViewModel()
    @StateObject private var settingsVM = SettingsViewModel()
    @StateObject private var modelManager = LocalModelManager()

    init() {
        // 强制深色主题
        UITabBar.appearance().scrollEdgeAppearance = UITabBarAppearance().alsoDark()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(chatVM)
                .environmentObject(settingsVM)
                .environmentObject(modelManager)
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