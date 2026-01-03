import Cocoa

/// 统计详情弹出视图控制器
class StatsPopoverViewController: NSViewController {
    
    // MARK: - UI 组件
    private var containerView: NSView!
    private var titleLabel: NSTextField!
    private var statsStackView: NSStackView!
    private var keyBreakdownTitleLabel: NSTextField!
    private var keyBreakdownGridStack: NSStackView!
    private var keyBreakdownColumns: [NSStackView] = []
    private var keyBreakdownSeparators: [NSView] = []
    private var historyTitleLabel: NSTextField!
    private var rangeControl: NSSegmentedControl!
    private var metricControl: NSSegmentedControl!
    private var chartStyleControl: NSSegmentedControl!
    private var chartView: StatsChartView!
    private var historySummaryLabel: NSTextField!
    private var updateTimer: Timer?
    
    // 统计项视图
    private var keyPressView: StatItemView!
    private var leftClickView: StatItemView!
    private var rightClickView: StatItemView!
    private var mouseDistanceView: StatItemView!
    private var scrollDistanceView: StatItemView!
    
    // 底部按钮
    private var resetButton: NSButton!
    private var quitButton: NSButton!
    private var permissionButton: NSButton!
    
    // MARK: - 生命周期
    
    override func loadView() {
        // 创建主视图
        let mainView = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 640))
        mainView.wantsLayer = true
        self.view = mainView
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        updateStats()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        updateStats()
        startUpdateTimer()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        focusPrimaryControl()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        stopUpdateTimer()
    }
    
    deinit {
        stopUpdateTimer()
    }
    
    // MARK: - UI 设置
    
    private func setupUI() {
        // 标题
        titleLabel = createLabel(text: "KeyStats", fontSize: 18, weight: .bold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(titleLabel)
        
        permissionButton = NSButton(title: NSLocalizedString("button.permission", comment: ""), target: self, action: #selector(requestPermission))
        permissionButton.bezelStyle = .rounded
        permissionButton.controlSize = .regular
        permissionButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(permissionButton)

        // 分隔线
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(separator)
        
        // 统计项
        keyPressView = StatItemView(icon: "⌨️", title: NSLocalizedString("stats.keyPresses", comment: ""), value: "0")
        leftClickView = StatItemView(icon: "🖱️", title: NSLocalizedString("stats.leftClicks", comment: ""), value: "0")
        rightClickView = StatItemView(icon: "🖱️", title: NSLocalizedString("stats.rightClicks", comment: ""), value: "0")
        mouseDistanceView = StatItemView(icon: "↔️", title: NSLocalizedString("stats.mouseDistance", comment: ""), value: "0 px")
        scrollDistanceView = StatItemView(icon: "↕️", title: NSLocalizedString("stats.scrollDistance", comment: ""), value: "0 px")
        
        let clickRow = NSStackView(views: [leftClickView, rightClickView])
        clickRow.orientation = .horizontal
        clickRow.spacing = 16
        clickRow.distribution = .fillEqually
        clickRow.alignment = .centerY
        clickRow.translatesAutoresizingMaskIntoConstraints = false

        let distanceRow = NSStackView(views: [mouseDistanceView, scrollDistanceView])
        distanceRow.orientation = .horizontal
        distanceRow.spacing = 16
        distanceRow.distribution = .fillEqually
        distanceRow.alignment = .centerY
        distanceRow.translatesAutoresizingMaskIntoConstraints = false

        statsStackView = NSStackView(views: [
            keyPressView,
            clickRow,
            distanceRow
        ])
        statsStackView.orientation = .vertical
        statsStackView.spacing = 8
        statsStackView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statsStackView)
        
        // 键位统计标题
        keyBreakdownTitleLabel = createLabel(text: NSLocalizedString("section.keyBreakdown", comment: ""), fontSize: 14, weight: .semibold)
        keyBreakdownTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(keyBreakdownTitleLabel)

        // 键位统计列表（最多 3 列，每列 5 个）
        keyBreakdownGridStack = NSStackView()
        keyBreakdownGridStack.orientation = .horizontal
        keyBreakdownGridStack.spacing = 10
        keyBreakdownGridStack.distribution = .fill
        keyBreakdownGridStack.alignment = .top
        keyBreakdownGridStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(keyBreakdownGridStack)

        keyBreakdownColumns = (0..<3).map { index in
            let column = NSStackView()
            column.orientation = .vertical
            column.spacing = 6
            column.alignment = .leading
            column.distribution = .fill
            column.translatesAutoresizingMaskIntoConstraints = false
            keyBreakdownGridStack.addArrangedSubview(column)
            if index < 2 {
                let separator = makeVerticalSeparator()
                keyBreakdownSeparators.append(separator)
                keyBreakdownGridStack.addArrangedSubview(separator)
                separator.heightAnchor.constraint(equalTo: keyBreakdownGridStack.heightAnchor).isActive = true
            }
            return column
        }

        if keyBreakdownColumns.count == 3 {
            keyBreakdownColumns[0].widthAnchor.constraint(equalTo: keyBreakdownColumns[1].widthAnchor).isActive = true
            keyBreakdownColumns[1].widthAnchor.constraint(equalTo: keyBreakdownColumns[2].widthAnchor).isActive = true
        }

        // 历史趋势标题
        historyTitleLabel = createLabel(text: NSLocalizedString("section.history", comment: ""), fontSize: 14, weight: .semibold)
        historyTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(historyTitleLabel)
        
        // 时间范围
        rangeControl = NSSegmentedControl(labels: [
            NSLocalizedString("history.range.week", comment: ""),
            NSLocalizedString("history.range.month", comment: "")
        ],
                                          trackingMode: .selectOne,
                                          target: self,
                                          action: #selector(historyControlsChanged))
        rangeControl.selectedSegment = 0
        rangeControl.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(rangeControl)
        
        // 指标选择
        metricControl = NSSegmentedControl(labels: [
            NSLocalizedString("history.metric.keys", comment: ""),
            NSLocalizedString("history.metric.clicks", comment: ""),
            NSLocalizedString("history.metric.move", comment: ""),
            NSLocalizedString("history.metric.scroll", comment: "")
        ],
                                           trackingMode: .selectOne,
                                           target: self,
                                           action: #selector(historyControlsChanged))
        metricControl.selectedSegment = 0
        metricControl.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(metricControl)
        
        // 图表样式
        chartStyleControl = NSSegmentedControl(labels: [
            NSLocalizedString("history.chart.line", comment: ""),
            NSLocalizedString("history.chart.bar", comment: "")
        ],
                                               trackingMode: .selectOne,
                                               target: self,
                                               action: #selector(historyControlsChanged))
        chartStyleControl.selectedSegment = 0
        chartStyleControl.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(chartStyleControl)
        
        // 图表视图
        chartView = StatsChartView()
        chartView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(chartView)
        
        // 汇总
        historySummaryLabel = createLabel(
            text: String(format: NSLocalizedString("history.total", comment: ""), "0"),
            fontSize: 12,
            weight: .regular
        )
        historySummaryLabel.textColor = .secondaryLabelColor
        historySummaryLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(historySummaryLabel)
        
        // 底部分隔线
        let bottomSeparator = NSBox()
        bottomSeparator.boxType = .separator
        bottomSeparator.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bottomSeparator)
        
        // 按钮容器
        let buttonStack = NSStackView()
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 12
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        
        // 重置按钮
        resetButton = NSButton(title: NSLocalizedString("button.reset", comment: ""), target: self, action: #selector(resetStats))
        resetButton.bezelStyle = .rounded
        resetButton.controlSize = .regular
        
        // 退出按钮
        quitButton = NSButton(title: NSLocalizedString("button.quit", comment: ""), target: self, action: #selector(quitApp))
        quitButton.bezelStyle = .rounded
        quitButton.controlSize = .regular
        
        buttonStack.addArrangedSubview(resetButton)
        buttonStack.addArrangedSubview(quitButton)

        view.addSubview(buttonStack)
        
        // 布局约束
        NSLayoutConstraint.activate([
            // 标题
            titleLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            titleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            permissionButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            permissionButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            
            // 分隔线
            separator.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            separator.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            separator.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            
            // 统计项
            statsStackView.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 12),
            statsStackView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            statsStackView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            
            // 键位统计
            keyBreakdownTitleLabel.topAnchor.constraint(equalTo: statsStackView.bottomAnchor, constant: 16),
            keyBreakdownTitleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),

            keyBreakdownGridStack.topAnchor.constraint(equalTo: keyBreakdownTitleLabel.bottomAnchor, constant: 8),
            keyBreakdownGridStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            keyBreakdownGridStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            keyBreakdownGridStack.heightAnchor.constraint(equalToConstant: 124),

            // 历史趋势
            historyTitleLabel.topAnchor.constraint(equalTo: keyBreakdownGridStack.bottomAnchor, constant: 16),
            historyTitleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            
            rangeControl.topAnchor.constraint(equalTo: historyTitleLabel.bottomAnchor, constant: 8),
            rangeControl.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            rangeControl.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            
            metricControl.topAnchor.constraint(equalTo: rangeControl.bottomAnchor, constant: 8),
            metricControl.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            metricControl.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            
            chartStyleControl.topAnchor.constraint(equalTo: metricControl.bottomAnchor, constant: 8),
            chartStyleControl.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            chartStyleControl.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            
            chartView.topAnchor.constraint(equalTo: chartStyleControl.bottomAnchor, constant: 8),
            chartView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            chartView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            chartView.heightAnchor.constraint(equalToConstant: 140),
            
            historySummaryLabel.topAnchor.constraint(equalTo: chartView.bottomAnchor, constant: 6),
            historySummaryLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            
            // 底部分隔线
            bottomSeparator.topAnchor.constraint(equalTo: historySummaryLabel.bottomAnchor, constant: 12),
            bottomSeparator.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            bottomSeparator.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            
            // 按钮
            buttonStack.topAnchor.constraint(equalTo: bottomSeparator.bottomAnchor, constant: 12),
            buttonStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            buttonStack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16)
        ])
    }
    
    private func createLabel(text: String, fontSize: CGFloat, weight: NSFont.Weight) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: fontSize, weight: weight)
        label.isEditable = false
        label.isSelectable = false
        label.isBezeled = false
        label.drawsBackground = false
        return label
    }

    private func makeVerticalSeparator() -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: 1).isActive = true
        return view
    }
    
    // MARK: - 更新统计数据
    
    private func updateStats() {
        let stats = StatsManager.shared.currentStats
        
        keyPressView.updateValue(formatNumber(stats.keyPresses))
        leftClickView.updateValue(formatNumber(stats.leftClicks))
        rightClickView.updateValue(formatNumber(stats.rightClicks))
        mouseDistanceView.updateValue(stats.formattedMouseDistance)
        scrollDistanceView.updateValue(stats.formattedScrollDistance)
        updateKeyBreakdown()
        updateHistorySection()
        updatePermissionButtonVisibility()
    }

    private func startUpdateTimer() {
        updateTimer?.invalidate()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateStats()
        }
    }

    private func stopUpdateTimer() {
        updateTimer?.invalidate()
        updateTimer = nil
    }
    
    private func formatNumber(_ number: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: number)) ?? "\(number)"
    }

    private func updateKeyBreakdown() {
        let items = StatsManager.shared.keyPressBreakdownSorted()
        let hasItems = !items.isEmpty
        keyBreakdownSeparators.forEach { $0.isHidden = !hasItems }
        for column in keyBreakdownColumns {
            column.arrangedSubviews.forEach {
                column.removeArrangedSubview($0)
                $0.removeFromSuperview()
            }
        }
        guard hasItems else {
            let emptyLabel = createLabel(text: NSLocalizedString("keyBreakdown.empty", comment: ""), fontSize: 12, weight: .regular)
            emptyLabel.textColor = .secondaryLabelColor
            emptyLabel.translatesAutoresizingMaskIntoConstraints = false
            if let firstColumn = keyBreakdownColumns.first {
                firstColumn.addArrangedSubview(emptyLabel)
                emptyLabel.widthAnchor.constraint(equalTo: firstColumn.widthAnchor).isActive = true
            }
            return
        }
        let limitedItems = Array(items.prefix(15))
        for (index, item) in limitedItems.enumerated() {
            let columnIndex = index / 5
            if columnIndex >= keyBreakdownColumns.count { break }
            let row = KeyCountRowView(key: item.key, count: formatNumber(item.count))
            let column = keyBreakdownColumns[columnIndex]
            column.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
    }

    @objc private func historyControlsChanged() {
        updateHistorySection()
    }

    private func updatePermissionButtonVisibility() {
        permissionButton.isHidden = InputMonitor.shared.hasAccessibilityPermission()
    }

    private func focusPrimaryControl() {
        if !permissionButton.isHidden {
            view.window?.makeFirstResponder(permissionButton)
        }
    }
    
    private func updateHistorySection() {
        let range = selectedRange()
        let metric = selectedMetric()
        let style = selectedChartStyle()
        
        let series = StatsManager.shared.historySeries(range: range, metric: metric)
        chartView.series = series
        chartView.metric = metric
        chartView.range = range
        chartView.style = style
        
        let total = series.reduce(0) { $0 + $1.value }
        let formatted = StatsManager.shared.formatHistoryValue(metric: metric, value: total)
        historySummaryLabel.stringValue = String(format: NSLocalizedString("history.total", comment: ""), formatted)
    }
    
    private func selectedRange() -> StatsManager.HistoryRange {
        switch rangeControl.selectedSegment {
        case 0: return .week
        default: return .month
        }
    }
    
    private func selectedMetric() -> StatsManager.HistoryMetric {
        switch metricControl.selectedSegment {
        case 0: return .keyPresses
        case 1: return .clicks
        case 2: return .mouseDistance
        default: return .scrollDistance
        }
    }
    
    private func selectedChartStyle() -> StatsChartView.Style {
        switch chartStyleControl.selectedSegment {
        case 1: return .bar
        default: return .line
        }
    }
    
    // MARK: - 按钮操作
    
    @objc private func resetStats() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("stats.reset.title", comment: "")
        alert.informativeText = NSLocalizedString("stats.reset.message", comment: "")
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("stats.reset.confirm", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("stats.reset.cancel", comment: ""))
        
        if alert.runModal() == .alertFirstButtonReturn {
            StatsManager.shared.resetStats()
        }
    }

    @objc private func requestPermission() {
        _ = InputMonitor.shared.checkAccessibilityPermission()
        openAccessibilitySettings()
        updatePermissionButtonVisibility()
    }
    
    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}

// MARK: - 统计项视图

class StatItemView: NSView {
    private var iconLabel: NSTextField!
    private var titleLabel: NSTextField!
    private var valueLabel: NSTextField!
    
    init(icon: String, title: String, value: String) {
        super.init(frame: .zero)
        setupUI(icon: icon, title: title, value: value)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupUI(icon: String, title: String, value: String) {
        translatesAutoresizingMaskIntoConstraints = false
        
        // 图标
        iconLabel = NSTextField(labelWithString: icon)
        iconLabel.font = NSFont.systemFont(ofSize: 20)
        iconLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconLabel)
        
        // 标题
        titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)
        
        // 数值
        valueLabel = NSTextField(labelWithString: value)
        valueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        valueLabel.textColor = .systemBlue
        valueLabel.alignment = .right
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(valueLabel)
        
        // 布局
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            
            iconLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            iconLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconLabel.widthAnchor.constraint(equalToConstant: 24),
            
            titleLabel.leadingAnchor.constraint(equalTo: iconLabel.trailingAnchor, constant: 4),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8)
        ])
    }
    
    func updateValue(_ value: String) {
        valueLabel.stringValue = value
    }
}

// MARK: - 键位统计行

class KeyCountRowView: NSView {
    private var keyLabel: NSTextField!
    private var countLabel: NSTextField!
    private static let symbolNameMap: [String: String] = [
        "Cmd": "command",
        "Shift": "shift",
        "Option": "option",
        "Ctrl": "control",
        "Fn": "fn",
        "Esc": "escape",
        "Escape": "escape",
        "Tab": "tab",
        "Return": "return",
        "Enter": "return",
        "Delete": "delete.left",
        "ForwardDelete": "delete.right",
        "Left": "arrow.left",
        "Right": "arrow.right",
        "Up": "arrow.up",
        "Down": "arrow.down"
    ]
    private static let squareSymbolKeys: Set<String> = ["Ctrl", "Control"]

    init(key: String, count: String) {
        super.init(frame: .zero)
        setupUI(key: key, count: count)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI(key: String, count: String) {
        translatesAutoresizingMaskIntoConstraints = false
        let keyFont = NSFont.systemFont(ofSize: 12, weight: .medium)
        keyLabel = NSTextField(labelWithAttributedString: formattedKeyLabel(for: key, font: keyFont))
        keyLabel.font = keyFont
        keyLabel.textColor = .labelColor
        keyLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(keyLabel)

        countLabel = NSTextField(labelWithString: count)
        countLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        countLabel.textColor = .secondaryLabelColor
        countLabel.alignment = .right
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(countLabel)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 20),

            keyLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            keyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            countLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            countLabel.leadingAnchor.constraint(greaterThanOrEqualTo: keyLabel.trailingAnchor, constant: 8)
        ])
    }

    func update(key: String, count: String) {
        if let font = keyLabel.font {
            keyLabel.attributedStringValue = formattedKeyLabel(for: key, font: font)
        } else {
            keyLabel.stringValue = key
        }
        countLabel.stringValue = count
    }

    private func formattedKeyLabel(for key: String, font: NSFont) -> NSAttributedString {
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor
        ]
        let result = NSMutableAttributedString()

        for (index, part) in keyParts(from: key).enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: " ", attributes: textAttributes))
            }
            if let badge = makeKeyBadge(for: part, font: font) {
                let attachment = NSTextAttachment()
                attachment.image = badge
                let baselineOffset = (font.ascender + font.descender - badge.size.height) / 2 + 1
                attachment.bounds = CGRect(x: 0, y: baselineOffset, width: badge.size.width, height: badge.size.height)
                result.append(NSAttributedString(attachment: attachment))
            } else {
                result.append(NSAttributedString(string: part, attributes: textAttributes))
            }
        }

        return result
    }

    private func makeKeyBadge(for keyPart: String, font: NSFont) -> NSImage? {
        let contentPointSize = max(font.pointSize - 1, 10)
        let padding: CGFloat = 4
        let lineWidth: CGFloat = 0.8
        let cornerRadiusScale: CGFloat = 0.3
        let textFont = NSFont.systemFont(ofSize: contentPointSize, weight: .medium)
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: textFont,
            .foregroundColor: NSColor.labelColor
        ]
        let textMetricsHeight = ("M" as NSString).size(withAttributes: textAttributes).height
        let badgeHeight = ceil(max(textMetricsHeight, contentPointSize) + padding * 2)

        if let symbolName = Self.symbolNameMap[keyPart],
           let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: keyPart)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: contentPointSize, weight: .medium)) {
            let symbolSize = symbol.size
            let forceSquare = Self.squareSymbolKeys.contains(keyPart)
            let symbolRectSize: NSSize
            let badgeWidth: CGFloat

            if forceSquare {
                let maxSide = contentPointSize
                let scale = min(maxSide / symbolSize.width, maxSide / symbolSize.height)
                symbolRectSize = NSSize(width: symbolSize.width * scale, height: symbolSize.height * scale)
                badgeWidth = badgeHeight
            } else {
                let aspectRatio = symbolSize.height > 0 ? (symbolSize.width / symbolSize.height) : 1
                let symbolHeight = contentPointSize
                let symbolWidth = symbolHeight * aspectRatio
                symbolRectSize = NSSize(width: symbolWidth, height: symbolHeight)
                badgeWidth = ceil(max(badgeHeight, symbolWidth + padding * 2))
            }
            let badgeSize = NSSize(width: badgeWidth, height: badgeHeight)
            return drawBadge(size: badgeSize, cornerRadius: badgeHeight * cornerRadiusScale, lineWidth: lineWidth) { rect in
                let symbolRect = NSRect(
                    x: rect.midX - symbolRectSize.width / 2,
                    y: rect.midY - symbolRectSize.height / 2,
                    width: symbolRectSize.width,
                    height: symbolRectSize.height
                )
                symbol.isTemplate = true
                NSColor.labelColor.set()
                symbol.draw(in: symbolRect)
            }
        }

        let text = keyPart
        let textSize = (text as NSString).size(withAttributes: textAttributes)
        let contentHeight = max(contentPointSize, textSize.height)
        let badgeWidth = ceil(max(badgeHeight, textSize.width + padding * 2))
        let badgeSize = NSSize(width: badgeWidth, height: badgeHeight)
        return drawBadge(size: badgeSize, cornerRadius: badgeHeight * cornerRadiusScale, lineWidth: lineWidth) { rect in
            let textRect = NSRect(
                x: rect.midX - textSize.width / 2,
                y: rect.midY - textSize.height / 2,
                width: textSize.width,
                height: textSize.height
            )
            (text as NSString).draw(in: textRect, withAttributes: textAttributes)
        }
    }

    private func drawBadge(size: NSSize, cornerRadius: CGFloat, lineWidth: CGFloat, content: (NSRect) -> Void) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        NSGraphicsContext.current?.shouldAntialias = true
        NSGraphicsContext.current?.imageInterpolation = .high

        let rect = NSRect(
            x: lineWidth / 2,
            y: lineWidth / 2,
            width: size.width - lineWidth,
            height: size.height - lineWidth
        )
        let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
        NSColor.controlBackgroundColor.withAlphaComponent(0.35).setFill()
        path.fill()
        NSColor.separatorColor.withAlphaComponent(0.35).setStroke()
        path.lineWidth = lineWidth
        path.stroke()

        content(rect)

        image.unlockFocus()
        return image
    }

    private func keyParts(from key: String) -> [String] {
        guard key.contains("+") else { return [key] }
        if key.hasSuffix("+") {
            var trimmed = String(key.dropLast())
            if trimmed.hasSuffix("+") {
                trimmed = String(trimmed.dropLast())
            }
            var parts = trimmed.split(separator: "+").map { String($0) }
            parts.append("+")
            return parts.isEmpty ? [key] : parts
        }
        return key.split(separator: "+").map { String($0) }
    }
}

// MARK: - 图表视图

class StatsChartView: NSView {
    enum Style {
        case line
        case bar
    }
    
    var series: [(date: Date, value: Double)] = [] {
        didSet {
            hoverIndex = nil
            needsDisplay = true
        }
    }
    
    var metric: StatsManager.HistoryMetric = .keyPresses {
        didSet { needsDisplay = true }
    }
    
    var range: StatsManager.HistoryRange = .week {
        didSet { needsDisplay = true }
    }
    
    var style: Style = .line {
        didSet { needsDisplay = true }
    }
    
    private var hoverIndex: Int? {
        didSet {
            if hoverIndex != oldValue {
                needsDisplay = true
            }
        }
    }
    
    private var trackingArea: NSTrackingArea?
    
    private lazy var dayDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("M/d")
        return formatter
    }()
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }
    
    override func updateTrackingAreas() {
        if let trackingArea = trackingArea {
            removeTrackingArea(trackingArea)
        }
        let options: NSTrackingArea.Options = [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect]
        let area = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }
    
    override func mouseMoved(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        updateHoverIndex(for: location)
    }
    
    override func mouseExited(with event: NSEvent) {
        hoverIndex = nil
    }
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        
        let backgroundRect = bounds.insetBy(dx: 6, dy: 6)
        let plotRect = plotRect(in: backgroundRect)
        let gridColor = NSColor.separatorColor.withAlphaComponent(0.35)
        let axisColor = NSColor.separatorColor.withAlphaComponent(0.6)
        
        NSColor.controlBackgroundColor.withAlphaComponent(0.15).setFill()
        NSBezierPath(roundedRect: backgroundRect, xRadius: 6, yRadius: 6).fill()
        
        guard let maxValue = series.map({ $0.value }).max(), maxValue > 0 else {
            let text = NSLocalizedString("history.empty", comment: "")
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            let size = text.size(withAttributes: attributes)
            let point = NSPoint(x: backgroundRect.midX - size.width / 2, y: backgroundRect.midY - size.height / 2)
            text.draw(at: point, withAttributes: attributes)
            return
        }
        
        drawGrid(in: plotRect, color: gridColor)
        drawAxes(in: plotRect, color: axisColor)
        drawAxisLabels(in: plotRect, maxValue: maxValue)
        
        switch style {
        case .line:
            drawLineChart(in: plotRect, maxValue: maxValue)
        case .bar:
            drawBarChart(in: plotRect, maxValue: maxValue)
        }
        
        drawHover(in: plotRect, maxValue: maxValue, backgroundRect: backgroundRect)
    }
    
    private func drawGrid(in rect: NSRect, color: NSColor) {
        for i in 1...3 {
            let y = rect.minY + rect.height * CGFloat(i) / 4
            let path = NSBezierPath()
            path.move(to: NSPoint(x: rect.minX, y: y))
            path.line(to: NSPoint(x: rect.maxX, y: y))
            color.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }
    
    private func drawAxes(in rect: NSRect, color: NSColor) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX, y: rect.minY))
        path.line(to: NSPoint(x: rect.minX, y: rect.maxY))
        path.move(to: NSPoint(x: rect.minX, y: rect.minY))
        path.line(to: NSPoint(x: rect.maxX, y: rect.minY))
        color.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
    
    private func drawAxisLabels(in rect: NSRect, maxValue: Double) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        
        drawLabel(formatValue(0), at: NSPoint(x: rect.minX - 4, y: rect.minY), alignment: .right, attributes: attributes)
        drawLabel(formatValue(maxValue / 2), at: NSPoint(x: rect.minX - 4, y: rect.midY), alignment: .right, attributes: attributes)
        drawLabel(formatValue(maxValue), at: NSPoint(x: rect.minX - 4, y: rect.maxY), alignment: .right, attributes: attributes)
        
        guard !series.isEmpty else { return }
        let labels = series.map { dateLabel(for: $0.date) }
        let maxLabelWidth = labels
            .map { $0.size(withAttributes: attributes).width }
            .max() ?? 0
        let minSpacing: CGFloat = 6
        let maxLabels = max(2, Int(rect.width / max(1, maxLabelWidth + minSpacing)))
        let count = labels.count
        let step: Int
        if count <= 7 {
            step = 2
        } else if maxLabels >= count {
            step = 1
        } else {
            step = Int(ceil(Double(count - 1) / Double(maxLabels - 1)))
        }
        let xPositions = xPositions(in: rect)
        let y = rect.minY - 14
        var indices = Array(stride(from: 0, to: count, by: step))
        if indices.last != count - 1 {
            indices.append(count - 1)
        }
        for index in indices {
            let text = labels[index]
            let x = xPositions[index]
            drawClampedLabel(text, center: NSPoint(x: x, y: y), within: rect, attributes: attributes)
        }
    }
    
    private func drawLineChart(in rect: NSRect, maxValue: Double) {
        let count = series.count
        guard count > 0 else { return }
        let xPositions = xPositions(in: rect)
        let path = NSBezierPath()
        
        for (index, item) in series.enumerated() {
            let x = xPositions[index]
            let y = yPosition(for: item.value, in: rect, maxValue: maxValue)
            let point = NSPoint(x: x, y: y)
            if index == 0 {
                path.move(to: point)
            } else {
                path.line(to: point)
            }
        }
        
        NSColor.systemBlue.setStroke()
        path.lineWidth = 2
        path.stroke()
        
        for (index, item) in series.enumerated() {
            let x = xPositions[index]
            let y = yPosition(for: item.value, in: rect, maxValue: maxValue)
            let dotRect = NSRect(x: x - 2.5, y: y - 2.5, width: 5, height: 5)
            let dot = NSBezierPath(ovalIn: dotRect)
            NSColor.systemBlue.setFill()
            dot.fill()
        }
    }
    
    private func drawBarChart(in rect: NSRect, maxValue: Double) {
        let count = series.count
        guard count > 0 else { return }
        let stepX = rect.width / CGFloat(count)
        let barWidth = min(stepX * 0.6, 22)
        
        for (index, item) in series.enumerated() {
            let height = (CGFloat(item.value) / CGFloat(maxValue)) * rect.height
            let x = rect.minX + CGFloat(index) * stepX + (stepX - barWidth) / 2
            let barRect = NSRect(x: x, y: rect.minY, width: barWidth, height: height)
            let barPath = NSBezierPath(roundedRect: barRect, xRadius: 2, yRadius: 2)
            NSColor.systemBlue.setFill()
            barPath.fill()
        }
    }
    
    private func drawHover(in rect: NSRect, maxValue: Double, backgroundRect: NSRect) {
        guard let hoverIndex = hoverIndex, hoverIndex >= 0, hoverIndex < series.count else { return }
        let xPositions = xPositions(in: rect)
        let value = series[hoverIndex].value
        let x = xPositions[hoverIndex]
        let y = yPosition(for: value, in: rect, maxValue: maxValue)
        
        let crosshairColor = NSColor.systemBlue.withAlphaComponent(0.25)
        let crosshairPath = NSBezierPath()
        crosshairPath.move(to: NSPoint(x: x, y: rect.minY))
        crosshairPath.line(to: NSPoint(x: x, y: rect.maxY))
        crosshairPath.move(to: NSPoint(x: rect.minX, y: y))
        crosshairPath.line(to: NSPoint(x: rect.maxX, y: y))
        crosshairColor.setStroke()
        crosshairPath.lineWidth = 1
        crosshairPath.stroke()
        
        let radius: CGFloat = 5
        let dotRect = NSRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
        let dot = NSBezierPath(ovalIn: dotRect)
        NSColor.systemBlue.setFill()
        dot.fill()
        NSColor.white.withAlphaComponent(0.9).setStroke()
        dot.lineWidth = 2
        dot.stroke()
        
        let hoverAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ]
        
        drawLabel(formatValue(value), at: NSPoint(x: rect.minX - 4, y: y), alignment: .right, attributes: hoverAttributes)
        
        let dateLabel = dateLabel(for: series[hoverIndex].date)
        drawClampedLabel(dateLabel, center: NSPoint(x: x, y: rect.minY - 14), within: backgroundRect, attributes: hoverAttributes)
    }
    
    private func updateHoverIndex(for location: NSPoint) {
        guard !series.isEmpty else {
            hoverIndex = nil
            return
        }
        let backgroundRect = bounds.insetBy(dx: 6, dy: 6)
        let rect = plotRect(in: backgroundRect)
        guard rect.contains(location) else {
            hoverIndex = nil
            return
        }
        let positions = xPositions(in: rect)
        var nearestIndex = 0
        var nearestDistance = abs(location.x - positions[0])
        for (index, x) in positions.enumerated() {
            let distance = abs(location.x - x)
            if distance < nearestDistance {
                nearestDistance = distance
                nearestIndex = index
            }
        }
        hoverIndex = nearestIndex
    }
    
    private func plotRect(in rect: NSRect) -> NSRect {
        let leftPadding: CGFloat = 36
        let rightPadding: CGFloat = 10
        let topPadding: CGFloat = 10
        let bottomPadding: CGFloat = 20
        let width = max(1, rect.width - leftPadding - rightPadding)
        let height = max(1, rect.height - topPadding - bottomPadding)
        return NSRect(
            x: rect.minX + leftPadding,
            y: rect.minY + bottomPadding,
            width: width,
            height: height
        )
    }
    
    private func xPositions(in rect: NSRect) -> [CGFloat] {
        let count = series.count
        guard count > 0 else { return [] }
        if count == 1 {
            return [rect.midX]
        }
        switch style {
        case .bar:
            let stepX = rect.width / CGFloat(count)
            return (0..<count).map { rect.minX + (CGFloat($0) + 0.5) * stepX }
        case .line:
            let stepX = rect.width / CGFloat(count - 1)
            return (0..<count).map { rect.minX + CGFloat($0) * stepX }
        }
    }
    
    private func yPosition(for value: Double, in rect: NSRect, maxValue: Double) -> CGFloat {
        let ratio = maxValue > 0 ? CGFloat(value / maxValue) : 0
        return rect.minY + ratio * rect.height
    }
    
    private func formatValue(_ value: Double) -> String {
        return StatsManager.shared.formatHistoryValue(metric: metric, value: value)
    }
    
    private func dateLabel(for date: Date) -> String {
        return dayDateFormatter.string(from: date)
    }
    
    private enum LabelAlignment {
        case left
        case center
        case right
    }
    
    private func drawLabel(_ text: String, at point: NSPoint, alignment: LabelAlignment, attributes: [NSAttributedString.Key: Any]) {
        let size = text.size(withAttributes: attributes)
        var x = point.x
        switch alignment {
        case .left:
            break
        case .center:
            x -= size.width / 2
        case .right:
            x -= size.width
        }
        let y = point.y - size.height / 2
        text.draw(at: NSPoint(x: x, y: y), withAttributes: attributes)
    }
    
    private func drawClampedLabel(_ text: String, center: NSPoint, within rect: NSRect, attributes: [NSAttributedString.Key: Any]) {
        let size = text.size(withAttributes: attributes)
        var x = center.x - size.width / 2
        x = min(max(x, rect.minX), rect.maxX - size.width)
        let y = center.y - size.height / 2
        text.draw(at: NSPoint(x: x, y: y), withAttributes: attributes)
    }
}
