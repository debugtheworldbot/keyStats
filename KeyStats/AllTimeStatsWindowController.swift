import Cocoa

final class AllTimeStatsWindowController: NSWindowController {
    static let shared = AllTimeStatsWindowController()

    private init() {
        let viewController = AllTimeStatsViewController()
        let window = NSWindow(contentViewController: viewController)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = NSLocalizedString("allTimeStats.windowTitle", comment: "")
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = .windowBackgroundColor
        window.setContentSize(NSSize(width: 600, height: 750))
        window.minSize = NSSize(width: 500, height: 600)
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        guard let window = window else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        
        if let vc = contentViewController as? AllTimeStatsViewController {
            vc.refreshData()
            DispatchQueue.main.async {
                vc.scrollToTop()
            }
        }
    }
}
