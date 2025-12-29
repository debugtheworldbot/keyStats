import Cocoa

/// 统计详情弹出视图控制器
class StatsPopoverViewController: NSViewController {
    
    // MARK: - UI 组件
    private var containerView: NSView!
    private var titleLabel: NSTextField!
    private var dateLabel: NSTextField!
    private var statsStackView: NSStackView!
    private var keyBreakdownTitleLabel: NSTextField!
    private var keyBreakdownScrollView: NSScrollView!
    private var keyBreakdownContentView: NSView!
    private var keyBreakdownStackView: NSStackView!
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
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - UI 设置
    
    private func setupUI() {
        // 标题
        titleLabel = createLabel(text: "KeyStats", fontSize: 18, weight: .bold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(titleLabel)
        
        // 日期
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy年MM月dd日"
        dateLabel = createLabel(text: dateFormatter.string(from: Date()), fontSize: 12, weight: .regular)
        dateLabel.textColor = .secondaryLabelColor
        dateLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(dateLabel)
        
        // 分隔线
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(separator)
        
        // 统计项
        keyPressView = StatItemView(icon: "⌨️", title: "键盘敲击", value: "0")
        leftClickView = StatItemView(icon: "🖱️", title: "左键点击", value: "0")
        rightClickView = StatItemView(icon: "🖱️", title: "右键点击", value: "0")
        mouseDistanceView = StatItemView(icon: "↔️", title: "鼠标移动", value: "0 px")
        scrollDistanceView = StatItemView(icon: "↕️", title: "滚动距离", value: "0 px")
        
        statsStackView = NSStackView(views: [
            keyPressView,
            leftClickView,
            rightClickView,
            mouseDistanceView,
            scrollDistanceView
        ])
        statsStackView.orientation = .vertical
        statsStackView.spacing = 8
        statsStackView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statsStackView)

        // 键位统计标题
        keyBreakdownTitleLabel = createLabel(text: "键位统计", fontSize: 14, weight: .semibold)
        keyBreakdownTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(keyBreakdownTitleLabel)

        // 键位统计列表
        keyBreakdownScrollView = NSScrollView()
        keyBreakdownScrollView.drawsBackground = false
        keyBreakdownScrollView.hasVerticalScroller = true
        keyBreakdownScrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(keyBreakdownScrollView)

        keyBreakdownContentView = NSView()
        keyBreakdownContentView.translatesAutoresizingMaskIntoConstraints = false
        keyBreakdownScrollView.documentView = keyBreakdownContentView

        keyBreakdownStackView = NSStackView()
        keyBreakdownStackView.orientation = .vertical
        keyBreakdownStackView.spacing = 6
        keyBreakdownStackView.alignment = .leading
        keyBreakdownStackView.translatesAutoresizingMaskIntoConstraints = false
        keyBreakdownContentView.addSubview(keyBreakdownStackView)

        // 历史趋势标题
        historyTitleLabel = createLabel(text: "历史趋势", fontSize: 14, weight: .semibold)
        historyTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(historyTitleLabel)
        
        // 时间范围
        rangeControl = NSSegmentedControl(labels: ["今天", "昨天", "本周", "本月"],
                                          trackingMode: .selectOne,
                                          target: self,
                                          action: #selector(historyControlsChanged))
        rangeControl.selectedSegment = 0
        rangeControl.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(rangeControl)
        
        // 指标选择
        metricControl = NSSegmentedControl(labels: ["键盘", "点击", "移动", "滚轮"],
                                           trackingMode: .selectOne,
                                           target: self,
                                           action: #selector(historyControlsChanged))
        metricControl.selectedSegment = 0
        metricControl.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(metricControl)
        
        // 图表样式
        chartStyleControl = NSSegmentedControl(labels: ["折线", "柱状"],
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
        historySummaryLabel = createLabel(text: "总计: 0", fontSize: 12, weight: .regular)
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
        resetButton = NSButton(title: "重置统计", target: self, action: #selector(resetStats))
        resetButton.bezelStyle = .rounded
        resetButton.controlSize = .regular
        
        // 退出按钮
        quitButton = NSButton(title: "退出应用", target: self, action: #selector(quitApp))
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
            
            // 日期
            dateLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            dateLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            
            // 分隔线
            separator.topAnchor.constraint(equalTo: dateLabel.bottomAnchor, constant: 12),
            separator.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            separator.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            
            // 统计项
            statsStackView.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 12),
            statsStackView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            statsStackView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            
            // 键位统计
            keyBreakdownTitleLabel.topAnchor.constraint(equalTo: statsStackView.bottomAnchor, constant: 16),
            keyBreakdownTitleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),

            keyBreakdownScrollView.topAnchor.constraint(equalTo: keyBreakdownTitleLabel.bottomAnchor, constant: 8),
            keyBreakdownScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            keyBreakdownScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            keyBreakdownScrollView.heightAnchor.constraint(equalToConstant: 120),

            keyBreakdownContentView.leadingAnchor.constraint(equalTo: keyBreakdownScrollView.contentView.leadingAnchor),
            keyBreakdownContentView.trailingAnchor.constraint(equalTo: keyBreakdownScrollView.contentView.trailingAnchor),
            keyBreakdownContentView.topAnchor.constraint(equalTo: keyBreakdownScrollView.contentView.topAnchor),
            keyBreakdownContentView.bottomAnchor.constraint(equalTo: keyBreakdownScrollView.contentView.bottomAnchor),
            keyBreakdownContentView.widthAnchor.constraint(equalTo: keyBreakdownScrollView.widthAnchor),

            keyBreakdownStackView.leadingAnchor.constraint(equalTo: keyBreakdownContentView.leadingAnchor),
            keyBreakdownStackView.trailingAnchor.constraint(equalTo: keyBreakdownContentView.trailingAnchor),
            keyBreakdownStackView.topAnchor.constraint(equalTo: keyBreakdownContentView.topAnchor),
            keyBreakdownStackView.bottomAnchor.constraint(equalTo: keyBreakdownContentView.bottomAnchor),

            // 历史趋势
            historyTitleLabel.topAnchor.constraint(equalTo: keyBreakdownScrollView.bottomAnchor, constant: 16),
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
    }
    
    private func formatNumber(_ number: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: number)) ?? "\(number)"
    }

    private func updateKeyBreakdown() {
        let items = StatsManager.shared.keyPressBreakdownSorted()
        keyBreakdownStackView.arrangedSubviews.forEach {
            keyBreakdownStackView.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        guard !items.isEmpty else {
            let emptyLabel = createLabel(text: "暂无键位数据", fontSize: 12, weight: .regular)
            emptyLabel.textColor = .secondaryLabelColor
            emptyLabel.translatesAutoresizingMaskIntoConstraints = false
            keyBreakdownStackView.addArrangedSubview(emptyLabel)
            emptyLabel.widthAnchor.constraint(equalTo: keyBreakdownStackView.widthAnchor).isActive = true
            return
        }
        for item in items {
            let row = KeyCountRowView(key: item.key, count: formatNumber(item.count))
            keyBreakdownStackView.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: keyBreakdownStackView.widthAnchor).isActive = true
        }
    }

    @objc private func historyControlsChanged() {
        updateHistorySection()
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
        historySummaryLabel.stringValue = "总计: \(formatted)"
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
        alert.messageText = "确认重置"
        alert.informativeText = "确定要重置今日的所有统计数据吗？此操作不可撤销。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "重置")
        alert.addButton(withTitle: "取消")
        
        if alert.runModal() == .alertFirstButtonReturn {
            StatsManager.shared.resetStats()
        }
    }
    
    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
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
            let text = "无数据"
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
