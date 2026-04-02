import Cocoa

final class MouseDistanceCalibrationWindowController: NSWindowController {
    static let shared = MouseDistanceCalibrationWindowController()

    private let calibrationViewController = MouseDistanceCalibrationViewController()

    private init() {
        let window = NSWindow(contentViewController: calibrationViewController)
        window.styleMask = [.titled, .closable]
        window.title = NSLocalizedString("settings.mouseDistanceCalibration.windowTitle", comment: "")
        window.setContentSize(NSSize(width: 360, height: 240))
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        calibrationViewController.prepareForDisplay()
        guard let window = window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        AppDelegate.trackPageView("mouse_calibration")
    }
}
