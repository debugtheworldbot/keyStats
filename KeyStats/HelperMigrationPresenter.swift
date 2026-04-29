import AppKit
import Foundation

/// 一次性引导老用户清理旧的 "KeyStats" accessibility 授权条目，并授权新的 "KeyStatsHelper"。
/// Why: accessibility 采集已迁移到辅助进程，旧条目不会自动消失，需要用户侧手工 / tccutil 清理一次。
@MainActor
final class HelperMigrationPresenter {
    static let shared = HelperMigrationPresenter()

    private static let shownDefaultsKey = "KeyStats.HelperMigrationShown"
    private static let legacyBundleID = "com.keystats.app"

    private init() {}

    func showIfNeeded(wasPreviouslyInstalled: Bool) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.shownDefaultsKey) else { return }
        // 立即置 true，防止任何路径再次触发（例如 alert 打开系统设置后 re-activate）
        defaults.set(true, forKey: Self.shownDefaultsKey)

        // Fresh install 没有任何旧 "KeyStats" TCC 条目可清理，再展示
        // "we cleared the old entry / last manual authorization" 文案会误导用户。
        // 常规权限 alert 会照常引导用户授权 KeyStatsHelper，无需此迁移引导。
        guard wasPreviouslyInstalled else { return }

        let resetStatus = Self.runTCCReset()
        let resetSucceeded = (resetStatus == 0)

        AppDelegate.trackEvent("helper_migration_prompt_shown", properties: [
            "tcc_reset_status": Int(resetStatus)
        ])

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = NSLocalizedString("helperMigration.title", comment: "")

        let body = NSLocalizedString("helperMigration.body", comment: "")
        let followUpKey = resetSucceeded
            ? "helperMigration.autoReset.success"
            : "helperMigration.autoReset.manual"
        let followUp = NSLocalizedString(followUpKey, comment: "")
        alert.informativeText = [body, followUp]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")

        alert.addButton(withTitle: NSLocalizedString("helperMigration.openSettings", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("helperMigration.later", comment: ""))

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            AppDelegate.trackClick("helper_migration_open_settings")
            DispatchQueue.main.async { [weak self] in
                guard self != nil else { return }
                AppDelegate.shared?.requestAccessibilityPermission(analyticsSource: "migration_dialog")
            }
        } else {
            AppDelegate.trackClick("helper_migration_later")
        }
    }

    /// 同步执行 `tccutil reset Accessibility com.keystats.app`。返回子进程退出码；
    /// 若启动失败返回 -1。以当前用户身份运行，不需要 sudo。
    private static func runTCCReset() -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "Accessibility", legacyBundleID]
        // 丢弃 stdout/stderr，避免 tccutil 的输出污染 app console
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}
