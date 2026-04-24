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

    private var controller: PermissionFlowController
    private var lastAppURLs: [URL]

    private init() {
        let initial = Self.currentAppURLs()
        self.lastAppURLs = initial
        self.controller = PermissionFlow.makeController(
            configuration: .init(
                requiredAppURLs: initial,
                promptForAccessibilityTrust: false
            )
        )
    }

    func requestPermission(sourceFrameInScreen: CGRect? = nil) {
        let urls = Self.currentAppURLs()
        if urls != lastAppURLs {
            // helper 刚装好后 URL 变了，重建 controller 让 PermissionFlow 指新的
            lastAppURLs = urls
            controller = PermissionFlow.makeController(
                configuration: .init(
                    requiredAppURLs: urls,
                    promptForAccessibilityTrust: false
                )
            )
        }
        controller.authorize(
            pane: .accessibility,
            suggestedAppURLs: urls,
            sourceFrameInScreen: sourceFrameInScreen ?? fallbackSourceFrameInScreen()
        )
    }

    func closePanel() {
        controller.closePanel(returnToPreviousApp: true)
    }

    private static func currentAppURLs() -> [URL] {
        let helperURL = HelperLocations.installedHelperURL
        if FileManager.default.fileExists(atPath: helperURL.path) {
            return [helperURL]
        }
        return [Bundle.main.bundleURL]
    }

    private func fallbackSourceFrameInScreen() -> CGRect {
        let mouseLocation = NSEvent.mouseLocation
        return CGRect(x: mouseLocation.x - 16, y: mouseLocation.y - 16, width: 32, height: 32)
    }
}
