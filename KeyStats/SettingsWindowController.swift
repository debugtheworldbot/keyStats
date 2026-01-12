import Cocoa

final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        let viewController = SettingsViewController()
        let window = NSWindow(contentViewController: viewController)
        window.styleMask = [.titled, .closable]
        window.title = NSLocalizedString("settings.windowTitle", comment: "")
        window.setContentSize(NSSize(width: 360, height: 320))
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
    }
}
