import Foundation
import Combine

final class SettingsViewModel: ObservableObject {
    @Published var settings: APISettings

    init() {
        // 优先从 iCloud 读取（重装后自动恢复），回退本机
        settings = ICloudSettingsStore.load() ?? APISettings()
    }

    func save() {
        // 同时写入 iCloud 与本机
        ICloudSettingsStore.save(settings)
    }
}
