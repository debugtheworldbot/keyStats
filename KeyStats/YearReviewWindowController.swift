import Cocoa

private func yearReviewLocalized(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

/// 界面日期/星期/月份使用 App 当前语言，而不是系统区域，避免中英混排。
private func yearReviewDisplayLocale() -> Locale {
    Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
}

private func yearReviewFormattedCount(_ value: Int) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.locale = yearReviewDisplayLocale()
    return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
}

private func yearReviewPercent(_ ratio: Double) -> String {
    String(format: "%.1f%%", ratio * 100)
}

private func yearReviewIsDark(_ view: NSView) -> Bool {
    view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
}

// MARK: - Window

final class YearReviewWindowController: NSWindowController {
    static let shared = YearReviewWindowController()

    private init() {
        let viewController = YearReviewViewController()
        let window = NSWindow(contentViewController: viewController)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = yearReviewLocalized("yearReview.windowTitle")
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = true
        window.backgroundColor = .windowBackgroundColor
        window.setContentSize(NSSize(width: 900, height: 600))
        window.minSize = NSSize(width: 820, height: 560)
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        guard let window = window else { return }
        NSApp.activate(ignoringOtherApps: true)
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()

        if let vc = contentViewController as? YearReviewViewController {
            vc.refreshData()
        }
        AppDelegate.trackPageView("year_review")
    }
}

// MARK: - Root view controller

final class YearReviewViewController: NSViewController {
    private var titleLabel: NSTextField!
    private var tabControl: NSSegmentedControl!
    private var wallTabView: ContributionWallTabView!
    private var personaTabView: KeyboardPersonaTabView!

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        refreshData()
    }

    func refreshData() {
        let history = StatsManager.shared.yearReviewHistorySnapshot()
        wallTabView.apply(history: history)
        personaTabView.apply(history: history)
    }

    private func setupUI() {
        titleLabel = NSTextField(labelWithString: yearReviewLocalized("yearReview.windowTitle"))
        titleLabel.font = NSFont.systemFont(ofSize: 22, weight: .bold)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        tabControl = NSSegmentedControl(labels: [yearReviewLocalized("yearReview.tab.wall"),
                                                 yearReviewLocalized("yearReview.tab.persona")],
                                        trackingMode: .selectOne,
                                        target: self,
                                        action: #selector(tabChanged))
        tabControl.selectedSegment = 0
        tabControl.translatesAutoresizingMaskIntoConstraints = false

        wallTabView = ContributionWallTabView()
        wallTabView.translatesAutoresizingMaskIntoConstraints = false
        personaTabView = KeyboardPersonaTabView()
        personaTabView.translatesAutoresizingMaskIntoConstraints = false
        personaTabView.isHidden = true

        view.addSubview(titleLabel)
        view.addSubview(tabControl)
        view.addSubview(wallTabView)
        view.addSubview(personaTabView)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 36),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),

            tabControl.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            tabControl.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
            tabControl.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 16),
        ])

        for tabView in [wallTabView as NSView, personaTabView as NSView] {
            NSLayoutConstraint.activate([
                tabView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 16),
                tabView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
                tabView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
                tabView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -24),
            ])
        }
    }

    @objc private func tabChanged() {
        let showsWall = tabControl.selectedSegment == 0
        wallTabView.isHidden = !showsWall
        personaTabView.isHidden = showsWall
        AppDelegate.trackClick("year_review_tab", properties: ["tab": showsWall ? "wall" : "persona"])
    }
}

// MARK: - Shared card views

/// 圆角玻璃卡片。layer 颜色在 updateLayer 中按当前 appearance 重新解析，深浅色切换后自动更新。
class YearReviewCardView: NSView {
    var fillAlpha: CGFloat = 0.75

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var wantsUpdateLayer: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func updateLayer() {
        guard let layer = layer else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(fillAlpha).cgColor
            layer.borderColor = NSColor.separatorColor.withAlphaComponent(0.16).cgColor
            layer.shadowColor = NSColor.black.withAlphaComponent(0.07).cgColor
        }
        layer.cornerRadius = 12
        layer.borderWidth = 0.5
        layer.masksToBounds = false
        layer.shadowOpacity = 1
        layer.shadowRadius = 8
        layer.shadowOffset = NSSize(width: 0, height: -1)
    }
}

/// 标题 + 大号数值 + 说明 的统计卡片。
final class YearReviewStatCard: YearReviewCardView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    init(title: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        titleLabel.stringValue = title
        titleLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor

        valueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 20, weight: .semibold)
        valueLabel.textColor = .labelColor
        valueLabel.lineBreakMode = .byTruncatingTail

        detailLabel.font = NSFont.systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [titleLabel, valueLabel, detailLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -12),
        ])
        valueLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(value: String, detail: String?) {
        valueLabel.stringValue = value
        detailLabel.stringValue = detail ?? ""
        detailLabel.isHidden = (detail ?? "").isEmpty
    }
}

/// 胶囊标签，用于人格副称号。
final class YearReviewTagView: NSView {
    private let label = NSTextField(labelWithString: "")

    init(text: String) {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        label.stringValue = text
        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        label.textColor = .controlAccentColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var wantsUpdateLayer: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }

    override func updateLayer() {
        guard let layer = layer else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.14).cgColor
        }
        layer.cornerRadius = bounds.height / 2
    }
}

// MARK: - Contribution wall tab

final class ContributionWallTabView: NSView {
    private enum Metric: Int {
        case keyPresses = 0
        case clicks = 1

        var analyticsValue: String { self == .keyPresses ? "key_presses" : "clicks" }
    }

    private let rangeControl = NSSegmentedControl(frame: .zero)
    private var metricControl: NSSegmentedControl!
    private let totalCard = YearReviewStatCard(title: yearReviewLocalized("yearReview.summary.total"))
    private let activeDaysCard = YearReviewStatCard(title: yearReviewLocalized("yearReview.summary.activeDays"))
    private let currentStreakCard = YearReviewStatCard(title: yearReviewLocalized("yearReview.summary.currentStreak"))
    private let longestStreakCard = YearReviewStatCard(title: yearReviewLocalized("yearReview.summary.longestStreak"))
    private let bestDayCard = YearReviewStatCard(title: yearReviewLocalized("yearReview.summary.bestDay"))
    private let wallCard = YearReviewCardView()
    private let wallView = ContributionWallView()
    private let legendView = ContributionWallLegendView()

    private var history: [String: DailyStats] = [:]
    private var ranges: [ContributionWallRange] = [.last12Months]
    private var selectedRange: ContributionWallRange = .last12Months
    private var metric: Metric = .keyPresses

    private let dayKeyFormatter: DateFormatter = {
        // 与 StatsManager 的历史 key 格式保持一致
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private lazy var tooltipDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = yearReviewDisplayLocale()
        formatter.setLocalizedDateFormatFromTemplate("yMMMdEEE")
        return formatter
    }()

    private lazy var shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = yearReviewDisplayLocale()
        formatter.setLocalizedDateFormatFromTemplate("yMMMd")
        return formatter
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(history: [String: DailyStats]) {
        self.history = history
        rebuildRangeMenu()
        reload()
    }

    private func setupUI() {
        rangeControl.trackingMode = .selectOne
        rangeControl.target = self
        rangeControl.action = #selector(rangeChanged)
        rangeControl.translatesAutoresizingMaskIntoConstraints = false

        metricControl = NSSegmentedControl(labels: [yearReviewLocalized("yearReview.metric.keyPresses"),
                                                    yearReviewLocalized("yearReview.metric.clicks")],
                                           trackingMode: .selectOne,
                                           target: self,
                                           action: #selector(metricChanged))
        metricControl.selectedSegment = 0
        metricControl.translatesAutoresizingMaskIntoConstraints = false

        let controlsRow = NSStackView(views: [rangeControl, NSView(), metricControl])
        controlsRow.orientation = .horizontal
        controlsRow.alignment = .centerY
        controlsRow.spacing = 12
        controlsRow.translatesAutoresizingMaskIntoConstraints = false

        let summaryRow = NSStackView(views: [totalCard, activeDaysCard, currentStreakCard, longestStreakCard, bestDayCard])
        summaryRow.orientation = .horizontal
        summaryRow.distribution = .fillEqually
        summaryRow.spacing = 10
        summaryRow.translatesAutoresizingMaskIntoConstraints = false

        wallCard.translatesAutoresizingMaskIntoConstraints = false
        wallView.translatesAutoresizingMaskIntoConstraints = false
        legendView.translatesAutoresizingMaskIntoConstraints = false

        let lessLabel = NSTextField(labelWithString: yearReviewLocalized("settings.heatmapPreview.less"))
        let moreLabel = NSTextField(labelWithString: yearReviewLocalized("settings.heatmapPreview.more"))
        for label in [lessLabel, moreLabel] {
            label.font = NSFont.systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
        }
        let legendRow = NSStackView(views: [lessLabel, legendView, moreLabel])
        legendRow.orientation = .horizontal
        legendRow.alignment = .centerY
        legendRow.spacing = 6
        legendRow.translatesAutoresizingMaskIntoConstraints = false

        wallCard.addSubview(wallView)
        wallCard.addSubview(legendRow)

        addSubview(controlsRow)
        addSubview(summaryRow)
        addSubview(wallCard)

        NSLayoutConstraint.activate([
            controlsRow.topAnchor.constraint(equalTo: topAnchor),
            controlsRow.leadingAnchor.constraint(equalTo: leadingAnchor),
            controlsRow.trailingAnchor.constraint(equalTo: trailingAnchor),

            summaryRow.topAnchor.constraint(equalTo: controlsRow.bottomAnchor, constant: 14),
            summaryRow.leadingAnchor.constraint(equalTo: leadingAnchor),
            summaryRow.trailingAnchor.constraint(equalTo: trailingAnchor),
            summaryRow.heightAnchor.constraint(equalToConstant: 82),

            wallCard.topAnchor.constraint(equalTo: summaryRow.bottomAnchor, constant: 14),
            wallCard.leadingAnchor.constraint(equalTo: leadingAnchor),
            wallCard.trailingAnchor.constraint(equalTo: trailingAnchor),
            wallCard.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),

            wallView.topAnchor.constraint(equalTo: wallCard.topAnchor, constant: 16),
            wallView.leadingAnchor.constraint(equalTo: wallCard.leadingAnchor, constant: 16),
            wallView.trailingAnchor.constraint(equalTo: wallCard.trailingAnchor, constant: -16),
            wallView.heightAnchor.constraint(equalToConstant: 140),

            legendRow.topAnchor.constraint(equalTo: wallView.bottomAnchor, constant: 10),
            legendRow.trailingAnchor.constraint(equalTo: wallCard.trailingAnchor, constant: -16),
            legendRow.bottomAnchor.constraint(equalTo: wallCard.bottomAnchor, constant: -14),
            legendView.widthAnchor.constraint(equalToConstant: ContributionWallLegendView.preferredWidth),
            legendView.heightAnchor.constraint(equalToConstant: ContributionWallLegendView.cellSize),
        ])

        wallView.tooltipProvider = { [weak self] day in
            self?.tooltipText(for: day) ?? ""
        }
    }

    private func rebuildRangeMenu() {
        let earliest = history.values
            .filter { $0.keyPresses > 0 || $0.totalClicks > 0 }
            .map { $0.date }
            .min()
        ranges = ContributionWallBuilder.availableRanges(earliestDate: earliest, today: Date())
        if !ranges.contains(selectedRange) {
            selectedRange = .last12Months
        }

        // 范围用分段控件平铺展示，和指标、人格范围的切换样式保持一致
        rangeControl.segmentCount = ranges.count
        for (index, range) in ranges.enumerated() {
            let label: String
            switch range {
            case .last12Months:
                label = yearReviewLocalized("yearReview.range.last12Months")
            case .year(let year):
                label = String(format: yearReviewLocalized("yearReview.range.yearFormat"), year)
            }
            rangeControl.setLabel(label, forSegment: index)
            rangeControl.setWidth(0, forSegment: index)
        }
        if let index = ranges.firstIndex(of: selectedRange) {
            rangeControl.selectedSegment = index
        }
    }

    private func reload() {
        let model = ContributionWallBuilder.build(range: selectedRange, today: Date()) { [weak self] date in
            self?.value(on: date) ?? 0
        }
        wallView.model = model

        totalCard.update(value: yearReviewFormattedCount(model.total), detail: unitText())
        activeDaysCard.update(value: daysText(model.activeDays), detail: nil)
        if let currentStreak = model.currentStreak {
            currentStreakCard.update(value: daysText(currentStreak), detail: nil)
        } else {
            currentStreakCard.update(value: "—", detail: nil)
        }
        longestStreakCard.update(value: daysText(model.longestStreak), detail: nil)
        if let best = model.bestDay {
            bestDayCard.update(value: yearReviewFormattedCount(best.value), detail: shortDateFormatter.string(from: best.date))
        } else {
            bestDayCard.update(value: "—", detail: nil)
        }
    }

    private func value(on date: Date) -> Int {
        guard let stats = history[dayKeyFormatter.string(from: date)] else { return 0 }
        switch metric {
        case .keyPresses:
            return stats.keyPresses
        case .clicks:
            return stats.totalClicks
        }
    }

    private func daysText(_ days: Int) -> String {
        String(format: yearReviewLocalized("yearReview.daysFormat"), days)
    }

    private func unitText() -> String {
        metric == .keyPresses
            ? yearReviewLocalized("yearReview.unit.keyPresses")
            : yearReviewLocalized("yearReview.unit.clicks")
    }

    private func tooltipText(for day: ContributionWallDay) -> String {
        let format = metric == .keyPresses
            ? yearReviewLocalized("yearReview.tooltip.keyPressesFormat")
            : yearReviewLocalized("yearReview.tooltip.clicksFormat")
        return String(format: format, tooltipDateFormatter.string(from: day.date), yearReviewFormattedCount(day.value))
    }

    @objc private func rangeChanged() {
        let index = rangeControl.selectedSegment
        guard index >= 0, index < ranges.count else { return }
        selectedRange = ranges[index]
        reload()
        AppDelegate.trackClick("year_review_range", properties: ["range": selectedRange.analyticsValue])
    }

    @objc private func metricChanged() {
        metric = Metric(rawValue: metricControl.selectedSegment) ?? .keyPresses
        reload()
        AppDelegate.trackClick("year_review_metric", properties: ["metric": metric.analyticsValue])
    }
}

/// 贡献墙网格：列为周、行为周一到周日，颜色跟随热力图配色。
final class ContributionWallView: NSView, NSViewToolTipOwner {
    private let weekdayLabelWidth: CGFloat = 34
    private let monthLabelHeight: CGFloat = 18
    private let cellGap: CGFloat = 3
    private let maxCellSize: CGFloat = 16
    private var schemeObserver: NSObjectProtocol?

    var model: ContributionWallModel? {
        didSet {
            needsLayout = true
            needsDisplay = true
        }
    }

    var tooltipProvider: ((ContributionWallDay) -> String)?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        schemeObserver = NotificationCenter.default.addObserver(
            forName: .heatmapColorSchemeDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.needsDisplay = true
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let observer = schemeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        rebuildToolTips()
    }

    private var cellSize: CGFloat {
        let columns = CGFloat(max(1, model?.columnCount ?? 53))
        let widthFit = (bounds.width - weekdayLabelWidth - cellGap * (columns - 1)) / columns
        let heightFit = (bounds.height - monthLabelHeight - cellGap * 6) / 7
        return max(4, min(maxCellSize, widthFit, heightFit))
    }

    private func cellRect(column: Int, row: Int) -> NSRect {
        let size = cellSize
        return NSRect(x: weekdayLabelWidth + CGFloat(column) * (size + cellGap),
                      y: monthLabelHeight + CGFloat(row) * (size + cellGap),
                      width: size,
                      height: size)
    }

    private func rebuildToolTips() {
        removeAllToolTips()
        guard let model = model else { return }
        for day in model.days {
            _ = addToolTip(cellRect(column: day.column, row: day.row), owner: self, userData: nil)
        }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard let model = model,
              let day = model.days.first(where: { cellRect(column: $0.column, row: $0.row).insetBy(dx: -cellGap / 2, dy: -cellGap / 2).contains(point) })
        else { return "" }
        return tooltipProvider?(day) ?? ""
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let model = model else { return }

        let isDarkMode = yearReviewIsDark(self)
        let locale = yearReviewDisplayLocale()
        let formatter = DateFormatter()
        formatter.locale = locale
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let size = cellSize

        // 月份标签：相邻太近时跳过，避免重叠
        let monthSymbols = formatter.shortStandaloneMonthSymbols ?? formatter.shortMonthSymbols ?? []
        var lastLabelMaxX = -CGFloat.greatestFiniteMagnitude
        for label in model.monthLabels where label.month >= 1 && label.month <= monthSymbols.count {
            let text = monthSymbols[label.month - 1] as NSString
            let textSize = text.size(withAttributes: labelAttributes)
            let x = cellRect(column: label.column, row: 0).minX
            guard x >= lastLabelMaxX + 4, x + textSize.width <= bounds.maxX else { continue }
            text.draw(at: NSPoint(x: x, y: (monthLabelHeight - textSize.height) / 2 - 2), withAttributes: labelAttributes)
            lastLabelMaxX = x + textSize.width
        }

        // 星期标签：只标周一 / 周三 / 周五（shortWeekdaySymbols 从周日开始）
        let weekdaySymbols = formatter.shortStandaloneWeekdaySymbols ?? formatter.shortWeekdaySymbols ?? []
        if weekdaySymbols.count == 7 {
            for (row, symbolIndex) in [(0, 1), (2, 3), (4, 5)] {
                let text = weekdaySymbols[symbolIndex] as NSString
                let textSize = text.size(withAttributes: labelAttributes)
                let rect = cellRect(column: 0, row: row)
                text.draw(at: NSPoint(x: 0, y: rect.midY - textSize.height / 2), withAttributes: labelAttributes)
            }
        }

        let borderColor = isDarkMode ? NSColor.white.withAlphaComponent(0.10) : NSColor.black.withAlphaComponent(0.06)
        let radius = min(3, size * 0.22)
        for day in model.days {
            let rect = cellRect(column: day.column, row: day.row)
            guard rect.intersects(dirtyRect) else { continue }
            let fillColor = day.value > 0
                ? HeatmapPalette.color(intensity: CGFloat(model.intensity(for: day.value)), isDarkMode: isDarkMode)
                : HeatmapPalette.neutralColor(isDarkMode: isDarkMode)
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.25, dy: 0.25), xRadius: radius, yRadius: radius)
            fillColor.setFill()
            path.fill()
            borderColor.setStroke()
            path.lineWidth = 0.5
            path.stroke()
        }
    }
}

/// 图例：底色 + 4 档热度。
final class ContributionWallLegendView: NSView {
    static let cellSize: CGFloat = 11
    static let gap: CGFloat = 3
    static let intensities: [CGFloat] = [0, 0.25, 0.5, 0.75, 1.0]
    static var preferredWidth: CGFloat {
        CGFloat(intensities.count) * cellSize + CGFloat(intensities.count - 1) * gap
    }

    private var schemeObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        schemeObserver = NotificationCenter.default.addObserver(
            forName: .heatmapColorSchemeDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.needsDisplay = true
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let observer = schemeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let isDarkMode = yearReviewIsDark(self)
        let borderColor = isDarkMode ? NSColor.white.withAlphaComponent(0.10) : NSColor.black.withAlphaComponent(0.06)
        for (index, intensity) in Self.intensities.enumerated() {
            let rect = NSRect(x: CGFloat(index) * (Self.cellSize + Self.gap),
                              y: (bounds.height - Self.cellSize) / 2,
                              width: Self.cellSize,
                              height: Self.cellSize)
            let fillColor = intensity == 0
                ? HeatmapPalette.neutralColor(isDarkMode: isDarkMode)
                : HeatmapPalette.color(intensity: intensity, isDarkMode: isDarkMode)
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.25, dy: 0.25), xRadius: 2.5, yRadius: 2.5)
            fillColor.setFill()
            path.fill()
            borderColor.setStroke()
            path.lineWidth = 0.5
            path.stroke()
        }
    }
}

// MARK: - Keyboard persona tab

final class KeyboardPersonaTabView: NSView {
    private enum PersonaRange: Int, CaseIterable {
        case today = 0
        case week
        case month
        case all

        var analyticsValue: String {
            switch self {
            case .today: return "today"
            case .week: return "week"
            case .month: return "month"
            case .all: return "all"
            }
        }

        /// nil 表示全部历史
        var dayCount: Int? {
            switch self {
            case .today: return 1
            case .week: return 7
            case .month: return 30
            case .all: return nil
            }
        }
    }

    private var rangeControl: NSSegmentedControl!
    private let heroCard = YearReviewCardView()
    private let personaTitleLabel = NSTextField(labelWithString: "")
    private let personaCommentLabel = NSTextField(labelWithString: "")
    private let totalsLabel = NSTextField(labelWithString: "")
    private let tagsRow = NSStackView()
    private let shortcutCard = YearReviewStatCard(title: yearReviewLocalized("yearReview.persona.metric.shortcut"))
    private let regretCard = YearReviewStatCard(title: yearReviewLocalized("yearReview.persona.metric.regret"))
    private let copyPasteCard = YearReviewStatCard(title: yearReviewLocalized("yearReview.persona.metric.copyPaste"))
    private let undoCard = YearReviewStatCard(title: yearReviewLocalized("yearReview.persona.metric.undo"))
    private let arrowCard = YearReviewStatCard(title: yearReviewLocalized("yearReview.persona.metric.arrow"))
    private let clickRatioCard = YearReviewStatCard(title: yearReviewLocalized("yearReview.persona.metric.clickRatio"))
    private let topKeysCard = YearReviewStatCard(title: yearReviewLocalized("yearReview.persona.metric.topKeys"))

    private var history: [String: DailyStats] = [:]
    private var range: PersonaRange = .month

    private let dayKeyFormatter: DateFormatter = {
        // 与 StatsManager 的历史 key 格式保持一致
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(history: [String: DailyStats]) {
        self.history = history
        reload()
    }

    private func setupUI() {
        rangeControl = NSSegmentedControl(labels: [yearReviewLocalized("yearReview.persona.range.today"),
                                                   yearReviewLocalized("yearReview.persona.range.week"),
                                                   yearReviewLocalized("yearReview.persona.range.month"),
                                                   yearReviewLocalized("yearReview.persona.range.all")],
                                          trackingMode: .selectOne,
                                          target: self,
                                          action: #selector(rangeChanged))
        rangeControl.selectedSegment = range.rawValue
        rangeControl.translatesAutoresizingMaskIntoConstraints = false

        personaTitleLabel.font = NSFont.systemFont(ofSize: 26, weight: .bold)
        personaTitleLabel.textColor = .labelColor
        personaTitleLabel.lineBreakMode = .byWordWrapping
        personaTitleLabel.maximumNumberOfLines = 2

        personaCommentLabel.font = NSFont.systemFont(ofSize: 14)
        personaCommentLabel.textColor = .secondaryLabelColor

        totalsLabel.font = NSFont.systemFont(ofSize: 11)
        totalsLabel.textColor = .tertiaryLabelColor

        tagsRow.orientation = .horizontal
        tagsRow.spacing = 6
        tagsRow.alignment = .centerY

        let heroStack = NSStackView(views: [personaTitleLabel, personaCommentLabel, tagsRow, totalsLabel])
        heroStack.orientation = .vertical
        heroStack.alignment = .leading
        heroStack.spacing = 8
        heroStack.setCustomSpacing(12, after: personaCommentLabel)
        heroStack.translatesAutoresizingMaskIntoConstraints = false

        heroCard.translatesAutoresizingMaskIntoConstraints = false
        heroCard.addSubview(heroStack)

        let cards = [shortcutCard, regretCard, copyPasteCard, undoCard, arrowCard, clickRatioCard, topKeysCard]
        var rows: [NSView] = []
        var index = 0
        while index < cards.count {
            let right: NSView = index + 1 < cards.count ? cards[index + 1] : NSView()
            let row = NSStackView(views: [cards[index], right])
            row.orientation = .horizontal
            row.distribution = .fillEqually
            row.spacing = 10
            row.translatesAutoresizingMaskIntoConstraints = false
            row.heightAnchor.constraint(equalToConstant: 76).isActive = true
            rows.append(row)
            index += 2
        }
        let grid = NSStackView(views: rows)
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = 10
        grid.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        let documentView = FlippedDocumentView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(heroCard)
        documentView.addSubview(grid)
        scrollView.documentView = documentView

        addSubview(rangeControl)
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            rangeControl.topAnchor.constraint(equalTo: topAnchor),
            rangeControl.leadingAnchor.constraint(equalTo: leadingAnchor),

            scrollView.topAnchor.constraint(equalTo: rangeControl.bottomAnchor, constant: 14),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            heroCard.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 2),
            heroCard.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            heroCard.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),

            heroStack.topAnchor.constraint(equalTo: heroCard.topAnchor, constant: 20),
            heroStack.leadingAnchor.constraint(equalTo: heroCard.leadingAnchor, constant: 22),
            heroStack.trailingAnchor.constraint(lessThanOrEqualTo: heroCard.trailingAnchor, constant: -22),
            heroStack.bottomAnchor.constraint(equalTo: heroCard.bottomAnchor, constant: -18),

            grid.topAnchor.constraint(equalTo: heroCard.bottomAnchor, constant: 12),
            grid.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            grid.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -4),
        ])
        for row in rows {
            row.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
        }
    }

    private func reload() {
        let input = aggregate()
        let result = KeyboardPersonaAnalyzer.analyze(keyCounts: input.keyCounts,
                                                     totalKeyPresses: input.keyPresses,
                                                     totalClicks: input.clicks)

        tagsRow.arrangedSubviews.forEach { view in
            tagsRow.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        if let primary = result.primary {
            personaTitleLabel.stringValue = title(for: primary)
            personaCommentLabel.stringValue = comment(for: primary)
            personaCommentLabel.isHidden = false
            for kind in result.secondary {
                tagsRow.addArrangedSubview(YearReviewTagView(text: title(for: kind)))
            }
        } else {
            personaTitleLabel.stringValue = yearReviewLocalized("yearReview.persona.notEnoughData")
            personaCommentLabel.stringValue = ""
            personaCommentLabel.isHidden = true
        }
        tagsRow.isHidden = tagsRow.arrangedSubviews.isEmpty
        totalsLabel.stringValue = String(format: yearReviewLocalized("yearReview.persona.totalsFormat"),
                                         yearReviewFormattedCount(result.totalKeyPresses),
                                         yearReviewFormattedCount(result.totalClicks))

        shortcutCard.update(value: yearReviewPercent(result.shortcutRatio),
                            detail: yearReviewLocalized("yearReview.persona.metric.shortcut.detail"))
        regretCard.update(value: yearReviewPercent(result.regretRatio),
                          detail: yearReviewLocalized("yearReview.persona.metric.regret.detail"))
        copyPasteCard.update(value: String(format: yearReviewLocalized("yearReview.persona.copyPasteFormat"),
                                           yearReviewFormattedCount(result.copyCount),
                                           yearReviewFormattedCount(result.pasteCount)),
                             detail: nil)
        undoCard.update(value: yearReviewFormattedCount(result.undoCount), detail: nil)
        arrowCard.update(value: yearReviewPercent(result.arrowRatio),
                         detail: yearReviewLocalized("yearReview.persona.metric.arrow.detail"))
        if result.totalKeyPresses > 0 {
            let clicksPerHundred = String(format: "%.0f", result.clicksPerKeyPress * 100)
            clickRatioCard.update(value: String(format: "%.2f", result.clicksPerKeyPress),
                                  detail: String(format: yearReviewLocalized("yearReview.persona.clickRatioFormat"), clicksPerHundred))
        } else {
            clickRatioCard.update(value: "—", detail: nil)
        }
        let topKeysText = result.topKeys.map { $0.name }.joined(separator: "  ·  ")
        topKeysCard.update(value: topKeysText.isEmpty ? "—" : topKeysText,
                           detail: result.topKeys.isEmpty ? nil : result.topKeys.map { yearReviewFormattedCount($0.count) }.joined(separator: "  ·  "))
    }

    private func aggregate() -> (keyCounts: [String: Int], keyPresses: Int, clicks: Int) {
        let selected: [DailyStats]
        if let dayCount = range.dayCount {
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: Date())
            selected = (0..<dayCount).compactMap { offset in
                guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
                return history[dayKeyFormatter.string(from: date)]
            }
        } else {
            selected = Array(history.values)
        }

        var keyCounts: [String: Int] = [:]
        var keyPresses = 0
        var clicks = 0
        for stats in selected {
            keyPresses += max(0, stats.keyPresses)
            clicks += stats.totalClicks
            for (key, count) in stats.keyPressCounts {
                keyCounts[key, default: 0] += max(0, count)
            }
        }
        return (keyCounts, keyPresses, clicks)
    }

    private func title(for kind: KeyboardPersonaKind) -> String {
        yearReviewLocalized("yearReview.persona.title.\(kind.rawValue)")
    }

    private func comment(for kind: KeyboardPersonaKind) -> String {
        yearReviewLocalized("yearReview.persona.comment.\(kind.rawValue)")
    }

    @objc private func rangeChanged() {
        range = PersonaRange(rawValue: rangeControl.selectedSegment) ?? .week
        reload()
        AppDelegate.trackClick("year_review_persona_range", properties: ["range": range.analyticsValue])
    }
}

private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}
