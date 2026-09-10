import Cocoa

final class HourlyStatsViewController: NSViewController {
    private let datePickerButton = NSButton()
    private let backToTodayButton = NSButton()
    private var selectedDate = Date()
    private lazy var datePickerController: HeatmapDatePickerPopoverViewController = {
        let controller = HeatmapDatePickerPopoverViewController()
        controller.onDateSelected = { [weak self] date in
            guard let self else { return }
            self.selectedDate = date
            self.datePickerPopover.performClose(nil)
            self.dateChanged()
        }
        return controller
    }()
    private lazy var datePickerPopover: NSPopover = {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = datePickerController
        return popover
    }()
    private let previousButton = NSButton()
    private let nextButton = NSButton()
    private let mode = NSSegmentedControl()
    private let metric = NSSegmentedControl()
    private let summary = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let note = NSTextField(wrappingLabelWithString: "")
    private let chart = HourlyStatsChartView()
    private var refreshTimer: Timer?
    private var lastDay: Date?

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 490))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let title = NSTextField(labelWithString: NSLocalizedString("hourly.title", comment: ""))
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        metric.segmentCount = 2
        metric.setLabel(NSLocalizedString("history.metric.keys", comment: ""), forSegment: 0)
        metric.setLabel(NSLocalizedString("history.metric.clicks", comment: ""), forSegment: 1)
        metric.selectedSegment = 0
        metric.target = self
        metric.action = #selector(metricChanged)
        mode.segmentCount = 2
        mode.setLabel(NSLocalizedString("hourly.byDate", comment: ""), forSegment: 0)
        mode.setLabel(NSLocalizedString("hourly.recent", comment: ""), forSegment: 1)
        mode.selectedSegment = 0
        mode.target = self
        mode.action = #selector(modeChanged)
        datePickerButton.bezelStyle = .rounded
        datePickerButton.controlSize = .regular
        datePickerButton.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        datePickerButton.contentTintColor = .labelColor
        datePickerButton.target = self
        datePickerButton.action = #selector(toggleDatePicker)
        datePickerButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        datePickerButton.setContentHuggingPriority(.required, for: .horizontal)
        datePickerButton.setAccessibilityLabel(NSLocalizedString("hourly.byDate", comment: ""))
        backToTodayButton.title = NSLocalizedString("keyboardHeatmap.backToToday", comment: "")
        backToTodayButton.bezelStyle = .rounded
        backToTodayButton.controlSize = .regular
        backToTodayButton.target = self
        backToTodayButton.action = #selector(backToToday)
        backToTodayButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        backToTodayButton.setContentHuggingPriority(.required, for: .horizontal)
        configure(previousButton, symbol: "chevron.left", label: "hourly.previous", action: #selector(previousDay))
        configure(nextButton, symbol: "chevron.right", label: "hourly.next", action: #selector(nextDay))
        let dateControls = NSStackView(views: [previousButton, datePickerButton, nextButton, backToTodayButton])
        dateControls.alignment = .centerY
        dateControls.spacing = 8
        dateControls.setCustomSpacing(10, after: nextButton)
        let controls = NSStackView(views: [mode, dateControls])
        controls.alignment = .centerY
        controls.spacing = 20
        summary.font = .systemFont(ofSize: 15, weight: .medium)
        detail.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        detail.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        for child in [title, metric, controls, summary, chart, detail, note] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        NSLayoutConstraint.activate([
            metric.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            metric.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            metric.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 16),
            datePickerButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 78),
            title.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            title.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            controls.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            controls.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 20),
            controls.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
            summary.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            summary.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 20),
            summary.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            chart.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            chart.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            chart.topAnchor.constraint(equalTo: summary.bottomAnchor, constant: 12),
            chart.bottomAnchor.constraint(equalTo: detail.topAnchor, constant: -10),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: chart.trailingAnchor),
            detail.bottomAnchor.constraint(equalTo: note.topAnchor, constant: -12),
            note.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            note.trailingAnchor.constraint(equalTo: chart.trailingAnchor),
            note.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20)
        ])
        chart.onHover = { [weak self] point in self?.showDetail(point) }
        refresh()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    deinit { refreshTimer?.invalidate() }

    func refresh() {
        guard isViewLoaded else { return }
        let stats = StatsManager.shared.hourlyStatsSnapshot()
        let now = Date()
        let today = stats.calendar.startOfDay(for: now)
        // Follow today across midnight only when the user was already viewing today.
        if let lastDay, lastDay != today, stats.calendar.isDate(selectedDate, inSameDayAs: lastDay) {
            selectedDate = today
        }
        lastDay = today
        updateDateButton(calendar: stats.calendar, now: now)
        let recent = mode.selectedSegment == 1
        datePickerButton.isEnabled = !recent
        backToTodayButton.isHidden = recent || stats.calendar.isDate(selectedDate, inSameDayAs: now)
        previousButton.isEnabled = !recent
        nextButton.isEnabled = !recent && stats.calendar.startOfDay(for: selectedDate) < today
        let series = StatsManager.shared.hourlyTrendSeries(date: selectedDate, recent24Hours: recent)
        let points = series.total
        chart.showsClicks = metric.selectedSegment == 1
        chart.localPoints = series.local
        chart.timeZone = stats.calendar.timeZone
        chart.points = points
        let recorded = points.compactMap(\.counts)
        if recorded.isEmpty {
            summary.stringValue = NSLocalizedString("hourly.empty", comment: "")
        } else {
            let total = saturatingNonnegativeSum(recorded.map(chart.value))
            let local = saturatingNonnegativeSum(series.local.compactMap(\.counts).map(chart.value))
            let peak = points.filter { $0.counts != nil }.max {
                $0.counts.map(chart.value) ?? 0 < $1.counts.map(chart.value) ?? 0
            }
            let peakText = total > 0 ? peak.map { chart.hourLabel($0.date) } ?? "—" : "—"
            summary.stringValue = String(format: NSLocalizedString("hourly.summary.metric", comment: ""),
                                         total, local, peakText)
        }
        let formatter = DateFormatter()
        formatter.timeZone = stats.calendar.timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        note.stringValue = String(format: NSLocalizedString("hourly.note", comment: ""),
                                  formatter.string(from: stats.startedAt), stats.timeZoneIdentifier)
        showDetail(chart.hoveredPoint)
    }

    private func configure(_ button: NSButton, symbol: String, label: String, action: Selector) {
        button.title = ""
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        button.contentTintColor = .labelColor
        button.controlSize = .regular
        button.setButtonType(.momentaryPushIn)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.imagePosition = .imageOnly
        button.bezelStyle = .rounded
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 32)
        ])
        button.target = self
        button.action = action
        button.toolTip = NSLocalizedString(label, comment: "")
        button.setAccessibilityLabel(NSLocalizedString(label, comment: ""))
    }

    private func showDetail(_ point: HourlyStats.Point?) {
        guard let point else {
            detail.stringValue = NSLocalizedString("hourly.hover", comment: "")
            return
        }
        let formatter = DateFormatter()
        formatter.timeZone = chart.timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMMd HH:mm z")
        let time = formatter.string(from: point.date)
        let total = point.counts.map { String(chart.value($0)) } ?? "—"
        let local = chart.localPoints.first(where: { $0.date == point.date })?.counts.map { String(chart.value($0)) } ?? "—"
        detail.stringValue = String(format: NSLocalizedString("hourly.detail.metric", comment: ""), time, total, local)
    }

    private func updateDateButton(calendar: Calendar, now: Date) {
        let sameYear = calendar.component(.year, from: selectedDate) == calendar.component(.year, from: now)
        let localization = Bundle.main.preferredLocalizations.first ?? ""
        let language = Locale.preferredLanguages.first ?? ""
        let title: String
        if localization.hasPrefix("zh") || language.hasPrefix("zh") {
            let monthDay = "\(calendar.component(.month, from: selectedDate))月\(calendar.component(.day, from: selectedDate))日"
            title = sameYear ? monthDay : "\(calendar.component(.year, from: selectedDate))年" + monthDay
        } else {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.setLocalizedDateFormatFromTemplate(sameYear ? "Md" : "yMd")
            title = formatter.string(from: selectedDate)
        }
        let attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ])
        datePickerButton.attributedTitle = attributedTitle
        datePickerButton.attributedAlternateTitle = attributedTitle
        datePickerButton.setAccessibilityValue(title)
    }

    @objc private func toggleDatePicker() {
        if datePickerPopover.isShown {
            datePickerPopover.performClose(nil)
            return
        }
        let calendar = StatsManager.shared.hourlyStatsSnapshot().calendar
        datePickerController.update(selectedDate: selectedDate,
                                    bounds: (.distantPast, Date()), calendar: calendar)
        datePickerController.prepareForPresentation()
        datePickerPopover.contentSize = datePickerController.preferredContentSize
        datePickerPopover.show(relativeTo: datePickerButton.bounds, of: datePickerButton, preferredEdge: .maxY)
        AppDelegate.trackClick("hourly_open_calendar")
    }

    @objc private func backToToday() {
        selectedDate = StatsManager.shared.hourlyStatsSnapshot().calendar.startOfDay(for: Date())
        AppDelegate.trackClick("hourly_back_to_today")
        chart.clearHover()
        refresh()
    }

    @objc private func metricChanged() {
        AppDelegate.trackClick("hourly_metric", properties: ["metric": metric.selectedSegment == 0 ? "keys" : "clicks"])
        refresh()
    }

    @objc private func modeChanged() {
        datePickerPopover.performClose(nil)
        AppDelegate.trackClick("hourly_mode", properties: ["mode": mode.selectedSegment == 0 ? "date" : "recent_24_hours"])
        chart.clearHover()
        refresh()
    }

    @objc private func dateChanged() {
        AppDelegate.trackClick("hourly_date")
        chart.clearHover()
        refresh()
    }

    private func moveDay(_ offset: Int) {
        let calendar = StatsManager.shared.hourlyStatsSnapshot().calendar
        guard let date = calendar.date(byAdding: .day, value: offset, to: selectedDate) else { return }
        selectedDate = min(date, Date())
        AppDelegate.trackClick("hourly_day", properties: ["direction": offset < 0 ? "previous" : "next"])
        chart.clearHover()
        refresh()
    }

    @objc private func previousDay() { moveDay(-1) }
    @objc private func nextDay() { moveDay(1) }
}
