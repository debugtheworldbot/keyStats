import Cocoa
import PostHog

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
        if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        } else if let view = statusItem.view {
            popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        } else {
            return
        }

        // 激活应用以确保弹窗可以接收焦点
        NSApp.activate(ignoringOtherApps: true)
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

class MenuBarStatusView: NSView {
    private let iconContainer = NSView()
    private let imageView = NSImageView()
    private let colorDotView = NSView()
    private let topLabel = NSTextField(labelWithString: "0")
    private let bottomLabel = NSTextField(labelWithString: "0")
    private let stack = NSStackView()
    private let textStack = NSStackView()
    private var stackLeadingConstraint: NSLayoutConstraint!
    private var stackTrailingConstraint: NSLayoutConstraint!
    private var horizontalPadding: CGFloat = 6
    
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
        // 使用菜单栏图标而不是 SF Symbol
        if let appIcon = NSImage(named: "MenuIcon") {
            let resizedIcon = NSImage(size: NSSize(width: 18, height: 18))
            resizedIcon.lockFocus()
            appIcon.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18),
                        from: NSRect(origin: .zero, size: appIcon.size),
                        operation: .copy,
                        fraction: 1.0)
            resizedIcon.unlockFocus()
            resizedIcon.isTemplate = true
            imageView.image = resizedIcon
        }
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.contentTintColor = .labelColor
        imageView.translatesAutoresizingMaskIntoConstraints = false

        iconContainer.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.addSubview(imageView)

        colorDotView.wantsLayer = true
        colorDotView.layer?.cornerRadius = 3
        colorDotView.layer?.backgroundColor = NSColor.clear.cgColor
        colorDotView.translatesAutoresizingMaskIntoConstraints = false
        colorDotView.isHidden = true
        iconContainer.addSubview(colorDotView)
        
        topLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        bottomLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        topLabel.alignment = .left
        bottomLabel.alignment = .left
        topLabel.textColor = .labelColor
        bottomLabel.textColor = .labelColor
        
        textStack.orientation = .vertical
        textStack.spacing = 0
        textStack.alignment = .leading
        textStack.addArrangedSubview(topLabel)
        textStack.addArrangedSubview(bottomLabel)
        
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(iconContainer)
        stack.addArrangedSubview(textStack)
        
        addSubview(stack)
        
        stackLeadingConstraint = stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: horizontalPadding)
        stackTrailingConstraint = stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -horizontalPadding)

        NSLayoutConstraint.activate([
            iconContainer.widthAnchor.constraint(equalToConstant: 18),
            iconContainer.heightAnchor.constraint(equalToConstant: 18),
            imageView.leadingAnchor.constraint(equalTo: iconContainer.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: iconContainer.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: iconContainer.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: iconContainer.bottomAnchor),
            colorDotView.widthAnchor.constraint(equalToConstant: 6),
            colorDotView.heightAnchor.constraint(equalToConstant: 6),
            colorDotView.leadingAnchor.constraint(equalTo: iconContainer.leadingAnchor, constant: -3),
            colorDotView.topAnchor.constraint(equalTo: iconContainer.topAnchor, constant: -3),
            stackLeadingConstraint,
            stackTrailingConstraint,
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    
    override var intrinsicContentSize: NSSize {
        let size = stack.fittingSize
        return NSSize(width: size.width + horizontalPadding * 2, height: max(20, size.height + 6))
    }
    
    func update(keysText: String, clicksText: String) {
        topLabel.stringValue = keysText
        topLabel.isHidden = keysText.isEmpty
        
        bottomLabel.stringValue = clicksText
        bottomLabel.isHidden = clicksText.isEmpty

        let hasText = !keysText.isEmpty || !clicksText.isEmpty
        textStack.isHidden = !hasText
        updateHorizontalPadding(hasText: hasText)
        
        // 如果只有一个显示，使其居中或者调整布局，这里简化处理，
        // 依靠 StackView 自动处理隐藏视图的布局
        
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    func updateIconColor(_ color: NSColor?, style: DynamicIconColorStyle) {
        guard let color = color else {
            imageView.contentTintColor = .labelColor
            colorDotView.isHidden = true
            return
        }

        switch style {
        case .icon:
            imageView.contentTintColor = color
            colorDotView.isHidden = true
        case .dot:
            imageView.contentTintColor = .labelColor
            colorDotView.layer?.backgroundColor = color.cgColor
            colorDotView.isHidden = false
        }
    }

    private func updateHorizontalPadding(hasText: Bool) {
        horizontalPadding = hasText ? 6 : 4
        stackLeadingConstraint.constant = horizontalPadding
        stackTrailingConstraint.constant = -horizontalPadding
    }
    
    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}
