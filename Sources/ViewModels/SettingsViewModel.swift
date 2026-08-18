import Foundation
import Combine

final class SettingsViewModel: ObservableObject {
    @Published var settings: APISettings

    init() {
        settings = PersistenceManager.shared.loadSettings()
    }

    func save() {
        PersistenceManager.shared.saveSettings(settings)
    }
}