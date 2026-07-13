import Cocoa

final class DeviceStatsViewController: NSViewController {
    private var scrollView: NSScrollView!
    private var documentView: NSView!
    private var contentStack: NSStackView!
    private var titleLabel: NSTextField!
    private var subtitleLabel: NSTextField!
    private var summaryLabel: NSTextField!
    private var emptyStateLabel: NSTextField!
    private var syncButton: NSButton!
    private var appearanceObservation: NSKeyValueObservation?
    private var cloudSyncObserver: NSObjectProtocol?
    private var cloudSyncObserverInstalled = false

    private lazy var numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    private lazy var syncDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    override func loadView() {
        let view = AppearanceTrackingView(frame: NSRect(x: 0, y: 0, width: 520, height: 620))
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
        installCloudSyncObserverIfNeeded()
        refreshData()
        updateAppearance()
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.updateAppearance()
            }
        }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refreshData()
    }

    deinit {
        appearanceObservation = nil
        if let cloudSyncObserver {
            NotificationCenter.default.removeObserver(cloudSyncObserver)
        }
    }

    func refreshData() {
        guard isViewLoaded else { return }
        rebuildDeviceRows()
        updateSummary()
    }

    private func setupUI() {
        titleLabel = NSTextField(labelWithString: NSLocalizedString("deviceStats.title", comment: ""))
        titleLabel.font = NSFont.systemFont(ofSize: 22, weight: .semibold)

        subtitleLabel = NSTextField(labelWithString: NSLocalizedString("deviceStats.subtitle", comment: ""))
        subtitleLabel.font = NSFont.systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byWordWrapping
        subtitleLabel.maximumNumberOfLines = 0

        summaryLabel = NSTextField(labelWithString: "")
        summaryLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        summaryLabel.textColor = .labelColor

        syncButton = NSButton(
            title: NSLocalizedString("sync.syncNow", comment: ""),
            target: self,
            action: #selector(syncNow)
        )
        syncButton.bezelStyle = .rounded
        syncButton.controlSize = .regular

        let headerStack = NSStackView(views: [titleLabel, subtitleLabel, summaryLabel])
        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 6
        headerStack.translatesAutoresizingMaskIntoConstraints = false

        let topRow = NSStackView(views: [headerStack, syncButton])
        topRow.orientation = .horizontal
        topRow.alignment = .top
        topRow.spacing = 12
        topRow.translatesAutoresizingMaskIntoConstraints = false

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        topRow.insertArrangedSubview(spacer, at: 1)

        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        documentView = FlippedDeviceStatsView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView

        contentStack = NSStackView()
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 12
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(contentStack)

        emptyStateLabel = NSTextField(labelWithString: NSLocalizedString("deviceStats.empty", comment: ""))
        emptyStateLabel.font = NSFont.systemFont(ofSize: 13)
        emptyStateLabel.textColor = .secondaryLabelColor
        emptyStateLabel.alignment = .center
        emptyStateLabel.isHidden = true

        view.addSubview(topRow)
        view.addSubview(scrollView)
        view.addSubview(emptyStateLabel)

        NSLayoutConstraint.activate([
            topRow.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            topRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            topRow.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            scrollView.topAnchor.constraint(equalTo: topRow.bottomAnchor, constant: 16),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            contentStack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 4),
            contentStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 24),
            contentStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -24),
            contentStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -24),
            contentStack.widthAnchor.constraint(equalTo: scrollView.widthAnchor, constant: -48),

            emptyStateLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyStateLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            emptyStateLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24)
        ])
    }

    private func installCloudSyncObserverIfNeeded() {
        guard !cloudSyncObserverInstalled else { return }
        cloudSyncObserverInstalled = true
        cloudSyncObserver = NotificationCenter.default.addObserver(
            forName: .cloudSyncStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshData()
        }
    }

    private func rebuildDeviceRows() {
        contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        guard CloudSyncManager.shared.isCloudDisplayAvailable else {
            emptyStateLabel.stringValue = NSLocalizedString("deviceStats.syncDisabled", comment: "")
            emptyStateLabel.isHidden = false
            syncButton.isEnabled = false
            return
        }

        syncButton.isEnabled = true
        let summaries = CloudSyncManager.shared.deviceSummariesForToday()
        guard !summaries.isEmpty else {
            emptyStateLabel.stringValue = NSLocalizedString("deviceStats.empty", comment: "")
            emptyStateLabel.isHidden = false
            return
        }

        emptyStateLabel.isHidden = true
        for summary in summaries {
            let card = DeviceStatsCardView(summary: summary, numberFormatter: numberFormatter, syncDateFormatter: syncDateFormatter)
            card.translatesAutoresizingMaskIntoConstraints = false
            contentStack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        }
    }

    private func updateSummary() {
        guard CloudSyncManager.shared.isCloudDisplayAvailable else {
            summaryLabel.stringValue = NSLocalizedString("deviceStats.summary.disabled", comment: "")
            return
        }

        let summaries = CloudSyncManager.shared.deviceSummariesForToday()
        let totalKeys = summaries.reduce(0) { $0 + $1.keyPresses }
        let totalClicks = summaries.reduce(0) { $0 + $1.totalClicks }
        summaryLabel.stringValue = String(
            format: NSLocalizedString("deviceStats.summary.format", comment: ""),
            summaries.count,
            formatNumber(totalKeys),
            formatNumber(totalClicks)
        )
    }

    private func formatNumber(_ value: Int) -> String {
        numberFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private func updateAppearance() {
        view.layer?.backgroundColor = resolvedCGColor(NSColor.windowBackgroundColor, for: view)
        view.window?.backgroundColor = NSColor.windowBackgroundColor
    }

    @objc private func syncNow() {
        AppDelegate.trackClick("cloud_sync_now_devices")
        Task {
            await CloudSyncManager.shared.syncNow()
            await MainActor.run {
                self.refreshData()
            }
        }
    }
}

final class DeviceStatsWindowController: NSWindowController {
    static let shared = DeviceStatsWindowController()

    private init() {
        let viewController = DeviceStatsViewController()
        let window = NSWindow(contentViewController: viewController)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = NSLocalizedString("deviceStats.windowTitle", comment: "")
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = true
        window.backgroundColor = .windowBackgroundColor
        window.setContentSize(NSSize(width: 520, height: 620))
        window.minSize = NSSize(width: 420, height: 420)
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
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        AppDelegate.trackPageView("device_stats")
        (contentViewController as? DeviceStatsViewController)?.refreshData()
    }
}

private final class FlippedDeviceStatsView: NSView {
    override var isFlipped: Bool { true }
}

private final class DeviceStatsCardView: NSView {
    init(summary: DeviceTodaySummary, numberFormatter: NumberFormatter, syncDateFormatter: DateFormatter) {
        super.init(frame: .zero)
        setup(summary: summary, numberFormatter: numberFormatter, syncDateFormatter: syncDateFormatter)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup(summary: DeviceTodaySummary, numberFormatter: NumberFormatter, syncDateFormatter: DateFormatter) {
        wantsLayer = true
        layer?.cornerRadius = 12

        let iconName: String
        switch summary.platform.lowercased() {
        case "windows": iconName = "desktopcomputer"
        case "linux": iconName = "server.rack"
        default: iconName = "laptopcomputer"
        }
        let iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        iconView.contentTintColor = .labelColor

        let title = NSTextField(labelWithString: summary.titleText)
        title.font = NSFont.systemFont(ofSize: 15, weight: .semibold)

        var badges = [summary.platformDisplayName]
        if summary.isLocal {
            badges.append(NSLocalizedString("deviceStats.badge.local", comment: ""))
        }
        let badgeLabel = NSTextField(labelWithString: badges.joined(separator: " · "))
        badgeLabel.font = NSFont.systemFont(ofSize: 11)
        badgeLabel.textColor = .secondaryLabelColor

        let stats = summary.asDailyStats()
        let metricsLabel = NSTextField(labelWithString: String(
            format: NSLocalizedString("deviceStats.metrics.format", comment: ""),
            formatNumber(summary.keyPresses, formatter: numberFormatter),
            formatNumber(summary.totalClicks, formatter: numberFormatter),
            stats.formattedMouseDistance,
            stats.formattedScrollDistance
        ))
        metricsLabel.font = NSFont.systemFont(ofSize: 12)
        metricsLabel.textColor = .labelColor
        metricsLabel.lineBreakMode = .byWordWrapping
        metricsLabel.maximumNumberOfLines = 0

        let syncText: String
        if let lastSyncAt = summary.lastSyncAt {
            syncText = String(
                format: NSLocalizedString("deviceStats.lastSync.format", comment: ""),
                syncDateFormatter.string(from: lastSyncAt)
            )
        } else {
            syncText = NSLocalizedString("deviceStats.lastSync.never", comment: "")
        }
        let syncLabel = NSTextField(labelWithString: syncText)
        syncLabel.font = NSFont.systemFont(ofSize: 11)
        syncLabel.textColor = .secondaryLabelColor

        let textStack = NSStackView(views: [title, badgeLabel, metricsLabel, syncLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 4

        let row = NSStackView(views: [iconView, textStack])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14)
        ])

        updateAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if isDark {
            layer?.backgroundColor = resolvedCGColor(
                NSColor(srgbRed: 39 / 255, green: 43 / 255, blue: 45 / 255, alpha: 1),
                for: self
            )
        } else {
            layer?.backgroundColor = resolvedCGColor(NSColor.controlBackgroundColor, alpha: 0.88, for: self)
        }
        layer?.borderWidth = 0.5
        layer?.borderColor = resolvedCGColor(NSColor.separatorColor, alpha: 0.16, for: self)
    }

    private func formatNumber(_ value: Int, formatter: NumberFormatter) -> String {
        formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

private func resolvedCGColor(_ color: NSColor, alpha: CGFloat = 1, for view: NSView) -> CGColor {
    let tinted = alpha < 1 ? color.withAlphaComponent(alpha) : color
    var resolved: CGColor = tinted.cgColor
    view.effectiveAppearance.performAsCurrentDrawingAppearance {
        resolved = tinted.cgColor
    }
    return resolved
}
