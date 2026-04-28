import Foundation
import Security

/// - 从主 app Resources 里找 KeyStatsHelper.app 并拷到 Application Support
/// - 按 cdhash 判断是否需要覆盖（cdhash 稳定 ⇒ TCC 授权跨升级保留的前提）
/// - 写入 LaunchAgent plist 并 bootstrap
final class HelperSupervisor {
    static let shared = HelperSupervisor()
    private init() {}

    enum SupervisorError: Error {
        case missingBundledHelper
        case copyFailed(Error)
        case plistWriteFailed(Error)
        case launchctlFailed(Int32, String)
        case cdhashUnavailable(OSStatus)
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
            // 关键：用 cdhash 判定，保持 TCC 授权稳定。文件系统上随便碰到的
            // mtime 变化（rsync、备份还原）不应触发重装。
            guard let bundledHash = try? readCDHash(at: bundledHelper),
                  let installedHash = try? readCDHash(at: target) else {
                return true
            }
            return bundledHash != installedHash
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

        try ensureLaunchAgentRegistered(helperWasCopied: shouldCopy)
    }

    // MARK: - LaunchAgent

    private func ensureLaunchAgentRegistered(helperWasCopied: Bool) throws {
        let plistChanged = try writeLaunchAgentPlist()
        guard helperWasCopied || plistChanged || !isLaunchAgentLoaded() else {
            return
        }
        try bootstrapLaunchAgent(restartExisting: helperWasCopied || plistChanged)
    }

    @discardableResult
    private func writeLaunchAgentPlist() throws -> Bool {
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
            if let existingData = try? Data(contentsOf: url),
               let existingPlist = try? PropertyListSerialization.propertyList(
                   from: existingData,
                   options: [],
                   format: nil
               ) as? NSDictionary,
               existingPlist.isEqual(plist as NSDictionary) {
                return false
            }
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            throw SupervisorError.plistWriteFailed(error)
        }
    }

    private func bootstrapLaunchAgent(restartExisting: Bool) throws {
        if restartExisting {
            _ = runLaunchctl(["bootout", "gui/\(getuid())/\(HelperLocations.launchAgentLabel)"])
        }
        let res = runLaunchctl(["bootstrap", "gui/\(getuid())", HelperLocations.launchAgentPlistURL.path])
        if res.status != 0 {
            if isLaunchAgentLoaded() {
                return
            }
            throw SupervisorError.launchctlFailed(res.status, res.stderr)
        }
    }

    private func isLaunchAgentLoaded() -> Bool {
        let res = runLaunchctl(["print", "gui/\(getuid())/\(HelperLocations.launchAgentLabel)"])
        return res.status == 0
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

    /// 读 .app bundle 的 CDHash，返回 hex 字符串（对应 codesign -dvvv 的 CDHash）。
    private func readCDHash(at url: URL) throws -> String {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode)
        guard createStatus == errSecSuccess, let staticCode = staticCode else {
            throw SupervisorError.cdhashUnavailable(createStatus)
        }
        var info: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: UInt32(kSecCSSigningInformation)),
            &info
        )
        guard infoStatus == errSecSuccess,
              let d = info as? [String: Any],
              let hashes = d["cdhashes"] as? [Data],
              let primary = hashes.first else {
            throw SupervisorError.cdhashUnavailable(infoStatus)
        }
        return primary.map { String(format: "%02x", $0) }.joined()
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
