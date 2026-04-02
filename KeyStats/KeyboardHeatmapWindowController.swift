import Cocoa

final class KeyboardHeatmapWindowController: NSWindowController {
    static let shared = KeyboardHeatmapWindowController()

    private init() {
        let viewController = KeyboardHeatmapViewController()
        let window = NSWindow(contentViewController: viewController)
        let fixedSize = NSSize(width: 860, height: 460)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.title = NSLocalizedString("keyboardHeatmap.windowTitle", comment: "")
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = true
        window.backgroundColor = .windowBackgroundColor
        window.setContentSize(fixedSize)
        window.minSize = fixedSize
        window.maxSize = fixedSize
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        guard let window = window else { return }
        let wasVisible = window.isVisible
        let wasMiniaturized = window.isMiniaturized
        NSApp.activate(ignoringOtherApps: true)
        if wasMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()

        if let vc = contentViewController as? KeyboardHeatmapViewController {
            if wasVisible || wasMiniaturized {
                vc.refreshData()
            } else {
                vc.resetToTodayAndRefresh()
            }
        }
        AppDelegate.trackPageView("keyboard_heatmap")
    }
}
