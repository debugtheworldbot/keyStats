import Cocoa

final class HourlyStatsViewController: NSViewController {
    private let datePicker = NSDatePicker()
    private let previousButton = NSButton()
    private let nextButton = NSButton()
    private let mode = NSSegmentedControl()
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
        mode.segmentCount = 2
        mode.setLabel(NSLocalizedString("hourly.byDate", comment: ""), forSegment: 0)
        mode.setLabel(NSLocalizedString("hourly.recent", comment: ""), forSegment: 1)
        mode.selectedSegment = 0
        mode.target = self
        mode.action = #selector(modeChanged)
        datePicker.datePickerElements = [.yearMonthDay]
        datePicker.datePickerStyle = .textFieldAndStepper
        datePicker.dateValue = Date()
        datePicker.target = self
        datePicker.action = #selector(dateChanged)
        datePicker.setAccessibilityLabel(NSLocalizedString("hourly.byDate", comment: ""))
        configure(previousButton, title: "‹", label: "hourly.previous", action: #selector(previousDay))
        configure(nextButton, title: "›", label: "hourly.next", action: #selector(nextDay))
        let controls = NSStackView(views: [mode, previousButton, datePicker, nextButton])
        controls.spacing = 10
        summary.font = .systemFont(ofSize: 15, weight: .medium)
        detail.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        detail.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        for child in [title, controls, summary, chart, detail, note] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        NSLayoutConstraint.activate([
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
        if let lastDay, lastDay != today, stats.calendar.isDate(datePicker.dateValue, inSameDayAs: lastDay) {
            datePicker.dateValue = today
        }
        lastDay = today
        datePicker.timeZone = stats.calendar.timeZone
        datePicker.maxDate = now
        let recent = mode.selectedSegment == 1
        datePicker.isEnabled = !recent
        previousButton.isEnabled = !recent
        nextButton.isEnabled = !recent && stats.calendar.startOfDay(for: datePicker.dateValue) < today
        let points = stats.points(on: datePicker.dateValue, recent24Hours: recent, now: now)
        chart.timeZone = stats.calendar.timeZone
        chart.points = points
        let recorded = points.compactMap(\.counts)
        if recorded.isEmpty {
            summary.stringValue = NSLocalizedString("hourly.empty", comment: "")
        } else {
            let keys = saturatingNonnegativeSum(recorded.map(\.keys))
            let clicks = saturatingNonnegativeSum(recorded.map(\.clicks))
            let peak = points.filter { $0.counts != nil }.max {
                saturatingNonnegativeSum([$0.counts?.keys ?? 0, $0.counts?.clicks ?? 0]) <
                saturatingNonnegativeSum([$1.counts?.keys ?? 0, $1.counts?.clicks ?? 0])
            }
            let peakText = (keys > 0 || clicks > 0) ? peak.map { chart.hourLabel($0.date) } ?? "—" : "—"
            summary.stringValue = String(format: NSLocalizedString("hourly.summary", comment: ""), keys, clicks, peakText)
        }
        let formatter = DateFormatter()
        formatter.timeZone = stats.calendar.timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        note.stringValue = String(format: NSLocalizedString("hourly.note", comment: ""),
                                  formatter.string(from: stats.startedAt), stats.timeZoneIdentifier)
        showDetail(chart.hoveredPoint)
    }

    private func configure(_ button: NSButton, title: String, label: String, action: Selector) {
        button.title = title
        button.bezelStyle = .rounded
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
        if let counts = point.counts {
            detail.stringValue = String(format: NSLocalizedString("hourly.detail", comment: ""), time, counts.keys, counts.clicks)
        } else {
            detail.stringValue = time + " · " + NSLocalizedString("hourly.unavailable", comment: "")
        }
    }

    @objc private func modeChanged() {
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
        guard let date = calendar.date(byAdding: .day, value: offset, to: datePicker.dateValue) else { return }
        datePicker.dateValue = min(date, Date())
        AppDelegate.trackClick("hourly_day", properties: ["direction": offset < 0 ? "previous" : "next"])
        chart.clearHover()
        refresh()
    }

    @objc private func previousDay() { moveDay(-1) }
    @objc private func nextDay() { moveDay(1) }
}
