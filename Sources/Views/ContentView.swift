import SwiftUI

struct ContentView: View {
    @EnvironmentObject var chatVM: ChatViewModel

    var body: some View {
        NavigationStack {
            ChatView()
                .navigationDestination(for: AppRoute.self) { route in
                    switch route {
                    case .settings:
                        SettingsView()
                    case .models:
                        ModelManagementView()
                    }
                }
        }
        .tint(AppTheme.accent)
    }
}

enum AppRoute: Hashable {
    case settings
    case models
}