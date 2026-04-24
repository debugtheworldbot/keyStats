import Cocoa
import CoreGraphics

struct AppIdentity: Equatable {
    let bundleId: String
    let displayName: String

    static let unknown = AppIdentity(bundleId: "unknown", displayName: "")
}

final class AppActivityTracker {
    static let shared = AppActivityTracker()

    private let lock = NSLock()
    private var frontmostIdentity = AppIdentity.unknown
    private var pidToBundleId: [pid_t: String] = [:]
    private var bundleIdToName: [String: String] = [:]

    private init() {
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
        if let event = event {
            let pidValue = event.getIntegerValueField(.eventSourceUnixProcessID)
            if pidValue > 0 {
                let pid = pid_t(pidValue)
                if let identity = identityForPID(pid) {
                    return identity
                }
            }
        }
        return currentFrontmostIdentity()
    }

    /// 直接基于 PID 查询（helper 路径只带 PID，无 CGEvent）。
    func appIdentity(forPID pid: pid_t) -> AppIdentity {
        if pid > 0, let identity = identityForPID(pid) {
            return identity
        }
        return currentFrontmostIdentity()
    }

    private func identityForPID(_ pid: pid_t) -> AppIdentity? {
        lock.lock()
        if let bundleId = pidToBundleId[pid] {
            let name = bundleIdToName[bundleId] ?? ""
            let identity = AppIdentity(bundleId: bundleId, displayName: name)
            lock.unlock()
            return identity
        }
        lock.unlock()

        guard let app = NSRunningApplication(processIdentifier: pid),
              let bundleId = app.bundleIdentifier else {
            return nil
        }
        let name = app.localizedName ?? ""

        lock.lock()
        pidToBundleId[pid] = bundleId
        if !name.isEmpty {
            bundleIdToName[bundleId] = name
        }
        let identity = AppIdentity(bundleId: bundleId, displayName: name)
        lock.unlock()
        return identity
    }

    private func currentFrontmostIdentity() -> AppIdentity {
        lock.lock()
        let identity = frontmostIdentity
        lock.unlock()
        return identity
    }

    @objc private func activeApplicationChanged(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }
        updateFrontmostApp(app)
    }

    private func updateFrontmostApp(_ app: NSRunningApplication?) {
        guard let app = app, let bundleId = app.bundleIdentifier else { return }
        let name = app.localizedName ?? ""
        lock.lock()
        frontmostIdentity = AppIdentity(bundleId: bundleId, displayName: name)
        if !name.isEmpty {
            bundleIdToName[bundleId] = name
        }
        lock.unlock()
    }
}
