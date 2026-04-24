import Foundation

/// MVP 版本：
/// - 从主 app Resources 里找 KeyStatsHelper.app 并拷到 Application Support
/// - 写入 LaunchAgent plist 并 bootstrap
/// - 跳过 manifest / cdhash 校验（后续引入）
final class HelperSupervisor {
    static let shared = HelperSupervisor()
    private init() {}

    enum SupervisorError: Error {
        case missingBundledHelper
        case copyFailed(Error)
        case plistWriteFailed(Error)
        case launchctlFailed(Int32, String)
    }

    func ensureInstalled() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: HelperLocations.installDir, withIntermediateDirectories: true)

        guard let bundledHelper = bundledHelperURL() else {
            throw SupervisorError.missingBundledHelper
        }

        let target = HelperLocations.installedHelperURL

        let shouldCopy: Bool = {
            guard fm.fileExists(atPath: target.path) else { return true }
            let bundledMTime = (try? bundledHelper.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let targetMTime = (try? target.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return bundledMTime > targetMTime
        }()

        if shouldCopy {
            do {
                if fm.fileExists(atPath: target.path) {
                    try fm.removeItem(at: target)
                }
                try fm.copyItem(at: bundledHelper, to: target)
                stripQuarantine(at: target)
            } catch {
                throw SupervisorError.copyFailed(error)
            }
        }

        try ensureLaunchAgentRegistered()
    }

    func uninstall() throws {
        try? unregisterLaunchAgent()
        let fm = FileManager.default
        if fm.fileExists(atPath: HelperLocations.installedHelperURL.path) {
            try fm.removeItem(at: HelperLocations.installedHelperURL)
        }
    }

    // MARK: - LaunchAgent

    private func ensureLaunchAgentRegistered() throws {
        try writeLaunchAgentPlist()
        try bootstrapLaunchAgent()
    }

    private func unregisterLaunchAgent() throws {
        try bootoutLaunchAgent()
        try? FileManager.default.removeItem(at: HelperLocations.launchAgentPlistURL)
    }

    private func writeLaunchAgentPlist() throws {
        let binary = HelperLocations.installedHelperBinaryURL.path
        let plist: [String: Any] = [
            "Label": HelperLocations.launchAgentLabel,
            "ProgramArguments": [binary],
            "MachServices": [HelperLocations.machServiceName: true],
            "LimitLoadToSessionType": ["Aqua"],
            "ProcessType": "Interactive"
        ]
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            let url = HelperLocations.launchAgentPlistURL
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            throw SupervisorError.plistWriteFailed(error)
        }
    }

    private func bootstrapLaunchAgent() throws {
        _ = runLaunchctl(["bootout", "gui/\(getuid())/\(HelperLocations.launchAgentLabel)"])
        let res = runLaunchctl(["bootstrap", "gui/\(getuid())", HelperLocations.launchAgentPlistURL.path])
        if res.status != 0 {
            throw SupervisorError.launchctlFailed(res.status, res.stderr)
        }
    }

    private func bootoutLaunchAgent() throws {
        let res = runLaunchctl(["bootout", "gui/\(getuid())/\(HelperLocations.launchAgentLabel)"])
        if res.status != 0 && !res.stderr.contains("No such process") && !res.stderr.contains("Could not find") {
            throw SupervisorError.launchctlFailed(res.status, res.stderr)
        }
    }

    // MARK: - Helpers

    private func bundledHelperURL() -> URL? {
        let fm = FileManager.default
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/KeyStatsHelper.app"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LoginItems/KeyStatsHelper.app"),
        ]
        for c in candidates where fm.fileExists(atPath: c.path) {
            return c
        }
        return nil
    }

    private func stripQuarantine(at url: URL) {
        let p = Process()
        p.launchPath = "/usr/bin/xattr"
        p.arguments = ["-rd", "com.apple.quarantine", url.path]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
    }

    private func runLaunchctl(_ args: [String]) -> (status: Int32, stderr: String) {
        let p = Process()
        p.launchPath = "/bin/launchctl"
        p.arguments = args
        let err = Pipe()
        p.standardError = err
        p.standardOutput = Pipe()
        do { try p.run() } catch {
            return (-1, "\(error)")
        }
        p.waitUntilExit()
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (p.terminationStatus, stderr)
    }
}
