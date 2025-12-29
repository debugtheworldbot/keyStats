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
        
        // 监听统计更新通知
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(statsDidUpdate),
            name: .statsDidUpdate,
            object: nil
        )
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        updatePermissionButtonVisibility()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        focusPrimaryControl()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
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
        clickRow.spacing = 12
        clickRow.distribution = .fillEqually
        clickRow.alignment = .centerY
        clickRow.translatesAutoresizingMaskIntoConstraints = false

        let distanceRow = NSStackView(views: [mouseDistanceView, scrollDistanceView])
        distanceRow.orientation = .horizontal
        distanceRow.spacing = 12
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
            NSLocalizedString("history.range.today", comment: ""),
            NSLocalizedString("history.range.yesterday", comment: ""),
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
    
    @objc private func statsDidUpdate() {
        DispatchQueue.main.async { [weak self] in
            self?.updateStats()
        }
    }
    
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
        chartView.values = series.map { $0.value }
        chartView.style = style
        
        let total = series.reduce(0) { $0 + $1.value }
        let formatted = StatsManager.shared.formatHistoryValue(metric: metric, value: total)
        historySummaryLabel.stringValue = String(format: NSLocalizedString("history.total", comment: ""), formatted)
    }
    
    private func selectedRange() -> StatsManager.HistoryRange {
        switch rangeControl.selectedSegment {
        case 0: return .today
        case 1: return .yesterday
        case 2: return .week
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
            iconLabel.widthAnchor.constraint(equalToConstant: 30),
            
            titleLabel.leadingAnchor.constraint(equalTo: iconLabel.trailingAnchor, constant: 8),
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

    init(key: String, count: String) {
        super.init(frame: .zero)
        setupUI(key: key, count: count)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI(key: String, count: String) {
        translatesAutoresizingMaskIntoConstraints = false

        keyLabel = NSTextField(labelWithString: key)
        keyLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
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
        keyLabel.stringValue = key
        countLabel.stringValue = count
    }
}

// MARK: - 图表视图

class StatsChartView: NSView {
    enum Style {
        case line
        case bar
    }
    
    var values: [Double] = [] {
        didSet { needsDisplay = true }
    }
    
    var style: Style = .line {
        didSet { needsDisplay = true }
    }
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        
        let insetBounds = bounds.insetBy(dx: 6, dy: 6)
        let gridColor = NSColor.separatorColor.withAlphaComponent(0.35)
        
        NSColor.controlBackgroundColor.withAlphaComponent(0.15).setFill()
        NSBezierPath(roundedRect: insetBounds, xRadius: 6, yRadius: 6).fill()
        
        guard let maxValue = values.max(), maxValue > 0 else {
            let text = NSLocalizedString("history.empty", comment: "")
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            let size = text.size(withAttributes: attributes)
            let point = NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2)
            text.draw(at: point, withAttributes: attributes)
            return
        }
        
        // Grid
        for i in 1...3 {
            let y = insetBounds.minY + insetBounds.height * CGFloat(i) / 4
            let path = NSBezierPath()
            path.move(to: NSPoint(x: insetBounds.minX, y: y))
            path.line(to: NSPoint(x: insetBounds.maxX, y: y))
            gridColor.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        
        switch style {
        case .line:
            drawLineChart(in: insetBounds, maxValue: maxValue)
        case .bar:
            drawBarChart(in: insetBounds, maxValue: maxValue)
        }
    }
    
    private func drawLineChart(in rect: NSRect, maxValue: Double) {
        let count = max(values.count, 1)
        let stepX = count > 1 ? rect.width / CGFloat(count - 1) : 0
        let path = NSBezierPath()
        
        for (index, value) in values.enumerated() {
            let x = rect.minX + CGFloat(index) * stepX
            let y = rect.minY + (CGFloat(value) / CGFloat(maxValue)) * rect.height
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
        
        for (index, value) in values.enumerated() {
            let x = rect.minX + CGFloat(index) * stepX
            let y = rect.minY + (CGFloat(value) / CGFloat(maxValue)) * rect.height
            let dotRect = NSRect(x: x - 2.5, y: y - 2.5, width: 5, height: 5)
            let dot = NSBezierPath(ovalIn: dotRect)
            NSColor.systemBlue.setFill()
            dot.fill()
        }
    }
    
    private func drawBarChart(in rect: NSRect, maxValue: Double) {
        let count = max(values.count, 1)
        let stepX = rect.width / CGFloat(count)
        let barWidth = min(stepX * 0.6, 22)
        
        for (index, value) in values.enumerated() {
            let height = (CGFloat(value) / CGFloat(maxValue)) * rect.height
            let x = rect.minX + CGFloat(index) * stepX + (stepX - barWidth) / 2
            let barRect = NSRect(x: x, y: rect.minY, width: barWidth, height: height)
            let barPath = NSBezierPath(roundedRect: barRect, xRadius: 2, yRadius: 2)
            NSColor.systemBlue.setFill()
            barPath.fill()
        }
    }
}
