import Cocoa
import PostHog
import SwiftUI

enum DynamicIconColorStyle: String {
    case icon
    case dot
}

/// 菜单栏控制器
class MenuBarController {
    
    private var statusItem: NSStatusItem!
    private var statusView: MenuBarStatusView?
    private var popover: NSPopover!
    private var eventMonitor: Any?
    private let dynamicIconColorStyleKey = "dynamicIconColorStyle"
    
    init() {
        setupStatusItem()
        setupPopover()
        setupEventMonitor()
        StatsManager.shared.menuBarUpdateHandler = { [weak self] in
            self?.updateMenuBarText()
        }
    }
    
    deinit {
        StatsManager.shared.menuBarUpdateHandler = nil
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
    
    // MARK: - 设置状态栏项
    
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        let statusView = MenuBarStatusView()
        statusView.onClick = { [weak self] in
            self?.togglePopover()
        }
        statusItem.view = statusView
        self.statusView = statusView
        updateMenuBarAppearance()
    }
    
    // MARK: - 设置弹出面板
    
    private func setupPopover() {
        popover = NSPopover()
        popover.contentSize = NSSize(width: 320, height: 640)
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = StatsPopoverViewController()
    }
    
    // MARK: - 设置事件监听（点击外部关闭弹窗）
    
    private func setupEventMonitor() {
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            if let popover = self?.popover, popover.isShown {
                popover.performClose(nil)
            }
        }
    }
    
    // MARK: - 操作
    
    @objc private func togglePopover() {
        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }
    
    private func showPopover() {
        // 先激活应用，确保弹窗可以接收焦点
        NSApp.activate(ignoringOtherApps: true)

        if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        } else if let view = statusItem.view {
            popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        } else {
            return
        }

        // 确保 popover 窗口成为 key window
        popover.contentViewController?.view.window?.makeKey()
        PostHogSDK.shared.capture("popoverOpened")
    }
    
    private func closePopover() {
        popover.performClose(nil)
    }
    
    @objc private func updateMenuBarText() {
        if Thread.isMainThread {
            updateMenuBarAppearance()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.updateMenuBarAppearance()
            }
        }
    }

    // MARK: - 菜单栏显示样式

    private func updateMenuBarAppearance() {
        let parts = StatsManager.shared.getMenuBarTextParts()
        let tintColor = StatsManager.shared.enableDynamicIconColor
            ? StatsManager.shared.currentIconTintColor
            : nil
        let styleValue = UserDefaults.standard.string(forKey: dynamicIconColorStyleKey) ?? DynamicIconColorStyle.icon.rawValue
        let style = DynamicIconColorStyle(rawValue: styleValue) ?? .icon

        if let statusView = statusView {
            statusView.update(keysText: parts.keys, clicksText: parts.clicks)
            statusView.updateIconColor(tintColor, style: style)
            statusItem.length = statusView.intrinsicContentSize.width
        } else if let button = statusItem.button {
            button.attributedTitle = makeStatusTitle(keysText: parts.keys, clicksText: parts.clicks)
            button.contentTintColor = style == .icon ? tintColor : nil
        }

    }

    private func makeStatusTitle(keysText: String, clicksText: String) -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let textAttributes: [NSAttributedString.Key: Any] = [.font: font]
        let result = NSMutableAttributedString()

        func appendText(_ text: String) {
            result.append(NSAttributedString(string: text, attributes: textAttributes))
        }

        func appendAppIcon() {
            guard let appIcon = NSImage(named: "MenuIcon") else {
                return
            }
            let resizedIcon = NSImage(size: NSSize(width: 13, height: 13))
            resizedIcon.lockFocus()
            appIcon.draw(in: NSRect(x: 0, y: 0, width: 13, height: 13),
                        from: NSRect(origin: .zero, size: appIcon.size),
                        operation: .copy,
                        fraction: 1.0)
            resizedIcon.unlockFocus()
            resizedIcon.isTemplate = true

            let attachment = NSTextAttachment()
            attachment.image = resizedIcon
            attachment.bounds = NSRect(x: 0, y: -1, width: 13, height: 13)
            result.append(NSAttributedString(attachment: attachment))
        }

        appendAppIcon()
        
        if !keysText.isEmpty {
            appendText(" ")
            appendText(keysText)
        }
        
        if !clicksText.isEmpty {
            appendText(" ")
            appendText(clicksText)
        }

        return result
    }
}

// MARK: - 菜单栏自定义视图

final class MenuBarStatusViewModel: ObservableObject {
    @Published var keysText: String = "0"
    @Published var clicksText: String = "0"
    @Published var iconColor: NSColor?
    @Published var colorStyle: DynamicIconColorStyle = .icon
}

struct MenuBarStatusSwiftUIView: View {
    @ObservedObject var viewModel: MenuBarStatusViewModel

    private static let menuIcon: NSImage? = {
        guard let appIcon = NSImage(named: "MenuIcon") else {
            return nil
        }
        let resizedIcon = NSImage(size: NSSize(width: 18, height: 18))
        resizedIcon.lockFocus()
        appIcon.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18),
                    from: NSRect(origin: .zero, size: appIcon.size),
                    operation: .copy,
                    fraction: 1.0)
        resizedIcon.unlockFocus()
        resizedIcon.isTemplate = true
        return resizedIcon
    }()

    var body: some View {
        let hasText = !viewModel.keysText.isEmpty || !viewModel.clicksText.isEmpty
        let horizontalPadding: CGFloat = hasText ? 6 : 4

        HStack(spacing: 4) {
            ZStack(alignment: .topLeading) {
                if let icon = Self.menuIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .renderingMode(.template)
                        .frame(width: 18, height: 18, alignment: .center)
                        .foregroundStyle(iconTint)
                }

                if let dotColor = dotColor {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 6, height: 6)
                        .offset(x: -3, y: -3)
                }
            }
            .frame(width: 18, height: 18, alignment: .center)

            if hasText {
                VStack(alignment: .leading, spacing: 0) {
                    if !viewModel.keysText.isEmpty {
                        MenuBarValueText(text: viewModel.keysText, weight: .semibold)
                    }

                    if !viewModel.clicksText.isEmpty {
                        MenuBarValueText(text: viewModel.clicksText, weight: .medium)
                    }
                }
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, 2)
        .frame(minHeight: 20, alignment: .center)
    }

    private var iconTint: Color {
        if viewModel.colorStyle == .icon, let color = viewModel.iconColor {
            return Color(nsColor: color)
        }
        return Color(nsColor: .labelColor)
    }

    private var dotColor: Color? {
        guard viewModel.colorStyle == .dot, let color = viewModel.iconColor else {
            return nil
        }
        return Color(nsColor: color)
    }
}

private struct MenuBarValueText: View {
    let text: String
    let weight: Font.Weight

    var body: some View {
        Group {
            if #available(macOS 14.0, *) {
                Text(text)
                    .font(.system(size: 10, weight: weight))
                    .monospacedDigit()
                    .foregroundStyle(Color(nsColor: .labelColor))
                    .contentTransition(.numericText())
            } else {
                Text(text)
                    .font(.system(size: 10, weight: weight))
                    .monospacedDigit()
                    .foregroundStyle(Color(nsColor: .labelColor))
            }
        }
        .animation(.default, value: text)
    }
}

class MenuBarStatusView: NSView {
    private let viewModel = MenuBarStatusViewModel()
    private var hostingView: NSHostingView<MenuBarStatusSwiftUIView>?

    var onClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        let rootView = MenuBarStatusSwiftUIView(viewModel: viewModel)
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)

        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        self.hostingView = hostingView
    }

    override var intrinsicContentSize: NSSize {
        if let hostingView = hostingView {
            return hostingView.fittingSize
        }
        return NSSize(width: 24, height: 20)
    }

    func update(keysText: String, clicksText: String) {
        let updateBlock = {
            self.viewModel.keysText = keysText
            self.viewModel.clicksText = clicksText
        }

        if Thread.isMainThread {
            updateBlock()
        } else {
            DispatchQueue.main.async {
                updateBlock()
            }
        }

        invalidateIntrinsicContentSize()
        hostingView?.invalidateIntrinsicContentSize()
        needsLayout = true
    }

    func updateIconColor(_ color: NSColor?, style: DynamicIconColorStyle) {
        let updateBlock = {
            self.viewModel.iconColor = color
            self.viewModel.colorStyle = style
        }

        if Thread.isMainThread {
            updateBlock()
        } else {
            DispatchQueue.main.async {
                updateBlock()
            }
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        return self
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}
