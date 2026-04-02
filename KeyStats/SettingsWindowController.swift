import Cocoa

final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        let viewController = SettingsViewController()
        let window = NSWindow(contentViewController: viewController)
        window.styleMask = [.titled, .closable]
        window.title = NSLocalizedString("settings.windowTitle", comment: "")
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = true
        window.backgroundColor = .windowBackgroundColor
        window.setContentSize(NSSize(width: 520, height: 720))
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
        AppDelegate.trackPageView("settings")
    }
}
