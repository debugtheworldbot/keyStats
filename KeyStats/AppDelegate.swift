import Cocoa

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    
    private var menuBarController: MenuBarController?
    private var permissionCheckTimer: Timer?
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // 初始化菜单栏控制器
        menuBarController = MenuBarController()
        applyAppIcon()
        
        // 检查并请求辅助功能权限
        checkAndRequestPermission()
    }
    
    func applicationWillTerminate(_ aNotification: Notification) {
        // 停止输入监听
        InputMonitor.shared.stopMonitoring()
        permissionCheckTimer?.invalidate()
    }
    
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }
    
    // MARK: - 权限检查
    
    private func checkAndRequestPermission() {
        if InputMonitor.shared.hasAccessibilityPermission() {
            // 已有权限，直接开始监听
            InputMonitor.shared.startMonitoring()
        } else {
            // 请求权限并显示提示
            showPermissionAlert()
            
            // 定期检查权限状态
            permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
                if InputMonitor.shared.hasAccessibilityPermission() {
                    timer.invalidate()
                    self?.permissionCheckTimer = nil
                    InputMonitor.shared.startMonitoring()
                }
            }
        }
    }
    
    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("permission.title", comment: "")
        if let appIcon = NSApp.applicationIconImage {
            alert.icon = makeRoundedAlertIcon(from: appIcon)
        }
        alert.informativeText = NSLocalizedString("permission.message", comment: "")
        alert.alertStyle = .informational
        alert.addButton(withTitle: NSLocalizedString("permission.openSettings", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("permission.later", comment: ""))
        
        if alert.runModal() == .alertFirstButtonReturn {
            openAccessibilitySettings()
            _ = InputMonitor.shared.checkAccessibilityPermission()
        }
    }
    
    private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    private func makeRoundedAlertIcon(from image: NSImage) -> NSImage {
        let targetSize: CGFloat = 64
        let rect = NSRect(x: 0, y: 0, width: targetSize, height: targetSize)
        let icon = NSImage(size: rect.size)
        icon.lockFocus()
        let radius = targetSize * 0.22
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        path.addClip()
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
        icon.unlockFocus()
        return icon
    }

    private func applyAppIcon() {
        let symbolName = "button.horizontal.top.press"
        let size: CGFloat = 256
        let symbolScale: CGFloat = 0.55
        let config = NSImage.SymbolConfiguration(pointSize: size * symbolScale, weight: .regular)
        guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else {
            return
        }
        
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        let rect = NSRect(x: 0, y: 0, width: size, height: size)
        let gradient = NSGradient(colors: [
            NSColor(calibratedRed: 0.15, green: 0.77, blue: 0.96, alpha: 1.0),
            NSColor(calibratedRed: 0.49, green: 0.86, blue: 0.42, alpha: 1.0)
        ])
        gradient?.draw(in: rect, angle: 45)
        
        let symbolSize = size * symbolScale
        let symbolRect = NSRect(
            x: (size - symbolSize) / 2,
            y: (size - symbolSize) / 2,
            width: symbolSize,
            height: symbolSize
        )
        NSColor.white.set()
        symbol.draw(in: symbolRect, from: .zero, operation: .sourceOver, fraction: 1.0)
        image.unlockFocus()
        
        NSApp.applicationIconImage = image
    }
}
