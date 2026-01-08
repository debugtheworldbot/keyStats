import Foundation
import Sparkle

/// Manages Sparkle update checks and lifecycle.
final class UpdateManager {
    static let shared = UpdateManager()

    private let updaterController: SPUStandardUpdaterController

    private init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    // MARK: - Updates

    func checkForUpdates() {
        if Thread.isMainThread {
            updaterController.checkForUpdates(nil)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.updaterController.checkForUpdates(nil)
            }
        }
    }
}
