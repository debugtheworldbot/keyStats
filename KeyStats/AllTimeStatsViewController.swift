import Cocoa

class AllTimeStatsViewController: NSViewController {
    
    // MARK: - UI 组件
    private var scrollView: NSScrollView!
    private var documentView: NSView!
    private var containerStack: NSStackView!
    private var headerLabel: NSTextField!
    private var dateRangeLabel: NSTextField!
    
    // 统计卡片
    private var cardsGrid: NSStackView!
    private var keyPressCard: BigStatCard!
    private var clickCard: BigStatCard!
    private var mouseDistCard: BigStatCard!
    private var scrollDistCard: BigStatCard!
    
    // 洞察分析
    private var insightsTitle: NSTextField!
    private var insightsGrid: NSStackView!
    
    // 键位列表
    private var keyListTitle: NSTextField!
    private var keyListStack: NSStackView!
    private var keyListContainer: NSStackView!
    private var keyPieChartView: TopKeysPieChartView!
    
    override func loadView() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 540, height: 700))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        self.view = view
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        refreshData()
    }
    
    private func setupUI() {
        // 滚动视图
        scrollView = NSScrollView(frame: view.bounds)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        view.addSubview(scrollView)
        
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        
        documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView
        
        // 主容器
        containerStack = NSStackView()
        containerStack.orientation = .vertical
        containerStack.alignment = .centerX
        containerStack.spacing = 32
        containerStack.edgeInsets = NSEdgeInsets(top: 30, left: 30, bottom: 30, right: 30)
        containerStack.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(containerStack)
        
        NSLayoutConstraint.activate([
            containerStack.topAnchor.constraint(equalTo: documentView.topAnchor),
            containerStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            containerStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            containerStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
            containerStack.widthAnchor.constraint(equalTo: scrollView.widthAnchor)
        ])
        
        // 1. 头部区域
        let headerStack = NSStackView()
        headerStack.orientation = .vertical
        headerStack.alignment = .centerX
        headerStack.spacing = 8
        
        headerLabel = NSTextField(labelWithString: NSLocalizedString("allTimeStats.title", comment: ""))
        headerLabel.font = NSFont.systemFont(ofSize: 28, weight: .bold)
        headerLabel.textColor = .labelColor
        
        dateRangeLabel = NSTextField(labelWithString: "-")
        dateRangeLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        dateRangeLabel.textColor = .secondaryLabelColor
        
        headerStack.addArrangedSubview(headerLabel)
        headerStack.addArrangedSubview(dateRangeLabel)
        containerStack.addArrangedSubview(headerStack)
        
        // 2. 统计卡片网格 (2x2)
        cardsGrid = NSStackView()
        cardsGrid.translatesAutoresizingMaskIntoConstraints = false
        cardsGrid.orientation = .vertical
        cardsGrid.spacing = 16
        cardsGrid.distribution = .fillEqually
        cardsGrid.wantsLayer = true
        
        let row1 = NSStackView()
        row1.translatesAutoresizingMaskIntoConstraints = false
        row1.distribution = .fillEqually
        row1.spacing = 16
        
        keyPressCard = BigStatCard(icon: "⌨️", title: NSLocalizedString("stats.keyPresses", comment: ""), color: .systemBlue)
        clickCard = BigStatCard(icon: "🖱️", title: NSLocalizedString("stats.totalClicks", comment: ""), color: .systemOrange)
        
        row1.addArrangedSubview(keyPressCard)
        row1.addArrangedSubview(clickCard)
        
        let row2 = NSStackView()
        row2.translatesAutoresizingMaskIntoConstraints = false
        row2.distribution = .fillEqually
        row2.spacing = 16
        
        mouseDistCard = BigStatCard(icon: "↔️", title: NSLocalizedString("stats.mouseDistance", comment: ""), color: .systemGreen)
        scrollDistCard = BigStatCard(icon: "↕️", title: NSLocalizedString("stats.scrollDistance", comment: ""), color: .systemPurple)
        
        row2.addArrangedSubview(mouseDistCard)
        row2.addArrangedSubview(scrollDistCard)
        
        cardsGrid.addArrangedSubview(row1)
        cardsGrid.addArrangedSubview(row2)

        containerStack.addArrangedSubview(cardsGrid)
        
        row1.widthAnchor.constraint(equalTo: cardsGrid.widthAnchor).isActive = true
        row2.widthAnchor.constraint(equalTo: cardsGrid.widthAnchor).isActive = true
        cardsGrid.widthAnchor.constraint(equalTo: containerStack.widthAnchor, constant: -40).isActive = true
        
        keyPressCard.heightAnchor.constraint(equalToConstant: 110).isActive = true
        mouseDistCard.heightAnchor.constraint(equalToConstant: 110).isActive = true

        // 3. 洞察分析区域
        let insightsSectionStack = NSStackView()
        insightsSectionStack.translatesAutoresizingMaskIntoConstraints = false
        insightsSectionStack.orientation = .vertical
        insightsSectionStack.alignment = .leading
        insightsSectionStack.spacing = 16
        
        insightsTitle = NSTextField(labelWithString: NSLocalizedString("allTimeStats.insights", comment: ""))
        insightsTitle.font = NSFont.systemFont(ofSize: 18, weight: .semibold)
        insightsTitle.textColor = .labelColor
        insightsSectionStack.addArrangedSubview(insightsTitle)
        
        insightsGrid = NSStackView()
        insightsGrid.orientation = .vertical
        insightsGrid.spacing = 12
        insightsGrid.distribution = .fill
        insightsGrid.alignment = .leading
        insightsGrid.translatesAutoresizingMaskIntoConstraints = false
        insightsSectionStack.addArrangedSubview(insightsGrid)
        
        containerStack.addArrangedSubview(insightsSectionStack)
        insightsSectionStack.widthAnchor.constraint(equalTo: containerStack.widthAnchor, constant: -40).isActive = true
        insightsGrid.widthAnchor.constraint(equalTo: insightsSectionStack.widthAnchor).isActive = true

        // 4. 键位列表区域
        let listSectionStack = NSStackView()
        listSectionStack.translatesAutoresizingMaskIntoConstraints = false
        listSectionStack.orientation = .vertical
        listSectionStack.alignment = .leading
        listSectionStack.spacing = 16
        
        keyListTitle = NSTextField(labelWithString: NSLocalizedString("allTimeStats.topKeys", comment: ""))
        keyListTitle.font = NSFont.systemFont(ofSize: 18, weight: .semibold)
        keyListTitle.textColor = .labelColor
        
        listSectionStack.addArrangedSubview(keyListTitle)
        
        keyListStack = NSStackView()
        keyListStack.orientation = .horizontal
        keyListStack.alignment = .top
        keyListStack.spacing = 24
        keyListStack.translatesAutoresizingMaskIntoConstraints = false
        listSectionStack.addArrangedSubview(keyListStack)
        
        keyPieChartView = TopKeysPieChartView()
        keyPieChartView.translatesAutoresizingMaskIntoConstraints = false
        keyListStack.addArrangedSubview(keyPieChartView)
        
        keyListContainer = NSStackView()
        keyListContainer.translatesAutoresizingMaskIntoConstraints = false
        keyListContainer.orientation = .vertical
        keyListContainer.spacing = 10
        keyListContainer.alignment = .leading
        keyListStack.addArrangedSubview(keyListContainer)
        
        containerStack.addArrangedSubview(listSectionStack)
        
        listSectionStack.widthAnchor.constraint(equalTo: containerStack.widthAnchor, constant: -40).isActive = true
        keyListStack.widthAnchor.constraint(equalTo: listSectionStack.widthAnchor).isActive = true
        keyPieChartView.widthAnchor.constraint(equalToConstant: 180).isActive = true
        keyPieChartView.heightAnchor.constraint(equalToConstant: 180).isActive = true
        keyListContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        
        // 底部弹簧
        containerStack.addArrangedSubview(NSView())
    }
    
    func refreshData() {
        let stats = StatsManager.shared.getAllTimeStats()
        
        // 更新日期范围
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .none
        
        if let first = stats.firstDate, let last = stats.lastDate {
            let start = dateFormatter.string(from: first)
            let end = dateFormatter.string(from: last)
            let days = Calendar.current.dateComponents([.day], from: first, to: last).day ?? 0
            let totalDays = days + 1
            let format = NSLocalizedString("allTimeStats.rangeFormat", comment: "")
            dateRangeLabel.stringValue = String(format: format, start, end, totalDays)
        } else {
            dateRangeLabel.stringValue = NSLocalizedString("allTimeStats.noData", comment: "")
        }
        
        keyPressCard.setValue(formatNumber(stats.totalKeyPresses))
        clickCard.setValue(formatNumber(stats.totalClicks))
        mouseDistCard.setValue(stats.formattedMouseDistance)
        scrollDistCard.setValue(stats.formattedScrollDistance)

        updateInsights(stats)
        updateTopKeys(stats.keyPressCounts)
    }
    
    private func updateInsights(_ stats: AllTimeStats) {
        let oldRows = insightsGrid.arrangedSubviews
        for row in oldRows {
            insightsGrid.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        
        guard stats.activeDays > 0 else {
            let emptyLabel = NSTextField(labelWithString: NSLocalizedString("allTimeStats.noData", comment: ""))
            emptyLabel.textColor = .secondaryLabelColor
            insightsGrid.addArrangedSubview(emptyLabel)
            return
        }
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .none
        
        // 1. 巅峰单日 (Keys & Clicks)
        let peakRow = NSStackView()
        peakRow.orientation = .horizontal
        peakRow.distribution = .fillEqually
        peakRow.spacing = 16
        peakRow.translatesAutoresizingMaskIntoConstraints = false
        
        let maxKeysDateStr = stats.maxDailyKeyPressesDate.map { dateFormatter.string(from: $0) } ?? "-"
        let maxClicksDateStr = stats.maxDailyClicksDate.map { dateFormatter.string(from: $0) } ?? "-"
        
        let maxKeysItem = InsightItemView(
            title: NSLocalizedString("allTimeStats.maxDailyKeyPresses", comment: ""),
            value: formatNumber(stats.maxDailyKeyPresses),
            subtitle: maxKeysDateStr,
            icon: "🔥"
        )
        
        let maxClicksItem = InsightItemView(
            title: NSLocalizedString("allTimeStats.maxDailyClicks", comment: ""),
            value: formatNumber(stats.maxDailyClicks),
            subtitle: maxClicksDateStr,
            icon: "⚡️"
        )
        
        peakRow.addArrangedSubview(maxKeysItem)
        peakRow.addArrangedSubview(maxClicksItem)
        
        insightsGrid.addArrangedSubview(peakRow)
        peakRow.widthAnchor.constraint(equalTo: insightsGrid.widthAnchor).isActive = true
        
        // 2. 每日平均 (Keys & Clicks)
        let avgRow = NSStackView()
        avgRow.orientation = .horizontal
        avgRow.distribution = .fillEqually
        avgRow.spacing = 16
        avgRow.translatesAutoresizingMaskIntoConstraints = false
        
        let avgKeys: Int
        let avgClicks: Int
        if stats.keyActiveDays > 0 {
            avgKeys = Int((Double(stats.totalKeyPresses) / Double(stats.keyActiveDays)).rounded())
        } else {
            avgKeys = 0
        }
        if stats.clickActiveDays > 0 {
            avgClicks = Int((Double(stats.totalClicks) / Double(stats.clickActiveDays)).rounded())
        } else {
            avgClicks = 0
        }
        
        let avgKeysItem = InsightItemView(
            title: NSLocalizedString("allTimeStats.avgKeyPressesPerDay", comment: ""),
            value: formatNumber(avgKeys),
            subtitle: NSLocalizedString("insights.dailyAvg", comment: ""),
            icon: "📊"
        )
        
        let avgClicksItem = InsightItemView(
            title: NSLocalizedString("allTimeStats.avgClicksPerDay", comment: ""),
            value: formatNumber(avgClicks),
            subtitle: NSLocalizedString("insights.dailyAvg", comment: ""),
            icon: "📈"
        )
        
        avgRow.addArrangedSubview(avgKeysItem)
        avgRow.addArrangedSubview(avgClicksItem)
        
        insightsGrid.addArrangedSubview(avgRow)
        avgRow.widthAnchor.constraint(equalTo: insightsGrid.widthAnchor).isActive = true
        
        // 3. 点击占比
        let ratioRow = ClickRatioView(leftClicks: stats.totalLeftClicks, rightClicks: stats.totalRightClicks)
        insightsGrid.addArrangedSubview(ratioRow)
        ratioRow.widthAnchor.constraint(equalTo: insightsGrid.widthAnchor).isActive = true
        
        // 4. 趣味统计 (Peak Weekday & Marathon & Everest)
        let funRow = NSStackView()
        funRow.orientation = .horizontal
        funRow.distribution = .fillEqually
        funRow.spacing = 16
        funRow.translatesAutoresizingMaskIntoConstraints = false
        
        // Efficiency Peak
        var weekdayStr = "-"
        if let weekday = stats.mostActiveWeekday {
            // weekday: 1=Sun, 2=Mon, ..., 7=Sat
            let symbols = dateFormatter.shortWeekdaySymbols ?? []
            // shortWeekdaySymbols 索引 0=Sun, 1=Mon...
            // 所以直接用 weekday - 1 即可
            if weekday >= 1 && weekday <= symbols.count {
                weekdayStr = symbols[weekday - 1]
            }
        }
        let peakWeekdayItem = InsightItemView(
            title: NSLocalizedString("allTimeStats.mostActiveWeekday", comment: ""),
            value: weekdayStr,
            subtitle: NSLocalizedString("insights.subtitle.weeklyBest", comment: ""),
            icon: "🏆",
            tooltip: NSLocalizedString("insights.tooltip.peakWeekday", comment: "")
        )
        
        // Marathon Mouse (42.195 km = 42195 m)
        let metersPerPixel = 0.000264583
        let totalMeters = stats.totalMouseDistance * metersPerPixel
        let marathons = totalMeters / 42195.0
        let marathonStr = String(format: NSLocalizedString("insights.marathon", comment: ""), marathons)
        
        let marathonItem = InsightItemView(
            title: NSLocalizedString("allTimeStats.marathonMouse", comment: ""),
            value: String(format: "%.2f", marathons),
            subtitle: NSLocalizedString("insights.subtitle.marathons", comment: ""),
            icon: "🏃",
            tooltip: String(format: NSLocalizedString("insights.tooltip.marathon", comment: ""), marathons)
        )
        
        // Everest Scroll (8848 m)
        let totalScrollMeters = stats.totalScrollDistance * metersPerPixel // Assuming same scale for rough estimate
        let everests = totalScrollMeters / 8848.0
        let everestStr = String(format: NSLocalizedString("insights.everest", comment: ""), everests)
        
        let everestItem = InsightItemView(
            title: NSLocalizedString("allTimeStats.everestScroll", comment: ""),
            value: String(format: "%.2f", everests),
            subtitle: NSLocalizedString("insights.subtitle.everests", comment: ""),
            icon: "🏔️",
            tooltip: String(format: NSLocalizedString("insights.tooltip.everest", comment: ""), everests)
        )
        
        funRow.addArrangedSubview(peakWeekdayItem)
        funRow.addArrangedSubview(marathonItem)
        funRow.addArrangedSubview(everestItem)
        
        insightsGrid.addArrangedSubview(funRow)
        funRow.widthAnchor.constraint(equalTo: insightsGrid.widthAnchor).isActive = true
        
        // 5. 新增统计 (Perfectionist & Input Style)
        let extraRow = NSStackView()
        extraRow.orientation = .horizontal
        extraRow.distribution = .fillEqually
        extraRow.spacing = 16
        extraRow.translatesAutoresizingMaskIntoConstraints = false
        
        // Perfectionist (Correction Rate)
        let correctionRate = stats.correctionRate * 100
        let correctionStr = String(format: "%.1f%%", correctionRate)
        let correctionItem = InsightItemView(
            title: NSLocalizedString("insights.perfectionist", comment: ""),
            value: correctionStr,
            subtitle: NSLocalizedString("insights.subtitle.backspaceDel", comment: ""),
            icon: "🔙",
            tooltip: NSLocalizedString("insights.tooltip.perfectionist", comment: "")
        )
        
        // Input Style (Keys / Clicks)
        let ratio = stats.inputRatio
        var styleText = ""
        var styleIcon = ""
        if ratio > 5.0 {
            styleText = NSLocalizedString("insights.style.keyboard", comment: "")
            styleIcon = "⌨️"
        } else if ratio < 1.0 {
            styleText = NSLocalizedString("insights.style.mouse", comment: "")
            styleIcon = "🖱️"
        } else {
            styleText = NSLocalizedString("insights.style.balanced", comment: "")
            styleIcon = "⚖️"
        }
        
        let styleItem = InsightItemView(
            title: NSLocalizedString("insights.inputStyle", comment: ""),
            value: styleText,
            subtitle: String(format: NSLocalizedString("insights.subtitle.ratioFormat", comment: ""), ratio),
            icon: styleIcon,
            tooltip: NSLocalizedString("insights.tooltip.inputStyle", comment: "")
        )
        
        extraRow.addArrangedSubview(correctionItem)
        extraRow.addArrangedSubview(styleItem)
        
        // Add a spacer to fill the row if needed, or just let it distribute equally
        // Since we have 2 items and previous rows had 2 or 3, let's keep it consistent.
        // If we want 3 columns layout, we might need an empty view.
        // But here we can just let them fill.
        
        insightsGrid.addArrangedSubview(extraRow)
        extraRow.widthAnchor.constraint(equalTo: insightsGrid.widthAnchor).isActive = true
    }

    private func updateTopKeys(_ counts: [String: Int]) {
        // 清除旧视图
        let oldRows = keyListContainer.arrangedSubviews
        for row in oldRows {
            keyListContainer.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        
        let sortedKeys = counts.sorted { $0.value > $1.value }.prefix(10) // 显示前10个
        
        if sortedKeys.isEmpty {
            keyPieChartView.entries = []
            let emptyLabel = NSTextField(labelWithString: NSLocalizedString("keyBreakdown.empty", comment: ""))
            emptyLabel.textColor = .secondaryLabelColor
            keyListContainer.addArrangedSubview(emptyLabel)
            return
        }

        keyPieChartView.entries = sortedKeys.map { ($0.key, $0.value) }

        let maxCount = Double(sortedKeys.first?.value ?? 1)

        for (index, item) in sortedKeys.enumerated() {
            let color = TopKeysPieChartView.colors[index % TopKeysPieChartView.colors.count]
            let row = TopKeyRowView(rank: index + 1, key: item.key, count: item.value, maxCount: maxCount, color: color)
            keyListContainer.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: keyListContainer.widthAnchor).isActive = true
        }
    }
    
    private func formatNumber(_ number: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: number)) ?? "\(number)"
    }
}

// MARK: - 组件：统计大卡片

class BigStatCard: NSView {
    private var valueLabel: NSTextField!
    
    init(icon: String, title: String, color: NSColor) {
        super.init(frame: .zero)
        self.wantsLayer = true
        self.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        self.layer?.cornerRadius = 16
        self.layer?.borderWidth = 1
        self.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.2).cgColor
        
        setupUI(icon: icon, title: title, color: color)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupUI(icon: String, title: String, color: NSColor) {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        
        // 标题行
        let titleStack = NSStackView()
        titleStack.spacing = 8
        
        let iconLabel = NSTextField(labelWithString: icon)
        iconLabel.font = NSFont.systemFont(ofSize: 20)
        
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        
        titleStack.addArrangedSubview(iconLabel)
        titleStack.addArrangedSubview(titleLabel)
        
        // 数值
        valueLabel = NSTextField(labelWithString: "0")
        valueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 28, weight: .bold)
        valueLabel.textColor = .labelColor
        
        stack.addArrangedSubview(titleStack)
        stack.addArrangedSubview(valueLabel)
    }
    
    func setValue(_ value: String) {
        valueLabel.stringValue = value
    }
}

// MARK: - 组件：洞察分析项

class InsightItemView: NSView {
    init(title: String, value: String, subtitle: String, icon: String, tooltip: String? = nil) {
        super.init(frame: .zero)
        self.wantsLayer = true
        self.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.5).cgColor
        self.layer?.cornerRadius = 12
        self.layer?.borderWidth = 1
        self.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.1).cgColor
        
        if let tooltip = tooltip {
            self.toolTip = tooltip
        }
        
        setupUI(title: title, value: value, subtitle: subtitle, icon: icon)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupUI(title: String, value: String, subtitle: String, icon: String) {
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(greaterThanOrEqualToConstant: 70).isActive = true
        
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -12)
        ])
        
        let headerStack = NSStackView()
        headerStack.spacing = 6
        
        let iconLabel = NSTextField(labelWithString: icon)
        iconLabel.font = NSFont.systemFont(ofSize: 14)
        
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        
        headerStack.addArrangedSubview(iconLabel)
        headerStack.addArrangedSubview(titleLabel)
        
        let valueLabel = NSTextField(labelWithString: value)
        valueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 18, weight: .semibold)
        valueLabel.textColor = .labelColor
        
        let subtitleLabel = NSTextField(labelWithString: subtitle)
        subtitleLabel.font = NSFont.systemFont(ofSize: 11)
        subtitleLabel.textColor = .tertiaryLabelColor
        
        stack.addArrangedSubview(headerStack)
        stack.addArrangedSubview(valueLabel)
        stack.addArrangedSubview(subtitleLabel)
    }
}

// MARK: - 组件：点击占比视图

class ClickRatioView: NSView {
    init(leftClicks: Int, rightClicks: Int) {
        super.init(frame: .zero)
        setupUI(leftClicks: leftClicks, rightClicks: rightClicks)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupUI(leftClicks: Int, rightClicks: Int) {
        self.wantsLayer = true
        self.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.5).cgColor
        self.layer?.cornerRadius = 12
        self.layer?.borderWidth = 1
        self.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.1).cgColor
        
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 80).isActive = true
        
        let total = max(1, leftClicks + rightClicks)
        let leftRatio = Double(leftClicks) / Double(total)
        let rightRatio = Double(rightClicks) / Double(total)
        
        let titleLabel = NSTextField(labelWithString: NSLocalizedString("insights.clickRatio", comment: ""))
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)
        
        // 进度条背景
        let barContainer = NSView()
        barContainer.wantsLayer = true
        barContainer.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.2).cgColor
        barContainer.layer?.cornerRadius = 6
        barContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(barContainer)
        
        // 左键占比 (蓝色)
        let leftBar = NSView()
        leftBar.wantsLayer = true
        leftBar.layer?.backgroundColor = NSColor.systemBlue.cgColor
        // 只设置左边的圆角有点麻烦，这里简单处理，整个 barContainer 是圆角
        // 如果 leftRatio 是 1.0，则全部蓝色
        leftBar.translatesAutoresizingMaskIntoConstraints = false
        barContainer.addSubview(leftBar)
        
        // 标签
        let leftLabel = NSTextField(labelWithString: "\(Int(leftRatio * 100))% L")
        leftLabel.font = NSFont.systemFont(ofSize: 12, weight: .bold)
        leftLabel.textColor = .systemBlue
        leftLabel.translatesAutoresizingMaskIntoConstraints = false
        
        let rightLabel = NSTextField(labelWithString: "R \(Int(rightRatio * 100))%")
        rightLabel.font = NSFont.systemFont(ofSize: 12, weight: .bold)
        rightLabel.textColor = .systemOrange
        rightLabel.translatesAutoresizingMaskIntoConstraints = false
        
        addSubview(leftLabel)
        addSubview(rightLabel)
        
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            
            barContainer.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            barContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            barContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            barContainer.heightAnchor.constraint(equalToConstant: 12),
            
            leftBar.leadingAnchor.constraint(equalTo: barContainer.leadingAnchor),
            leftBar.topAnchor.constraint(equalTo: barContainer.topAnchor),
            leftBar.bottomAnchor.constraint(equalTo: barContainer.bottomAnchor),
            leftBar.widthAnchor.constraint(equalTo: barContainer.widthAnchor, multiplier: max(0.01, leftRatio)),
            
            leftLabel.topAnchor.constraint(equalTo: barContainer.bottomAnchor, constant: 6),
            leftLabel.leadingAnchor.constraint(equalTo: barContainer.leadingAnchor),
            
            rightLabel.topAnchor.constraint(equalTo: barContainer.bottomAnchor, constant: 6),
            rightLabel.trailingAnchor.constraint(equalTo: barContainer.trailingAnchor)
        ])
    }
}

// MARK: - 组件：Top Key 行

class TopKeyRowView: NSView {
    init(rank: Int, key: String, count: Int, maxCount: Double, color: NSColor) {
        super.init(frame: .zero)
        setupUI(rank: rank, key: key, count: count, maxCount: maxCount, color: color)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupUI(rank: Int, key: String, count: Int, maxCount: Double, color: NSColor) {
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 32).isActive = true
        
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        
        let rankLabel = NSTextField(labelWithString: "\(rank)")
        rankLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        rankLabel.textColor = .tertiaryLabelColor
        rankLabel.widthAnchor.constraint(equalToConstant: 20).isActive = true
        
        let keyFont = NSFont.systemFont(ofSize: 14, weight: .medium)
        let keyAttributed = KeyCountRowView.attributedKeyLabel(for: key, font: keyFont)
        let keyLabel = NSTextField(labelWithAttributedString: keyAttributed)
        keyLabel.font = keyFont
        keyLabel.textColor = .labelColor
        keyLabel.lineBreakMode = .byTruncatingTail
        keyLabel.maximumNumberOfLines = 1
        keyLabel.cell?.truncatesLastVisibleLine = true
        keyLabel.toolTip = key
        keyLabel.widthAnchor.constraint(equalToConstant: 80).isActive = true
        
        // 进度条背景
        let barContainer = NSView()
        barContainer.wantsLayer = true
        barContainer.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.3).cgColor
        barContainer.layer?.cornerRadius = 4
        barContainer.translatesAutoresizingMaskIntoConstraints = false
        
        // 进度条前景
        let barFill = NSView()
        barFill.wantsLayer = true
        barFill.layer?.backgroundColor = color.withAlphaComponent(0.8).cgColor
        barFill.layer?.cornerRadius = 4
        barFill.translatesAutoresizingMaskIntoConstraints = false
        barContainer.addSubview(barFill)
        
        let ratio = maxCount > 0 ? CGFloat(count) / CGFloat(maxCount) : 0
        NSLayoutConstraint.activate([
            barFill.leadingAnchor.constraint(equalTo: barContainer.leadingAnchor),
            barFill.topAnchor.constraint(equalTo: barContainer.topAnchor),
            barFill.bottomAnchor.constraint(equalTo: barContainer.bottomAnchor),
            barFill.widthAnchor.constraint(equalTo: barContainer.widthAnchor, multiplier: max(0.01, ratio))
        ])
        
        // 计数值
        let countLabel = NSTextField(labelWithString: "\(count)")
        countLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        countLabel.textColor = .secondaryLabelColor
        countLabel.alignment = .right
        
        stack.addArrangedSubview(rankLabel)
        stack.addArrangedSubview(keyLabel)
        stack.addArrangedSubview(barContainer)
        stack.addArrangedSubview(countLabel)
        
        barContainer.heightAnchor.constraint(equalToConstant: 8).isActive = true
    }
}

class TopKeysPieChartView: NSView {
    static let colors: [NSColor] = [
        .systemBlue,
        .systemOrange,
        .systemGreen,
        .systemPurple,
        .systemPink,
        .systemRed,
        .systemTeal,
        .systemIndigo,
        .systemYellow,
        .systemBrown
    ]
    
    var entries: [(key: String, count: Int)] = [] {
        didSet {
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard !entries.isEmpty else {
            let text = NSLocalizedString("keyBreakdown.empty", comment: "")
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            let size = text.size(withAttributes: attributes)
            let point = NSPoint(
                x: bounds.midX - size.width / 2,
                y: bounds.midY - size.height / 2
            )
            text.draw(at: point, withAttributes: attributes)
            return
        }

        let total = entries.reduce(0) { $0 + $1.count }
        guard total > 0 else { return }

        let colors = Self.colors

        let inset: CGFloat = 8
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let radius = min(bounds.width, bounds.height) / 2 - inset

        var startAngle: CGFloat = 90

        for (index, entry) in entries.enumerated() {
            let fraction = CGFloat(entry.count) / CGFloat(total)
            let endAngle = startAngle - 360 * fraction

            let path = NSBezierPath()
            path.move(to: center)
            path.appendArc(
                withCenter: center,
                radius: radius,
                startAngle: startAngle,
                endAngle: endAngle,
                clockwise: true
            )
            path.close()

            let color = colors[index % colors.count].withAlphaComponent(0.85)
            color.setFill()
            path.fill()
            
            // 绘制分隔线
            if entries.count > 1 {
                NSColor.windowBackgroundColor.setStroke()
                path.lineWidth = 1
                path.stroke()
            }

            startAngle = endAngle
        }

        // 绘制空心圆
        let innerRadius = radius * 0.5
        let holePath = NSBezierPath(ovalIn: NSRect(
            x: center.x - innerRadius,
            y: center.y - innerRadius,
            width: innerRadius * 2,
            height: innerRadius * 2
        ))
        NSColor.windowBackgroundColor.setFill()
        holePath.fill()
    }
}
