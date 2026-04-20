import AppKit
import PermissionFlow

extension NSView {
    func permissionFlowSourceFrameInScreen() -> CGRect? {
        guard let window = window else { return nil }
        let frameInWindow = convert(bounds, to: nil)
        return window.convertToScreen(frameInWindow)
    }
}

@MainActor
final class AccessibilityPermissionCoordinator {
    static let shared = AccessibilityPermissionCoordinator()

    private let appURLs: [URL]
    private let controller: PermissionFlowController

    private init() {
        let appURLs = [Bundle.main.bundleURL]
        self.appURLs = appURLs
        self.controller = PermissionFlow.makeController(
            configuration: .init(
                requiredAppURLs: appURLs,
                promptForAccessibilityTrust: false
            )
        )
    }

    func requestPermission(sourceFrameInScreen: CGRect? = nil) {
        controller.authorize(
            pane: .accessibility,
            suggestedAppURLs: appURLs,
            sourceFrameInScreen: sourceFrameInScreen ?? fallbackSourceFrameInScreen()
        )
    }

    private func fallbackSourceFrameInScreen() -> CGRect {
        let mouseLocation = NSEvent.mouseLocation
        return CGRect(x: mouseLocation.x - 16, y: mouseLocation.y - 16, width: 32, height: 32)
    }
}
