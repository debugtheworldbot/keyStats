import Cocoa

final class AppStatsWindowController: NSWindowController {
    static let shared = AppStatsWindowController()

    private init() {
        let viewController = AppStatsViewController()
        let window = NSWindow(contentViewController: viewController)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = NSLocalizedString("appStats.windowTitle", comment: "")
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = true
        window.backgroundColor = .windowBackgroundColor
        window.setContentSize(NSSize(width: 600, height: 680))
        window.minSize = NSSize(width: 520, height: 520)
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        guard let window = window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        AppDelegate.trackPageView("app_stats")

        if let vc = contentViewController as? AppStatsViewController {
            vc.refreshData()
        }
    }
}
