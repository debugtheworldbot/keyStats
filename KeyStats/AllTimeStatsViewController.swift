import Cocoa

private func resolvedCGColor(_ color: NSColor, for view: NSView) -> CGColor {
    var resolved: CGColor = color.cgColor
    view.effectiveAppearance.performAsCurrentDrawingAppearance {
        resolved = color.cgColor
    }
    return resolved
}

private func resolvedColor(_ color: NSColor, for view: NSView) -> NSColor {
    let cgColor = resolvedCGColor(color, for: view)
    return NSColor(cgColor: cgColor) ?? color
}

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

    // MARK: - Animation Constants
    private let cardCascadeDelay: TimeInterval = 0.05
    private let insightRowCascadeDelay: TimeInterval = 0.08
    private let topKeyRowCascadeDelay: TimeInterval = 0.03
    private let visibilityCheckDelays: [TimeInterval] = [0, 0.05, 0.15, 0.3, 0.6]
    private var animatedViews = Set<ObjectIdentifier>()
    private var animationObserver: NSObjectProtocol?
    private var appearanceObservation: NSKeyValueObservation?
    private var isViewVisible = false

    deinit {
        if let observer = animationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        appearanceObservation = nil
    }
    
    override func loadView() {
        let view = AppearanceTrackingView(frame: NSRect(x: 0, y: 0, width: 540, height: 700))
        view.onEffectiveAppearanceChange = { [weak self] in
            self?.updateAppearance()
        }
        view.wantsLayer = true
        view.layer?.backgroundColor = resolvedCGColor(NSColor.windowBackgroundColor, for: view)
        self.view = view
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        refreshData()
        updateAppearance() // 初始化 appearance
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.updateAppearance()
            }
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        isViewVisible = true
        scrollToTop()
        scheduleVisibilityChecks()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        isViewVisible = false
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        checkVisibleAnimations()
    }
    
    private func setupUI() {
        // 滚动视图
        scrollView = NSScrollView(frame: view.bounds)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        animationObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.checkVisibleAnimations()
        }
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
        scheduleVisibilityChecks()
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
            let row = TopKeyRowView(
                rank: index + 1,
                key: item.key,
                count: item.value,
                maxCount: maxCount,
                color: color
            )
            keyListContainer.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: keyListContainer.widthAnchor).isActive = true
        }
    }

    private func animateBigStatCards() {
        let cards: [(BigStatCard, TimeInterval)] = [
            (keyPressCard, 0),
            (clickCard, cardCascadeDelay),
            (mouseDistCard, cardCascadeDelay * 2),
            (scrollDistCard, cardCascadeDelay * 3)
        ]

        for (card, delay) in cards where isViewInVisibleRect(card) {
            animateOnce(card) {
                card.animateIn(delay: delay)
            }
        }
    }

    private func animateInsightRow(_ row: NSStackView, index: Int) {
        let delay = insightRowCascadeDelay * TimeInterval(index)
        for case let item as InsightItemView in row.arrangedSubviews {
            item.animateIn(delay: delay)
        }
    }

    private func checkVisibleAnimations() {
        guard isViewVisible else { return }
        guard scrollView.window != nil else { return }
        documentView.layoutSubtreeIfNeeded()

        if isViewInVisibleRect(cardsGrid) {
            animateBigStatCards()
        }

        for (index, row) in insightsGrid.arrangedSubviews.enumerated() {
            guard isViewInVisibleRect(row) else { continue }
            if let ratioRow = row as? ClickRatioView {
                animateOnce(ratioRow) {
                    ratioRow.animateEntryIn(delay: insightRowCascadeDelay * TimeInterval(index))
                }
            } else if let stackRow = row as? NSStackView {
                animateOnce(stackRow) {
                    animateInsightRow(stackRow, index: index)
                }
            }
        }

        if isViewInVisibleRect(keyPieChartView) {
            animateOnce(keyPieChartView) {
                keyPieChartView.animateIn()
            }
        }

        for (index, row) in keyListContainer.arrangedSubviews.enumerated() {
            guard let keyRow = row as? TopKeyRowView else { continue }
            guard isViewInVisibleRect(keyRow) else { continue }
            animateOnce(keyRow) {
                keyRow.animateIn(delay: topKeyRowCascadeDelay * TimeInterval(index))
            }
        }
    }

    private func isViewInVisibleRect(_ view: NSView) -> Bool {
        let visibleRect = scrollView.contentView.bounds.insetBy(dx: 0, dy: -24)
        let viewRect = view.convert(view.bounds, to: scrollView.contentView)
        return viewRect.intersects(visibleRect)
    }

    private func animateOnce(_ view: NSView, action: () -> Void) {
        let identifier = ObjectIdentifier(view)
        guard !animatedViews.contains(identifier) else { return }
        animatedViews.insert(identifier)
        action()
    }

    private func scheduleVisibilityChecks() {
        for delay in visibilityCheckDelays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.checkVisibleAnimations()
            }
        }
    }
    
    private func formatNumber(_ number: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: number)) ?? "\(number)"
    }

    func scrollToTop() {
        guard let documentView = scrollView.documentView else { return }
        let contentHeight = scrollView.contentView.bounds.height
        let maxY = max(0, documentView.bounds.height - contentHeight)
        let targetY: CGFloat = documentView.isFlipped ? 0 : maxY
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
    
    // MARK: - Appearance Updates
    
    private func updateAppearance() {
        // 更新主视图背景色
        view.layer?.backgroundColor = resolvedCGColor(NSColor.windowBackgroundColor, for: view)
        view.window?.backgroundColor = resolvedColor(NSColor.windowBackgroundColor, for: view)
        
        // 更新所有卡片
        keyPressCard.updateAppearance()
        clickCard.updateAppearance()
        mouseDistCard.updateAppearance()
        scrollDistCard.updateAppearance()
        
        // 更新洞察分析项
        for row in insightsGrid.arrangedSubviews {
            if let insightItem = row as? InsightItemView {
                insightItem.updateAppearance()
            } else if let stackRow = row as? NSStackView {
                for item in stackRow.arrangedSubviews {
                    if let insightItem = item as? InsightItemView {
                        insightItem.updateAppearance()
                    }
                }
            } else if let ratioView = row as? ClickRatioView {
                ratioView.updateAppearance()
            }
        }
        
        // 更新键位列表行
        for row in keyListContainer.arrangedSubviews {
            if let keyRow = row as? TopKeyRowView {
                keyRow.updateAppearance()
            }
        }
        
        // 重新绘制饼图
        keyPieChartView.needsDisplay = true
        
        // 通知所有子视图更新
        view.needsDisplay = true
    }
}

// MARK: - 组件：统计大卡片

class BigStatCard: NSView {
    private var valueLabel: NSTextField!
    private var displayLink: CVDisplayLink?
    private var animationStartTime: CFTimeInterval = 0
    private var animationDuration: CFTimeInterval = 0.6
    private var targetValue: Double = 0
    private var currentDisplayValue: Double = 0
    private var isAnimating = false
    private var numberFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()
    private var useCustomFormat = false
    private var customFormatValue: String = ""

    private let normalBackgroundColor = NSColor.controlBackgroundColor

    init(icon: String, title: String, color: NSColor) {
        super.init(frame: .zero)
        self.wantsLayer = true
        self.layer?.backgroundColor = normalBackgroundColor.cgColor
        self.layer?.cornerRadius = 12
        self.layer?.borderWidth = 1
        self.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.2).cgColor

        // Initial state for entry animation
        self.alphaValue = 0
        self.layer?.transform = CATransform3DMakeScale(0.95, 0.95, 1)

        setupUI(icon: icon, title: title, color: color)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        stopAnimation()
    }

    // MARK: - Entry Animation
    func animateIn(delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.animator().alphaValue = 1.0
            }

            CATransaction.begin()
            CATransaction.setAnimationDuration(0.3)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
            self.layer?.transform = CATransform3DIdentity
            CATransaction.commit()
        }
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

    func animateValue(to value: Int, delay: TimeInterval = 0) {
        useCustomFormat = false
        targetValue = Double(value)
        startAnimation(delay: delay)
    }

    func animateValue(to value: String, numericValue: Double, delay: TimeInterval = 0) {
        useCustomFormat = true
        customFormatValue = value
        targetValue = numericValue
        startAnimation(delay: delay)
    }

    private func startAnimation(delay: TimeInterval) {
        stopAnimation()
        currentDisplayValue = 0
        valueLabel.stringValue = "0"

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.beginAnimation()
        }
    }

    private func beginAnimation() {
        isAnimating = true
        animationStartTime = CACurrentMediaTime()

        // 使用 Timer 代替 CVDisplayLink，更简单可靠
        Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { [weak self] timer in
            guard let self = self, self.isAnimating else {
                timer.invalidate()
                return
            }
            self.updateAnimation(timer: timer)
        }
    }

    private func updateAnimation(timer: Timer) {
        let elapsed = CACurrentMediaTime() - animationStartTime
        let progress = min(elapsed / animationDuration, 1.0)

        // easeOutQuart 缓动函数
        let easedProgress = 1.0 - pow(1.0 - progress, 4)

        currentDisplayValue = targetValue * easedProgress

        if useCustomFormat {
            // 对于自定义格式（如距离），在动画结束时显示最终格式
            if progress >= 1.0 {
                valueLabel.stringValue = customFormatValue
            } else {
                let displayInt = Int(currentDisplayValue)
                valueLabel.stringValue = numberFormatter.string(from: NSNumber(value: displayInt)) ?? "\(displayInt)"
            }
        } else {
            let displayInt = Int(currentDisplayValue)
            valueLabel.stringValue = numberFormatter.string(from: NSNumber(value: displayInt)) ?? "\(displayInt)"
        }

        if progress >= 1.0 {
            isAnimating = false
            timer.invalidate()
        }
    }

    private func stopAnimation() {
        isAnimating = false
    }
    
    func updateAppearance() {
        // 更新背景色和边框
        layer?.backgroundColor = resolvedCGColor(normalBackgroundColor, for: self)
        let borderColor = NSColor.separatorColor.withAlphaComponent(0.2)
        layer?.borderColor = resolvedCGColor(borderColor, for: self)
        layer?.shadowOpacity = 0
    }
}

// MARK: - 组件：洞察分析项

class InsightItemView: NSView {
    private let normalBackgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.5)

    init(title: String, value: String, subtitle: String, icon: String, tooltip: String? = nil) {
        super.init(frame: .zero)
        self.wantsLayer = true
        self.layer?.backgroundColor = normalBackgroundColor.cgColor
        self.layer?.cornerRadius = 12
        self.layer?.borderWidth = 1
        self.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.25).cgColor

        // Initial state for entry animation
        self.alphaValue = 0
        self.layer?.transform = CATransform3DMakeTranslation(0, -10, 0)

        if let tooltip = tooltip {
            self.toolTip = tooltip
        }

        setupUI(title: title, value: value, subtitle: subtitle, icon: icon)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Entry Animation
    func animateIn(delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.animator().alphaValue = 1.0
            }

            CATransaction.begin()
            CATransaction.setAnimationDuration(0.25)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
            self.layer?.transform = CATransform3DIdentity
            CATransaction.commit()
        }
    }

    
    func updateAppearance() {
        // 更新背景色和边框
        layer?.backgroundColor = resolvedCGColor(normalBackgroundColor, for: self)
        layer?.shadowOpacity = 0
        let borderColor = NSColor.separatorColor.withAlphaComponent(0.25)
        layer?.borderColor = resolvedCGColor(borderColor, for: self)
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
    private var leftBar: NSView!
    private var leftBarWidthConstraint: NSLayoutConstraint?
    private var targetLeftRatio: CGFloat = 0

    init(leftClicks: Int, rightClicks: Int) {
        super.init(frame: .zero)
        setupUI(leftClicks: leftClicks, rightClicks: rightClicks)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Entry Animation
    func animateIn(delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, let leftBar = self.leftBar else { return }

            // Animate progress bar width
            self.leftBarWidthConstraint?.isActive = false
            self.leftBarWidthConstraint = leftBar.widthAnchor.constraint(equalTo: leftBar.superview!.widthAnchor, multiplier: max(0.01, self.targetLeftRatio))
            self.leftBarWidthConstraint?.isActive = true

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.4
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                context.allowsImplicitAnimation = true
                self.layoutSubtreeIfNeeded()
            }
        }
    }

    private func setupUI(leftClicks: Int, rightClicks: Int) {
        self.wantsLayer = true
        self.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.5).cgColor
        self.layer?.cornerRadius = 12
        self.layer?.borderWidth = 1
        self.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.15).cgColor

        // Initial state for entry animation
        self.alphaValue = 0
        self.layer?.transform = CATransform3DMakeTranslation(0, -10, 0)

        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 80).isActive = true

        let total = max(1, leftClicks + rightClicks)
        let leftRatio = Double(leftClicks) / Double(total)
        let rightRatio = Double(rightClicks) / Double(total)
        targetLeftRatio = CGFloat(leftRatio)

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
        leftBar = NSView()
        leftBar.wantsLayer = true
        leftBar.layer?.backgroundColor = NSColor.systemBlue.cgColor
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

        // Start with 0 width for animation
        leftBarWidthConstraint = leftBar.widthAnchor.constraint(equalToConstant: 0)

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
            leftBarWidthConstraint!,

            leftLabel.topAnchor.constraint(equalTo: barContainer.bottomAnchor, constant: 6),
            leftLabel.leadingAnchor.constraint(equalTo: barContainer.leadingAnchor),

            rightLabel.topAnchor.constraint(equalTo: barContainer.bottomAnchor, constant: 6),
            rightLabel.trailingAnchor.constraint(equalTo: barContainer.trailingAnchor)
        ])
    }

    func animateEntryIn(delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.animator().alphaValue = 1.0
            }

            CATransaction.begin()
            CATransaction.setAnimationDuration(0.25)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
            self.layer?.transform = CATransform3DIdentity
            CATransaction.commit()

            // Animate progress bar after entry animation
            self.animateIn(delay: 0.15)
        }
    }
    
    func updateAppearance() {
        // 更新背景色和边框
        let backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.5)
        layer?.backgroundColor = resolvedCGColor(backgroundColor, for: self)
        let borderColor = NSColor.separatorColor.withAlphaComponent(0.15)
        layer?.borderColor = resolvedCGColor(borderColor, for: self)
    }
}

// MARK: - 组件：Top Key 行

class TopKeyRowView: NSView {
    private var barFill: NSView!
    private var barFillWidthConstraint: NSLayoutConstraint?
    private var targetRatio: CGFloat = 0

    init(rank: Int, key: String, count: Int, maxCount: Double, color: NSColor) {
        super.init(frame: .zero)
        setupUI(rank: rank, key: key, count: count, maxCount: maxCount, color: color)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Entry Animation
    func animateIn(delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }

            // Fade in and slide animation
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.35
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.animator().alphaValue = 1.0
            }

            CATransaction.begin()
            CATransaction.setAnimationDuration(0.35)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
            self.layer?.transform = CATransform3DIdentity
            CATransaction.commit()

            // Animate progress bar width after a small delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.animateProgressBar()
            }
        }
    }

    private func animateProgressBar() {
        guard let barFill = barFill, let superview = barFill.superview else { return }

        barFillWidthConstraint?.isActive = false
        barFillWidthConstraint = barFill.widthAnchor.constraint(equalTo: superview.widthAnchor, multiplier: max(0.01, targetRatio))
        barFillWidthConstraint?.isActive = true

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            self.layoutSubtreeIfNeeded()
        }
    }

    private func setupUI(rank: Int, key: String, count: Int, maxCount: Double, color: NSColor) {
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 32).isActive = true

        self.wantsLayer = true
        self.layer?.cornerRadius = 6

        self.layer?.backgroundColor = NSColor.clear.cgColor

        // Initial state for entry animation
        self.alphaValue = 0
        self.layer?.transform = CATransform3DMakeTranslation(-20, 0, 0)

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
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
        keyLabel.alignment = .left
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
        barContainer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        barContainer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // 进度条前景
        barFill = NSView()
        barFill.wantsLayer = true
        barFill.layer?.backgroundColor = color.withAlphaComponent(0.8).cgColor
        barFill.layer?.cornerRadius = 4
        barFill.translatesAutoresizingMaskIntoConstraints = false
        barContainer.addSubview(barFill)

        targetRatio = maxCount > 0 ? CGFloat(count) / CGFloat(maxCount) : 0

        // Start with 0 width for animation
        barFillWidthConstraint = barFill.widthAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            barFill.leadingAnchor.constraint(equalTo: barContainer.leadingAnchor),
            barFill.topAnchor.constraint(equalTo: barContainer.topAnchor),
            barFill.bottomAnchor.constraint(equalTo: barContainer.bottomAnchor),
            barFillWidthConstraint!
        ])

        // 计数值
        let countLabel = NSTextField(labelWithString: "\(count)")
        countLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        countLabel.textColor = .secondaryLabelColor
        countLabel.alignment = .right
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        stack.addArrangedSubview(rankLabel)
        stack.addArrangedSubview(keyLabel)
        stack.addArrangedSubview(barContainer)
        stack.addArrangedSubview(countLabel)

        barContainer.heightAnchor.constraint(equalToConstant: 8).isActive = true
        barContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        countLabel.widthAnchor.constraint(equalToConstant: 60).isActive = true
    }
    
    func updateAppearance() {
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.borderWidth = 0
        layer?.borderColor = nil
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

    private var hoveredIndex: Int? = nil {
        didSet {
            if oldValue != hoveredIndex {
                needsDisplay = true
            }
        }
    }

    private var trackingArea: NSTrackingArea?
    private var hasAnimatedIn = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    // MARK: - Entry Animation
    func animateIn(delay: TimeInterval = 0) {
        guard !hasAnimatedIn else { return }
        hasAnimatedIn = true

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            self.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.5
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.animator().alphaValue = 1.0
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea!)
    }

    override func mouseMoved(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        hoveredIndex = indexOfSlice(at: location)
    }

    override func mouseExited(with event: NSEvent) {
        hoveredIndex = nil
    }

    private func indexOfSlice(at point: NSPoint) -> Int? {
        guard !entries.isEmpty else { return nil }

        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let inset: CGFloat = 8
        let radius = min(bounds.width, bounds.height) / 2 - inset
        let innerRadius = radius * 0.5

        let dx = point.x - center.x
        let dy = point.y - center.y
        let distance = sqrt(dx * dx + dy * dy)

        // 检查是否在环形区域内
        guard distance >= innerRadius && distance <= radius else { return nil }

        // 计算角度 (从正上方顺时针)
        var angle = atan2(dx, dy) * 180 / .pi // 角度从正上方(90度)开始
        if angle < 0 { angle += 360 }

        let total = entries.reduce(0) { $0 + $1.count }
        guard total > 0 else { return nil }

        var cumulativeAngle: CGFloat = 0
        for (index, entry) in entries.enumerated() {
            let fraction = CGFloat(entry.count) / CGFloat(total)
            let sliceAngle = 360 * fraction
            if angle >= cumulativeAngle && angle < cumulativeAngle + sliceAngle {
                return index
            }
            cumulativeAngle += sliceAngle
        }

        return nil
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

            let isHovered = hoveredIndex == index
            let color = colors[index % colors.count].withAlphaComponent(isHovered ? 1.0 : 0.85)
            color.setFill()
            path.fill()

            // 绘制分隔线
            if entries.count > 1 {
                let isDarkMode = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                let separatorColor = isDarkMode 
                    ? NSColor.windowBackgroundColor.withAlphaComponent(0.6)
                    : NSColor.windowBackgroundColor
                separatorColor.setStroke()
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
        let holeColor = resolvedColor(NSColor.windowBackgroundColor, for: self)
        holeColor.setFill()
        holePath.fill()

        // 在中心显示悬停的按键信息
        if let index = hoveredIndex, index < entries.count {
            let entry = entries[index]
            let percentage = Double(entry.count) / Double(total) * 100

            // 按键名称
            let keyText = entry.key
            let keyAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 16, weight: .semibold),
                .foregroundColor: NSColor.labelColor
            ]
            let keySize = keyText.size(withAttributes: keyAttributes)
            let keyPoint = NSPoint(
                x: center.x - keySize.width / 2,
                y: center.y + 2
            )
            keyText.draw(at: keyPoint, withAttributes: keyAttributes)

            // 百分比
            let percentText = String(format: "%.1f%%", percentage)
            let percentAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            let percentSize = percentText.size(withAttributes: percentAttributes)
            let percentPoint = NSPoint(
                x: center.x - percentSize.width / 2,
                y: center.y - percentSize.height - 2
            )
            percentText.draw(at: percentPoint, withAttributes: percentAttributes)
        }
    }
}
