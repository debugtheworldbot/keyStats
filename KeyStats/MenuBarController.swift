import Cocoa

/// 菜单栏控制器
class MenuBarController {
    
    private var statusItem: NSStatusItem!
    private var statusView: MenuBarStatusView?
    private var popover: NSPopover!
    private var eventMonitor: Any?
    private var updateTimer: Timer?
    
    init() {
        setupStatusItem()
        setupPopover()
        setupEventMonitor()
        startUpdateTimer()
        
        // 监听统计更新
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateMenuBarText),
            name: .statsDidUpdate,
            object: nil
        )
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        updateTimer?.invalidate()
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
    
    // MARK: - 定时更新菜单栏文本
    
    private func startUpdateTimer() {
        // 每秒更新一次菜单栏显示（主要是为了节流，避免每次事件都更新）
        updateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateMenuBarText()
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
        DispatchQueue.main.async { [weak self] in
            self?.updateMenuBarAppearance()
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
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        let result = NSMutableAttributedString()

        func appendText(_ text: String) {
            result.append(NSAttributedString(string: text, attributes: textAttributes))
        }

        func appendSymbol(_ name: String) {
            guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(symbolConfig) else {
                return
            }
            let attachment = NSTextAttachment()
            image.size = NSSize(width: 13, height: 13)
            attachment.image = image
            attachment.bounds = NSRect(x: 0, y: -1, width: 13, height: 13)
            result.append(NSAttributedString(attachment: attachment))
        }

        appendSymbol("button.horizontal.top.press")
        appendText(" ")
        appendText(keysText)
        appendText(" ")
        appendText(clicksText)
        
        return result
    }
}

// MARK: - 菜单栏自定义视图

class MenuBarStatusView: NSView {
    private static let symbolName = "button.horizontal.top.press.fill"
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
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        if let image = NSImage(systemSymbolName: Self.symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolConfig) {
            image.size = NSSize(width: 18, height: 18)
            imageView.image = image
        }
        imageView.symbolConfiguration = symbolConfig
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
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
        bottomLabel.stringValue = clicksText
        invalidateIntrinsicContentSize()
        needsLayout = true
    }
    
    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}
