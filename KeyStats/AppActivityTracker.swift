import Cocoa
import CoreGraphics

final class AppActivityTracker {
    static let shared = AppActivityTracker()

    private let cache: AppIdentityCache

    private init() {
        let queue = DispatchQueue(label: "com.keystats.app-activity-resolver", qos: .utility)
        self.cache = AppIdentityCache(
            resolver: { pid in
                guard let app = NSRunningApplication(processIdentifier: pid),
                      let bundleId = app.bundleIdentifier else {
                    return nil
                }
                return (bundleId: bundleId, name: app.localizedName ?? "")
            },
            dispatcher: QueueAppIdentityDispatcher(queue: queue)
        )
        let workspace = NSWorkspace.shared
        updateFrontmostApp(workspace.frontmostApplication)
        workspace.notificationCenter.addObserver(
            self,
            selector: #selector(activeApplicationChanged(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: workspace
        )
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func appIdentity(for event: CGEvent?) -> AppIdentity {
        let pid: pid_t? = event.map { pid_t($0.getIntegerValueField(.eventSourceUnixProcessID)) }
        return cache.identity(forPID: pid)
    }

    @objc private func activeApplicationChanged(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }
        updateFrontmostApp(app)
    }

    private func updateFrontmostApp(_ app: NSRunningApplication?) {
        guard let app = app, let bundleId = app.bundleIdentifier else { return }
        cache.updateFrontmost(
            bundleId: bundleId,
            name: app.localizedName ?? "",
            pid: app.processIdentifier
        )
    }
}
