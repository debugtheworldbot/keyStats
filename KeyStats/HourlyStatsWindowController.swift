import Cocoa

final class HourlyStatsWindowController: NSWindowController {
    static let shared = HourlyStatsWindowController()

    private init() {
        let controller = HourlyStatsViewController()
        let window = NSWindow(contentViewController: controller)
        window.title = NSLocalizedString("hourly.title", comment: "")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 760, height: 490))
        window.minSize = NSSize(width: 660, height: 440)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        (contentViewController as? HourlyStatsViewController)?.refresh()
        AppDelegate.trackPageView("hourly_stats")
    }
}
