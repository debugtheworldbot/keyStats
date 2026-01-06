import Foundation
import ServiceManagement

final class LaunchAtLoginManager {
    static let shared = LaunchAtLoginManager()

    private init() {}

    var isEnabled: Bool {
        return SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
