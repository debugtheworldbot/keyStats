import Cocoa

final class AppStatsViewController: NSViewController {
    private var scrollView: NSScrollView!
    private var documentView: NSView!
    private var containerStack: NSStackView!
    private var titleLabel: NSTextField!
    private var subtitleLabel: NSTextField!
    private var rangeControl: NSSegmentedControl!
    private var summaryLabel: NSTextField!
    private var listHeaderView: AppStatsHeaderRowView!
    private var listStack: NSStackView!
    private var emptyStateLabel: NSTextField!
    private var separatorLine: NSView!
    private var appearanceObservation: NSKeyValueObservation?
    private var sortMetric: SortMetric = .keys
    private var appIconCache: [String: NSImage] = [:]
    private lazy var defaultAppIcon: NSImage = {
        NSWorkspace.shared.icon(forFileType: "app")
    }()

    private lazy var numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    // MARK: - Lifecycle

    override func loadView() {
        let view = AppearanceTrackingView(frame: NSRect(x: 0, y: 0, width: 560, height: 640))
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

    override func viewWillAppear() {
        super.viewWillAppear()
        refreshData()
    }
    
    deinit {
        appearanceObservation = nil
    }

    // MARK: - UI

    private func setupUI() {
        let headerContainer = NSView()
        headerContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(headerContainer)

        listHeaderView = AppStatsHeaderRowView()
        listHeaderView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(listHeaderView)

        // Separator line under header
        separatorLine = NSView()
        separatorLine.translatesAutoresizingMaskIntoConstraints = false
        separatorLine.wantsLayer = true
        separatorLine.layer?.backgroundColor = NSColor.separatorColor.cgColor
        view.addSubview(separatorLine)

        scrollView = NSScrollView(frame: view.bounds)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            headerContainer.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            headerContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            listHeaderView.topAnchor.constraint(equalTo: headerContainer.bottomAnchor, constant: 12),
            listHeaderView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            listHeaderView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),

            separatorLine.topAnchor.constraint(equalTo: listHeaderView.bottomAnchor, constant: 8),
            separatorLine.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            separatorLine.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
            separatorLine.heightAnchor.constraint(equalToConstant: 1),

            scrollView.topAnchor.constraint(equalTo: separatorLine.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        documentView = FlippedView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView

        containerStack = NSStackView()
        containerStack.orientation = .vertical
        containerStack.alignment = .leading
        containerStack.spacing = 18
        containerStack.edgeInsets = NSEdgeInsets(top: 0, left: 28, bottom: 28, right: 28)
        containerStack.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(containerStack)

        NSLayoutConstraint.activate([
            containerStack.topAnchor.constraint(equalTo: documentView.topAnchor),
            containerStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            containerStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            containerStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
            containerStack.widthAnchor.constraint(equalTo: scrollView.widthAnchor)
        ])

        rangeControl = NSSegmentedControl(labels: [
            NSLocalizedString("appStats.range.today", comment: ""),
            NSLocalizedString("appStats.range.week", comment: ""),
            NSLocalizedString("appStats.range.month", comment: ""),
            NSLocalizedString("appStats.range.all", comment: "")
        ], trackingMode: .selectOne, target: self, action: #selector(controlsChanged))
        rangeControl.selectedSegment = 0

        rangeControl.setContentHuggingPriority(.defaultLow, for: .horizontal)
        rangeControl.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let controlsStack = NSStackView(views: [rangeControl])
        controlsStack.orientation = .vertical
        controlsStack.alignment = .leading
        controlsStack.spacing = 8

        let headerStack = NSStackView()
        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 8
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        headerContainer.addSubview(headerStack)

        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: headerContainer.topAnchor, constant: 16),
            headerStack.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor, constant: 28),
            headerStack.trailingAnchor.constraint(equalTo: headerContainer.trailingAnchor, constant: -28),
            headerStack.bottomAnchor.constraint(equalTo: headerContainer.bottomAnchor, constant: -12)
        ])

        titleLabel = NSTextField(labelWithString: NSLocalizedString("appStats.title", comment: ""))
        titleLabel.font = NSFont.systemFont(ofSize: 26, weight: .bold)
        titleLabel.textColor = .labelColor

        subtitleLabel = NSTextField(wrappingLabelWithString: NSLocalizedString("appStats.subtitle", comment: ""))
        subtitleLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        subtitleLabel.textColor = .secondaryLabelColor

        headerStack.addArrangedSubview(titleLabel)
        headerStack.addArrangedSubview(subtitleLabel)
        headerStack.addArrangedSubview(controlsStack)

        emptyStateLabel = NSTextField(labelWithString: "")
        emptyStateLabel.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        emptyStateLabel.textColor = .secondaryLabelColor
        emptyStateLabel.isHidden = true

        summaryLabel = NSTextField(labelWithString: "")
        summaryLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        summaryLabel.textColor = .secondaryLabelColor

        headerStack.addArrangedSubview(emptyStateLabel)
        headerStack.addArrangedSubview(summaryLabel)

        listHeaderView.sortMetricHandler = { [weak self] metric in
            self?.updateSortMetric(metric)
        }
        listHeaderView.updateSortIndicator(selectedMetric: sortMetric)

        listStack = NSStackView()
        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 0
        containerStack.addArrangedSubview(listStack)
        listStack.widthAnchor.constraint(equalTo: containerStack.widthAnchor, constant: -56).isActive = true

        containerStack.addArrangedSubview(NSView())
    }

    // MARK: - Data

    func refreshData() {
        let statsManager = StatsManager.shared
        if !statsManager.appStatsEnabled {
            updateEmptyState(text: NSLocalizedString("appStats.disabled", comment: ""))
            return
        }

        let range = selectedRange()
        var items = statsManager.appStatsSummary(range: range)
        items = items.filter { $0.hasActivity }
        items.sort { lhs, rhs in
            let lhsValue = sortValue(for: lhs)
            let rhsValue = sortValue(for: rhs)
            if lhsValue != rhsValue {
                return lhsValue > rhsValue
            }
            return displayName(for: lhs).localizedCaseInsensitiveCompare(displayName(for: rhs)) == .orderedAscending
        }

        updateSummary(with: items)
        updateList(with: items)
    }

    private func updateSummary(with items: [AppStats]) {
        summaryLabel.isHidden = false
        let totalKeys = items.reduce(0) { $0 + $1.keyPresses }
        let totalClicks = items.reduce(0) { $0 + $1.totalClicks }
        let totalScroll = items.reduce(0) { $0 + $1.scrollDistance }
        let formattedKeys = formatNumber(totalKeys)
        let formattedClicks = formatNumber(totalClicks)
        let formattedScroll = formatScrollDistance(totalScroll)
        summaryLabel.stringValue = String(
            format: NSLocalizedString("appStats.summary", comment: ""),
            formattedKeys,
            formattedClicks,
            formattedScroll
        )
    }

    private func updateList(with items: [AppStats]) {
        listStack.arrangedSubviews.forEach {
            listStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        guard !items.isEmpty else {
            updateEmptyState(text: NSLocalizedString("appStats.empty", comment: ""))
            return
        }

        listHeaderView.isHidden = false
        emptyStateLabel.isHidden = true

        let maxKeys = Double(items.map { $0.keyPresses }.max() ?? 1)
        let maxClicks = Double(items.map { $0.totalClicks }.max() ?? 1)
        let maxScroll = items.map { $0.scrollDistance }.max() ?? 1

        var rows: [AppStatsRowView] = []

        for (index, item) in items.enumerated() {
            let row = AppStatsRowView()
            row.applyAlternatingBackground(isEvenRow: index.isMultiple(of: 2))
            row.update(
                name: displayName(for: item),
                icon: appIcon(for: item.bundleId),
                keys: Double(item.keyPresses),
                clicks: Double(item.totalClicks),
                scroll: item.scrollDistance,
                maxKeys: maxKeys,
                maxClicks: maxClicks,
                maxScroll: maxScroll,
                keysFormatted: formatNumber(item.keyPresses),
                keysCompact: formatCompact(item.keyPresses),
                clicksFormatted: formatNumber(item.totalClicks),
                clicksCompact: formatCompact(item.totalClicks),
                scrollFormatted: formatScrollDistance(item.scrollDistance)
            )
            listStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
            rows.append(row)
        }

        DispatchQueue.main.async {
            for (index, row) in rows.enumerated() {
                let delay = Double(index) * 0.03
                row.animateBars(delay: delay)
            }
        }
    }

    private func updateEmptyState(text: String) {
        listHeaderView.isHidden = true
        listStack.arrangedSubviews.forEach {
            listStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        emptyStateLabel.stringValue = text
        emptyStateLabel.isHidden = false
        summaryLabel.stringValue = ""
        summaryLabel.isHidden = true
    }

    private func displayName(for stats: AppStats) -> String {
        if !stats.displayName.isEmpty {
            return stats.displayName
        }
        return NSLocalizedString("appStats.unknownApp", comment: "")
    }

    private func sortValue(for stats: AppStats) -> Double {
        switch sortMetric {
        case .keys:
            return Double(stats.keyPresses)
        case .clicks:
            return Double(stats.totalClicks)
        case .scroll:
            return stats.scrollDistance
        }
    }

    private func formatNumber(_ number: Int) -> String {
        return numberFormatter.string(from: NSNumber(value: number)) ?? "\(number)"
    }
    
    private func formatCompact(_ number: Int) -> String {
        let num = Double(number)
        if num >= 1_000_000 {
            // 1.2M
            return String(format: "%.1fM", num / 1_000_000)
        } else if num >= 10_000 {
            // 12K (no decimal for K to be more compact)
            return String(format: "%.0fK", num / 1_000)
        }
        return formatNumber(number)
    }

    private func formatScrollDistance(_ distance: Double) -> String {
        if distance >= 10000 {
            return String(format: "%.1f kPx", distance / 1000)
        }
        return String(format: "%.0f px", distance)
    }

    private func appIcon(for bundleId: String) -> NSImage {
        let trimmed = bundleId.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cached = appIconCache[trimmed] {
            return cached
        }
        let source: NSImage
        if !trimmed.isEmpty, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: trimmed) {
            let workspaceIcon = NSWorkspace.shared.icon(forFile: url.path)
            source = (workspaceIcon.copy() as? NSImage) ?? workspaceIcon
        } else {
            source = (defaultAppIcon.copy() as? NSImage) ?? defaultAppIcon
        }
        let icon = rasterizeAppIcon(source)
        appIconCache[trimmed] = icon
        return icon
    }

    // MARK: - Icon Rendering

    private func rasterizeAppIcon(_ source: NSImage) -> NSImage {
        let targetSize = NSSize(width: AppStatsLayout.appIconSize, height: AppStatsLayout.appIconSize)
        guard let rep = makeIconRep(from: source, targetSize: targetSize) else { return source }
        let image = NSImage(size: targetSize)
        image.addRepresentation(rep)
        return image
    }

    private func makeIconRep(from source: NSImage, targetSize: NSSize) -> NSBitmapImageRep? {
        let scale: CGFloat = 2.0
        let pixelWidth = max(1, Int(targetSize.width * scale))
        let pixelHeight = max(1, Int(targetSize.height * scale))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }
        rep.size = targetSize

        NSGraphicsContext.saveGraphicsState()
        if let context = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = context
            context.imageInterpolation = .high
            source.draw(
                in: NSRect(origin: .zero, size: targetSize),
                from: NSRect(origin: .zero, size: source.size),
                operation: .copy,
                fraction: 1.0,
                respectFlipped: false,
                hints: nil
            )
        }
        NSGraphicsContext.restoreGraphicsState()

        return rep
    }

    // MARK: - Controls

    @objc private func controlsChanged() {
        refreshData()
    }

    private func updateSortMetric(_ metric: SortMetric) {
        sortMetric = metric
        listHeaderView.updateSortIndicator(selectedMetric: metric)
        refreshData()
    }

    private func selectedRange() -> StatsManager.AppStatsRange {
        switch rangeControl.selectedSegment {
        case 0:
            return .today
        case 1:
            return .week
        case 2:
            return .month
        default:
            return .all
        }
    }
    
    // MARK: - Appearance Updates
    
    private func updateAppearance() {
        // 更新主视图背景色
        view.layer?.backgroundColor = resolvedCGColor(NSColor.windowBackgroundColor, for: view)
        view.window?.backgroundColor = resolvedColor(NSColor.windowBackgroundColor, for: view)
        
        // 更新分隔线颜色
        separatorLine.layer?.backgroundColor = resolvedCGColor(NSColor.separatorColor, for: view)
        
        // 更新列表行的背景色
        for (index, row) in listStack.arrangedSubviews.enumerated() {
            if let appRow = row as? AppStatsRowView {
                appRow.applyAlternatingBackground(isEvenRow: index.isMultiple(of: 2))
            }
        }

        // 通知所有子视图更新 appearance
        view.needsDisplay = true
        listHeaderView?.needsDisplay = true
    }
}

final class AppearanceTrackingView: NSView {
    var onEffectiveAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        DispatchQueue.main.async { [weak self] in
            self?.onEffectiveAppearanceChange?()
        }
    }
}

private enum SortMetric {
    case keys
    case clicks
    case scroll
}

private final class FlippedView: NSView {
    override var isFlipped: Bool {
        return true
    }
}

private enum AppStatsLayout {
    static let appColumnMaxWidth: CGFloat = 180
    static let metricColumnWidth: CGFloat = 93
    static let columnSpacing: CGFloat = 12
    static let rowHeight: CGFloat = 32
    static let rowCornerRadius: CGFloat = 8
    static let headerHeight: CGFloat = 20
    static let dividerThickness: CGFloat = 1
    static let dividerHitWidth: CGFloat = 6
    static let dividerVerticalInset: CGFloat = 0
    static let appIconSize: CGFloat = 24
    static let appIconSpacing: CGFloat = 6
    static let appIconLeadingInset: CGFloat = 6
    static let barHeight: CGFloat = 16
    static let barCornerRadius: CGFloat = 4
}

private final class SortableHeaderLabel: NSTextField {
    let metric: SortMetric
    let baseText: String
    var onClick: ((SortMetric) -> Void)?

    init(text: String, metric: SortMetric) {
        self.baseText = text
        self.metric = metric
        super.init(frame: .zero)
        isEditable = false
        isBordered = false
        drawsBackground = false
        isSelectable = false
        stringValue = text
        focusRingType = .none
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        onClick?(metric)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    func updateIndicator(_ indicator: String?) {
        if let indicator = indicator, !indicator.isEmpty {
            stringValue = "\(baseText) \(indicator)"
        } else {
            stringValue = baseText
        }
    }
}

private final class AppStatsHeaderRowView: NSView {
    private let sortIndicator = NSLocalizedString("appStats.sortIndicator", comment: "")
    private var nameStack: NSStackView!
    private var nameSpacer: NSView!
    private var nameLabel: NSTextField!
    private var keysLabel: SortableHeaderLabel!
    private var clicksLabel: SortableHeaderLabel!
    private var scrollLabel: SortableHeaderLabel!

    var sortMetricHandler: ((SortMetric) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: AppStatsLayout.headerHeight).isActive = true

        nameLabel = makeHeaderLabel(text: NSLocalizedString("appStats.column.app", comment: ""), isNameColumn: true)
        keysLabel = makeSortableHeaderLabel(text: NSLocalizedString("appStats.column.keys", comment: ""), metric: .keys)
        clicksLabel = makeSortableHeaderLabel(text: NSLocalizedString("appStats.column.clicks", comment: ""), metric: .clicks)
        scrollLabel = makeSortableHeaderLabel(text: NSLocalizedString("appStats.column.scroll", comment: ""), metric: .scroll)

        nameSpacer = NSView()
        nameStack = NSStackView(views: [nameSpacer, nameLabel])
        nameStack.orientation = .horizontal
        nameStack.alignment = .centerY
        nameStack.spacing = AppStatsLayout.appIconSpacing
        nameStack.edgeInsets = NSEdgeInsets(
            top: 0,
            left: AppStatsLayout.appIconLeadingInset,
            bottom: 0,
            right: 0
        )
        nameStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nameStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [nameStack, keysLabel, clicksLabel, scrollLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.spacing = AppStatsLayout.columnSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        NSLayoutConstraint.activate([
            nameStack.widthAnchor.constraint(equalToConstant: AppStatsLayout.appColumnMaxWidth),
            nameSpacer.widthAnchor.constraint(equalToConstant: AppStatsLayout.appIconSize),
            // 三列等宽
            keysLabel.widthAnchor.constraint(equalTo: clicksLabel.widthAnchor),
            clicksLabel.widthAnchor.constraint(equalTo: scrollLabel.widthAnchor)
        ])

        addDividerView(after: nameStack)
        addDividerView(after: keysLabel)
        addDividerView(after: clicksLabel)
    }

    func updateSortIndicator(selectedMetric: SortMetric) {
        let indicator = sortIndicator.isEmpty ? nil : sortIndicator
        keysLabel.updateIndicator(selectedMetric == .keys ? indicator : nil)
        clicksLabel.updateIndicator(selectedMetric == .clicks ? indicator : nil)
        scrollLabel.updateIndicator(selectedMetric == .scroll ? indicator : nil)
    }

    private func makeHeaderLabel(text: String, isNameColumn: Bool) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        configureHeaderLabel(label, isNameColumn: isNameColumn)
        return label
    }

    private func makeSortableHeaderLabel(text: String, metric: SortMetric) -> SortableHeaderLabel {
        let label = SortableHeaderLabel(text: text, metric: metric)
        configureHeaderLabel(label, isNameColumn: false)
        label.onClick = { [weak self] metric in
            self?.sortMetricHandler?(metric)
        }
        return label
    }

    private func configureHeaderLabel(_ label: NSTextField, isNameColumn: Bool) {
        label.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.alignment = isNameColumn ? .left : .center
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    private func addDividerView(after view: NSView) {
        let dividerView = AppStatsColumnDividerView()
        dividerView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dividerView)
        NSLayoutConstraint.activate([
            dividerView.centerXAnchor.constraint(
                equalTo: view.trailingAnchor,
                constant: AppStatsLayout.columnSpacing / 2
            ),
            dividerView.topAnchor.constraint(equalTo: topAnchor),
            dividerView.bottomAnchor.constraint(equalTo: bottomAnchor),
            dividerView.widthAnchor.constraint(equalToConstant: AppStatsLayout.dividerHitWidth)
        ])
    }
}

private final class AppStatsRowView: NSView {
    private var nameStack: NSStackView!
    private var iconView: NSImageView!
    private var nameLabel: NSTextField!
    private var keysBar: SingleBarView!
    private var clicksBar: SingleBarView!
    private var scrollBar: SingleBarView!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: AppStatsLayout.rowHeight).isActive = true

        iconView = NSImageView()
        iconView.imageScaling = .scaleProportionallyDown
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)

        nameLabel = NSTextField(labelWithString: "")
        nameLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1
        nameLabel.usesSingleLineMode = true
        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        nameStack = NSStackView(views: [iconView, nameLabel])
        nameStack.orientation = .horizontal
        nameStack.alignment = .centerY
        nameStack.spacing = AppStatsLayout.appIconSpacing
        nameStack.edgeInsets = NSEdgeInsets(
            top: 0,
            left: AppStatsLayout.appIconLeadingInset,
            bottom: 0,
            right: 0
        )
        nameStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nameStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        keysBar = SingleBarView(color: .systemBlue)
        keysBar.translatesAutoresizingMaskIntoConstraints = false
        clicksBar = SingleBarView(color: .systemGreen)
        clicksBar.translatesAutoresizingMaskIntoConstraints = false
        scrollBar = SingleBarView(color: .systemOrange)
        scrollBar.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [nameStack, keysBar, clicksBar, scrollBar])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = AppStatsLayout.columnSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        NSLayoutConstraint.activate([
            nameStack.widthAnchor.constraint(equalToConstant: AppStatsLayout.appColumnMaxWidth),
            keysBar.heightAnchor.constraint(equalToConstant: AppStatsLayout.rowHeight),
            clicksBar.heightAnchor.constraint(equalToConstant: AppStatsLayout.rowHeight),
            scrollBar.heightAnchor.constraint(equalToConstant: AppStatsLayout.rowHeight),
            // 三列等宽
            keysBar.widthAnchor.constraint(equalTo: clicksBar.widthAnchor),
            clicksBar.widthAnchor.constraint(equalTo: scrollBar.widthAnchor)
        ])
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: AppStatsLayout.appIconSize),
            iconView.heightAnchor.constraint(equalToConstant: AppStatsLayout.appIconSize)
        ])
    }

    func update(
        name: String,
        icon: NSImage?,
        keys: Double, clicks: Double, scroll: Double,
        maxKeys: Double, maxClicks: Double, maxScroll: Double,
        keysFormatted: String, keysCompact: String,
        clicksFormatted: String, clicksCompact: String,
        scrollFormatted: String
    ) {
        iconView.image = icon
        nameLabel.stringValue = name
        nameLabel.toolTip = name
        keysBar.update(value: keys, maxValue: maxKeys, formatted: keysFormatted, compact: keysCompact)
        clicksBar.update(value: clicks, maxValue: maxClicks, formatted: clicksFormatted, compact: clicksCompact)
        // Scroll distance uses same formatted string for compact as it's already compact (kPx)
        scrollBar.update(value: scroll, maxValue: maxScroll, formatted: scrollFormatted, compact: nil)
    }

    func animateBars(delay: TimeInterval) {
        keysBar.animateIn(delay: delay)
        clicksBar.animateIn(delay: delay + 0.05)
        scrollBar.animateIn(delay: delay + 0.1)
    }

    func applyAlternatingBackground(isEvenRow: Bool) {
        wantsLayer = true
        let colors = NSColor.controlAlternatingRowBackgroundColors
        let index = isEvenRow ? 0 : 1
        let fallback = isEvenRow ? NSColor.windowBackgroundColor : NSColor.controlBackgroundColor
        let color = colors.count > index ? colors[index] : fallback
        layer?.backgroundColor = resolvedCGColor(color, for: self)
        layer?.cornerRadius = isEvenRow ? 0 : AppStatsLayout.rowCornerRadius
    }
}

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

private final class SingleBarView: NSView {
    private var barLayer: CALayer!
    private var valueLabel: NSTextField!
    private var value: Double = 0
    private var maxValue: Double = 1
    private var formattedValue: String = ""
    private var compactValue: String?
    private var targetBarWidth: CGFloat = 0
    private let labelPadding: CGFloat = 4
    private let animationDuration: TimeInterval = 0.35
    private var isAnimating = false
    private var animationToken = UUID()

    init(color: NSColor) {
        super.init(frame: .zero)
        setupUI(color: color)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI(color: .systemBlue)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI(color: NSColor) {
        wantsLayer = true
        layer?.masksToBounds = false

        barLayer = CALayer()
        barLayer.backgroundColor = color.cgColor
        barLayer.cornerRadius = AppStatsLayout.barCornerRadius
        barLayer.anchorPoint = CGPoint(x: 0, y: 0.5)
        layer?.addSublayer(barLayer)

        valueLabel = NSTextField(labelWithString: "")
        valueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right
        valueLabel.backgroundColor = .clear
        valueLabel.drawsBackground = false
        valueLabel.isBezeled = false
        valueLabel.isEditable = false
        valueLabel.lineBreakMode = .byTruncatingTail
        valueLabel.usesSingleLineMode = true
        addSubview(valueLabel)
    }

    override func layout() {
        super.layout()
        recalculateBarWidth()
        updateBarPosition(animated: false)
        updateLabelPosition()
    }

    func update(value: Double, maxValue: Double, formatted: String, compact: String?) {
        self.value = value
        self.maxValue = max(1, maxValue)
        self.formattedValue = formatted
        self.compactValue = compact
        valueLabel.stringValue = formatted
        recalculateBarWidth()
    }

    private func recalculateBarWidth() {
        targetBarWidth = bounds.width * CGFloat(value / maxValue)
    }

    func animateIn(delay: TimeInterval = 0) {
        targetBarWidth = bounds.width * CGFloat(value / maxValue)
        isAnimating = true
        let token = UUID()
        animationToken = token

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        barLayer.frame = CGRect(x: 0, y: (bounds.height - AppStatsLayout.barHeight) / 2, width: 0, height: AppStatsLayout.barHeight)
        CATransaction.commit()

        let animation = CABasicAnimation(keyPath: "bounds.size.width")
        animation.fromValue = 0
        animation.toValue = targetBarWidth
        animation.duration = animationDuration
        animation.beginTime = CACurrentMediaTime() + delay
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
        barLayer.add(animation, forKey: "widthAnimation")

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        barLayer.bounds.size.width = targetBarWidth
        CATransaction.commit()

        updateLabelPosition()

        let totalDelay = delay + animationDuration
        DispatchQueue.main.asyncAfter(deadline: .now() + totalDelay) { [weak self] in
            guard let self = self, self.animationToken == token else { return }
            self.isAnimating = false
            self.barLayer.removeAnimation(forKey: "widthAnimation")
            self.updateBarPosition(animated: false)
            self.updateLabelPosition()
        }
    }

    private func updateBarPosition(animated: Bool) {
        if !isAnimating {
            barLayer.removeAnimation(forKey: "widthAnimation")
        }

        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        barLayer.frame = CGRect(x: 0, y: (bounds.height - AppStatsLayout.barHeight) / 2, width: targetBarWidth, height: AppStatsLayout.barHeight)
        CATransaction.commit()
    }

    private func updateLabelPosition() {
        // Reset to default font to measure preferred width
        let defaultFontSize: CGFloat = 10
        let minReadableFontSize: CGFloat = 9.0
        let minAbsoluteFontSize: CGFloat = 7.0
        
        // Ensure tooltip is set for accessibility/checking truncated values
        valueLabel.toolTip = formattedValue
        
        // 1. Try Full Text
        valueLabel.stringValue = formattedValue
        valueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: defaultFontSize, weight: .medium)
        valueLabel.sizeToFit()
        var preferredSize = valueLabel.frame.size

        // Calculate available space
        let spaceInside = max(0, targetBarWidth - labelPadding * 2)
        let spaceOutside = max(0, bounds.width - targetBarWidth - labelPadding)
        
        // Determine placement strategy (prefer inside if space allows, else larger space)
        var placeInside = spaceInside >= preferredSize.width
        if !placeInside {
            if spaceOutside >= preferredSize.width {
                placeInside = false
            } else {
                placeInside = spaceInside > spaceOutside
            }
        }

        var availableWidth = placeInside ? spaceInside : spaceOutside

        // 2. Adaptive Logic
        // If full text is too wide, check if we should switch to compact
        if preferredSize.width > availableWidth {
            // Check what font size would be needed
            let scale = availableWidth / max(1, preferredSize.width)
            let projectedFontSize = floor(defaultFontSize * scale)
            
            // If projected font is too small, AND we have a compact string, switch to it
            if projectedFontSize < minReadableFontSize, let compact = compactValue {
                valueLabel.stringValue = compact
                valueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: defaultFontSize, weight: .medium)
                valueLabel.sizeToFit()
                preferredSize = valueLabel.frame.size
                
                // Re-evaluate placement for compact string
                let compactFitsInside = spaceInside >= preferredSize.width
                if compactFitsInside {
                    placeInside = true
                } else if spaceOutside >= preferredSize.width {
                    placeInside = false
                } else {
                    placeInside = spaceInside > spaceOutside
                }
                availableWidth = placeInside ? spaceInside : spaceOutside
            }
            
            // 3. Final Scaling (works for both full or compact)
            if preferredSize.width > availableWidth {
                let finalScale = availableWidth / max(1, preferredSize.width)
                let finalFontSize = max(minAbsoluteFontSize, floor(defaultFontSize * finalScale))
                valueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: finalFontSize, weight: .medium)
                valueLabel.sizeToFit()
            }
        }

        let finalSize = valueLabel.frame.size
        // Ensure width doesn't exceed available even after scaling
        let finalWidth = min(finalSize.width, availableWidth)
        let finalHeight = finalSize.height
        let finalY = (bounds.height - finalHeight) / 2

        if placeInside {
            let labelX = targetBarWidth - finalWidth - labelPadding
            valueLabel.frame = CGRect(x: labelX, y: finalY, width: finalWidth, height: finalHeight)
            valueLabel.textColor = .white
            valueLabel.alignment = .right
        } else {
            let labelX = targetBarWidth + labelPadding
            valueLabel.frame = CGRect(x: labelX, y: finalY, width: finalWidth, height: finalHeight)
            valueLabel.textColor = .secondaryLabelColor
            valueLabel.alignment = .left
        }
    }
}

private final class AppStatsColumnDividerView: NSView {
    override var mouseDownCanMoveWindow: Bool {
        return false
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let inset = AppStatsLayout.dividerVerticalInset
        let lineHeight = max(0, bounds.height - (inset * 2))
        let lineRect = NSRect(
            x: (bounds.width - AppStatsLayout.dividerThickness) / 2,
            y: inset,
            width: AppStatsLayout.dividerThickness,
            height: lineHeight
        )
        NSColor.separatorColor.setFill()
        lineRect.fill()
    }
}
