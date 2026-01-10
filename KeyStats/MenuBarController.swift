import Cocoa

/// 菜单栏控制器
class MenuBarController {
    
    private var statusItem: NSStatusItem!
    private var statusView: MenuBarStatusView?
    private var popover: NSPopover!
    private var eventMonitor: Any?
    
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
        if let statusView = statusView {
            statusView.update(keysText: parts.keys, clicksText: parts.clicks)
            statusItem.length = statusView.intrinsicContentSize.width
        } else if let button = statusItem.button {
            button.attributedTitle = makeStatusTitle(keysText: parts.keys, clicksText: parts.clicks)
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
    private let imageView = NSImageView()
    private let topLabel = NSTextField(labelWithString: "0")
    private let bottomLabel = NSTextField(labelWithString: "0")
    private let stack = NSStackView()
    private let textStack = NSStackView()
    
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
        stack.addArrangedSubview(imageView)
        stack.addArrangedSubview(textStack)
        
        addSubview(stack)
        
        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: 18),
            imageView.heightAnchor.constraint(equalToConstant: 18),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    
    override var intrinsicContentSize: NSSize {
        let size = stack.fittingSize
        return NSSize(width: size.width + 12, height: max(20, size.height + 6))
    }
    
    func update(keysText: String, clicksText: String) {
        topLabel.stringValue = keysText
        topLabel.isHidden = keysText.isEmpty
        
        bottomLabel.stringValue = clicksText
        bottomLabel.isHidden = clicksText.isEmpty
        
        // 如果只有一个显示，使其居中或者调整布局，这里简化处理，
        // 依靠 StackView 自动处理隐藏视图的布局
        
        invalidateIntrinsicContentSize()
        needsLayout = true
    }
    
    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}
