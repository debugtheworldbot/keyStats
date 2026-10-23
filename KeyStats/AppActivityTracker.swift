import Cocoa

struct AppIdentity: Equatable {
    let bundleId: String
    let displayName: String
}

/// Classifies apps for per-app presentation without modifying saved history.
final class AppActivityTracker {
    static let shared = AppActivityTracker()

    private init() {}

    func isUserFacing(bundleID: String) -> Bool {
        guard !bundleID.isEmpty, bundleID != "unknown" else { return false }

        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        if !running.isEmpty {
            return running.contains { $0.activationPolicy == .regular }
        }

        // Launch Services can classify an app after its process has exited.
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
           Self.isBackgroundOnlyBundle(at: url) {
            return false
        }

        // Preserve historical rows for uninstalled apps when eligibility is unknown.
        return true
    }

    static func isBackgroundOnlyBundle(at url: URL) -> Bool {
        guard let info = Bundle(url: url)?.infoDictionary else { return false }
        return (info["LSUIElement"] as? Bool ?? false) ||
            (info["LSBackgroundOnly"] as? Bool ?? false)
    }
}
