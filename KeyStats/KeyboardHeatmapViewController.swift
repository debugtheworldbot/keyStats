import Cocoa

private func resolvedCGColor(_ color: NSColor, for view: NSView) -> CGColor {
    var resolved: CGColor = color.cgColor
    view.effectiveAppearance.performAsCurrentDrawingAppearance {
        resolved = color.cgColor
    }
    return resolved
}

private func resolvedCGColor(_ color: NSColor, alpha: CGFloat, for view: NSView) -> CGColor {
    var resolved: CGColor = color.cgColor
    view.effectiveAppearance.performAsCurrentDrawingAppearance {
        resolved = color.withAlphaComponent(alpha).cgColor
    }
    return resolved
}

private func resolvedColor(_ color: NSColor, for view: NSView) -> NSColor {
    let cgColor = resolvedCGColor(color, for: view)
    return NSColor(cgColor: cgColor) ?? color
}

private func applyCardShadow(_ layer: CALayer?, for view: NSView) {
    guard let layer = layer else { return }
    layer.masksToBounds = false
    layer.shadowColor = resolvedCGColor(NSColor.black, alpha: 0.07, for: view)
    layer.shadowOpacity = 1
    layer.shadowRadius = 8
    layer.shadowOffset = NSSize(width: 0, height: -1)
    layer.borderWidth = 0.5
    layer.borderColor = resolvedCGColor(NSColor.separatorColor, alpha: 0.16, for: view)
}

final class KeyboardHeatmapViewController: NSViewController {
    private enum DaySlideDirection {
        case left
        case right

        func incomingOffset(distance: CGFloat) -> CGFloat {
            switch self {
            case .left: return -distance
            case .right: return distance
            }
        }

        func outgoingOffset(distance: CGFloat) -> CGFloat {
            -incomingOffset(distance: distance)
        }
    }

    private var titleLabel: NSTextField!
    private var subtitleLabel: NSTextField!
    private var previousDayButton: NSButton!
    private var nextDayButton: NSButton!
    private var backToTodayButton: NSButton!
    private var datePickerButton: NSButton!
    private var summaryLabel: NSTextField!
    private var heatmapContainer: NSView!
    private var keyboardHeatmapView: KeyboardHeatmapView!
    private var keyboardEmptyOverlayView: NSView!
    private var emptyStateBadgeView: EmptyStateBadgeView!

    private var selectedDate = Calendar.current.startOfDay(for: Date())
    private var dateBounds: (start: Date, end: Date) = {
        let today = Calendar.current.startOfDay(for: Date())
        return (today, today)
    }()

    private var statsUpdateToken: UUID?
    private var pendingRefresh = false
    private var isDayTransitionAnimating = false
    private var appearanceObservation: NSKeyValueObservation?
    private lazy var datePickerPopover: NSPopover = makeDatePickerPopover()
    private lazy var datePickerViewController: HeatmapDatePickerPopoverViewController = {
        let viewController = HeatmapDatePickerPopoverViewController()
        viewController.onDateSelected = { [weak self] date in
            self?.handleDateSelection(date)
        }
        return viewController
    }()

    private lazy var dateFormatterWithoutYear: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("Md")
        return formatter
    }()

    private lazy var dateFormatterWithYear: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("yMd")
        return formatter
    }()

    private lazy var numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    override func loadView() {
        let trackingView = AppearanceTrackingView(frame: NSRect(x: 0, y: 0, width: 980, height: 520))
        trackingView.onEffectiveAppearanceChange = { [weak self] in
            self?.updateAppearance()
        }
        trackingView.wantsLayer = true
        trackingView.layer?.backgroundColor = resolvedCGColor(NSColor.windowBackgroundColor, for: trackingView)
        self.view = trackingView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
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
        startLiveUpdates()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        stopLiveUpdates()
    }

    deinit {
        stopLiveUpdates()
        appearanceObservation = nil
    }

    private func setupUI() {
        let containerStack = NSStackView()
        containerStack.orientation = .vertical
        containerStack.alignment = .leading
        containerStack.spacing = 16
        containerStack.edgeInsets = NSEdgeInsets(top: 24, left: 30, bottom: 24, right: 30)
        containerStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(containerStack)

        let preferredContentWidth = containerStack.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -40)
        preferredContentWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            containerStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            containerStack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            containerStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            containerStack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            containerStack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
            preferredContentWidth,
            containerStack.widthAnchor.constraint(lessThanOrEqualToConstant: 1450)
        ])

        titleLabel = NSTextField(labelWithString: NSLocalizedString("keyboardHeatmap.title", comment: ""))
        titleLabel.font = NSFont.systemFont(ofSize: 26, weight: .bold)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .left

        subtitleLabel = NSTextField(labelWithString: NSLocalizedString("keyboardHeatmap.subtitle", comment: ""))
        subtitleLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.alignment = .left

        let headerStack = NSStackView(views: [titleLabel, subtitleLabel])
        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 6
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        containerStack.addArrangedSubview(headerStack)
        headerStack.widthAnchor.constraint(equalTo: containerStack.widthAnchor).isActive = true

        previousDayButton = makeIconControlButton(
            systemName: "chevron.left",
            accessibilityLabel: NSLocalizedString("keyboardHeatmap.prevDay", comment: ""),
            action: #selector(showPreviousDay)
        )
        nextDayButton = makeIconControlButton(
            systemName: "chevron.right",
            accessibilityLabel: NSLocalizedString("keyboardHeatmap.nextDay", comment: ""),
            action: #selector(showNextDay)
        )
        backToTodayButton = makeControlButton(title: NSLocalizedString("keyboardHeatmap.backToToday", comment: ""), action: #selector(backToToday))
        backToTodayButton.isHidden = true

        datePickerButton = makeDatePickerButton()

        summaryLabel = NSTextField(labelWithString: "")
        summaryLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.maximumNumberOfLines = 1

        let navigationStack = NSStackView()
        navigationStack.orientation = .horizontal
        navigationStack.alignment = .centerY
        navigationStack.spacing = 10
        navigationStack.translatesAutoresizingMaskIntoConstraints = false

        let dayNavigationStack = NSStackView(views: [previousDayButton, datePickerButton, nextDayButton])
        dayNavigationStack.orientation = .horizontal
        dayNavigationStack.alignment = .centerY
        dayNavigationStack.spacing = 8
        dayNavigationStack.setContentHuggingPriority(.required, for: .horizontal)
        dayNavigationStack.setContentCompressionResistancePriority(.required, for: .horizontal)

        let spacer = NSView()
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        navigationStack.addArrangedSubview(dayNavigationStack)
        navigationStack.addArrangedSubview(backToTodayButton)
        navigationStack.addArrangedSubview(spacer)
        navigationStack.addArrangedSubview(summaryLabel)

        containerStack.addArrangedSubview(navigationStack)
        navigationStack.widthAnchor.constraint(equalTo: containerStack.widthAnchor).isActive = true

        heatmapContainer = NSView()
        heatmapContainer.translatesAutoresizingMaskIntoConstraints = false
        heatmapContainer.wantsLayer = true
        heatmapContainer.layer?.cornerRadius = 16
        heatmapContainer.layer?.borderWidth = 0.5

        keyboardHeatmapView = KeyboardHeatmapView()
        keyboardHeatmapView.wantsLayer = true
        keyboardHeatmapView.translatesAutoresizingMaskIntoConstraints = false

        keyboardEmptyOverlayView = NSView()
        keyboardEmptyOverlayView.wantsLayer = true
        keyboardEmptyOverlayView.translatesAutoresizingMaskIntoConstraints = false
        keyboardEmptyOverlayView.layer?.cornerRadius = 12
        keyboardEmptyOverlayView.isHidden = true

        emptyStateBadgeView = EmptyStateBadgeView(text: NSLocalizedString("keyboardHeatmap.noData", comment: ""))
        emptyStateBadgeView.isHidden = true
        emptyStateBadgeView.translatesAutoresizingMaskIntoConstraints = false

        heatmapContainer.addSubview(keyboardHeatmapView)
        heatmapContainer.addSubview(keyboardEmptyOverlayView)
        heatmapContainer.addSubview(emptyStateBadgeView)

        NSLayoutConstraint.activate([
            keyboardHeatmapView.leadingAnchor.constraint(equalTo: heatmapContainer.leadingAnchor, constant: 12),
            keyboardHeatmapView.trailingAnchor.constraint(equalTo: heatmapContainer.trailingAnchor, constant: -12),
            keyboardHeatmapView.topAnchor.constraint(equalTo: heatmapContainer.topAnchor, constant: 10),
            keyboardHeatmapView.bottomAnchor.constraint(equalTo: heatmapContainer.bottomAnchor, constant: -10),
            keyboardHeatmapView.heightAnchor.constraint(greaterThanOrEqualToConstant: 320),

            keyboardEmptyOverlayView.leadingAnchor.constraint(equalTo: keyboardHeatmapView.leadingAnchor),
            keyboardEmptyOverlayView.trailingAnchor.constraint(equalTo: keyboardHeatmapView.trailingAnchor),
            keyboardEmptyOverlayView.topAnchor.constraint(equalTo: keyboardHeatmapView.topAnchor),
            keyboardEmptyOverlayView.bottomAnchor.constraint(equalTo: keyboardHeatmapView.bottomAnchor),

            emptyStateBadgeView.centerXAnchor.constraint(equalTo: heatmapContainer.centerXAnchor),
            emptyStateBadgeView.centerYAnchor.constraint(equalTo: heatmapContainer.centerYAnchor)
        ])

        containerStack.addArrangedSubview(heatmapContainer)
        heatmapContainer.widthAnchor.constraint(equalTo: containerStack.widthAnchor).isActive = true
    }

    private func makeControlButton(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    private func makeIconControlButton(systemName: String, accessibilityLabel: String, action: Selector) -> NSButton {
        let button = NSButton(title: "", target: self, action: action)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.image = NSImage(
            systemSymbolName: systemName,
            accessibilityDescription: accessibilityLabel
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        button.imagePosition = .imageOnly
        button.contentTintColor = .labelColor
        button.toolTip = accessibilityLabel
        button.setAccessibilityLabel(accessibilityLabel)
        button.setButtonType(.momentaryPushIn)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.widthAnchor.constraint(equalToConstant: 32).isActive = true
        return button
    }

    private func makeDatePickerButton() -> NSButton {
        let button = NSButton(title: "", target: self, action: #selector(toggleDatePickerPopover))
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.font = NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        button.contentTintColor = .labelColor
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 78).isActive = true
        return button
    }

    private func updateDatePickerButtonTitle(_ title: String) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ]
        let attributedTitle = NSAttributedString(string: title, attributes: attributes)
        datePickerButton.attributedTitle = attributedTitle
        datePickerButton.attributedAlternateTitle = attributedTitle
    }

    private func makeDatePickerPopover() -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = HeatmapDatePickerPopoverViewController.contentSize
        popover.contentViewController = datePickerViewController
        return popover
    }

    func resetToTodayAndRefresh() {
        selectedDate = clampedDate(Calendar.current.startOfDay(for: Date()))
        refreshData()
    }

    func refreshData() {
        let statsManager = StatsManager.shared
        dateBounds = statsManager.keyboardHeatmapDateBounds()
        selectedDate = clampedDate(selectedDate)

        let dayData = statsManager.keyboardHeatmapDay(for: selectedDate)
        let visibleCounts = dayData.keyCounts.filter { KeyboardHeatmapView.supportedKeyIDs.contains($0.key) }

        keyboardHeatmapView.apply(keyCounts: visibleCounts)

        let totalFormatted = numberFormatter.string(from: NSNumber(value: dayData.totalKeyPresses)) ?? "\(dayData.totalKeyPresses)"
        let activeKeys = visibleCounts.values.filter { $0 > 0 }.count
        let activeFormatted = numberFormatter.string(from: NSNumber(value: activeKeys)) ?? "\(activeKeys)"
        summaryLabel.stringValue = String(format: NSLocalizedString("keyboardHeatmap.summary", comment: ""), totalFormatted, activeFormatted)

        let hasActivity = dayData.totalKeyPresses > 0
        updateDatePickerButtonTitle(displayDateString(for: selectedDate))
        emptyStateBadgeView.isHidden = hasActivity
        keyboardEmptyOverlayView.isHidden = hasActivity
        keyboardHeatmapView.alphaValue = 1
        updateDateNavigationState()
        syncDatePickerState()
    }

    private func displayDateString(for date: Date) -> String {
        let calendar = Calendar.current
        let preferredLocalization = Bundle.main.preferredLocalizations.first ?? ""
        let preferredLanguage = Locale.preferredLanguages.first ?? ""
        let selectedYear = calendar.component(.year, from: date)
        let currentYear = calendar.component(.year, from: Date())
        let month = calendar.component(.month, from: date)
        let day = calendar.component(.day, from: date)

        if preferredLocalization.hasPrefix("zh") || preferredLanguage.hasPrefix("zh") {
            if selectedYear == currentYear {
                return "\(month)月\(day)日"
            }
            return "\(selectedYear)年\(month)月\(day)日"
        }

        if selectedYear == currentYear {
            return dateFormatterWithoutYear.string(from: date)
        }
        return dateFormatterWithYear.string(from: date)
    }

    @objc private func showPreviousDay() {
        let calendar = Calendar.current
        guard let previous = calendar.date(byAdding: .day, value: -1, to: selectedDate) else { return }
        guard previous >= dateBounds.start else { return }
        transitionToDate(previous)
    }

    @objc private func showNextDay() {
        let calendar = Calendar.current
        guard let next = calendar.date(byAdding: .day, value: 1, to: selectedDate) else { return }
        guard next <= dateBounds.end else { return }
        transitionToDate(next)
    }

    @objc private func backToToday() {
        transitionToDate(Calendar.current.startOfDay(for: Date()))
    }

    @objc private func toggleDatePickerPopover() {
        if datePickerPopover.isShown {
            datePickerPopover.performClose(nil)
            return
        }

        syncDatePickerState()
        datePickerViewController.prepareForPresentation()
        datePickerPopover.contentSize = datePickerViewController.preferredContentSize
        datePickerPopover.show(relativeTo: datePickerButton.bounds, of: datePickerButton, preferredEdge: .maxY)
    }

    private func clampedDate(_ date: Date) -> Date {
        let normalized = Calendar.current.startOfDay(for: date)
        if normalized < dateBounds.start {
            return dateBounds.start
        }
        if normalized > dateBounds.end {
            return dateBounds.end
        }
        return normalized
    }

    private func updateDateNavigationState() {
        let today = Calendar.current.startOfDay(for: Date())
        previousDayButton.isEnabled = selectedDate > dateBounds.start
        nextDayButton.isEnabled = selectedDate < dateBounds.end
        backToTodayButton.isHidden = Calendar.current.isDate(selectedDate, inSameDayAs: today)
    }

    private func startLiveUpdates() {
        statsUpdateToken = StatsManager.shared.addStatsUpdateHandler { [weak self] in
            self?.scheduleRefresh()
        }
    }

    private func stopLiveUpdates() {
        if let token = statsUpdateToken {
            StatsManager.shared.removeStatsUpdateHandler(token)
        }
        statsUpdateToken = nil
        pendingRefresh = false
    }

    private func scheduleRefresh() {
        guard !pendingRefresh else { return }
        pendingRefresh = true
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.refreshData()
            self.pendingRefresh = false
        }
    }

    private func transitionToDate(_ date: Date) {
        let targetDate = Calendar.current.startOfDay(for: date)
        guard targetDate != selectedDate else { return }

        let direction: DaySlideDirection = targetDate < selectedDate ? .left : .right
        let previousSnapshot = makeHeatmapSnapshot()
        selectedDate = targetDate
        refreshData()
        animateDayTransition(direction: direction, previousSnapshot: previousSnapshot)
    }

    private func syncDatePickerState() {
        datePickerViewController.update(selectedDate: selectedDate, bounds: dateBounds)
    }

    private func handleDateSelection(_ date: Date) {
        let targetDate = clampedDate(date)
        datePickerPopover.performClose(nil)
        guard targetDate != selectedDate else { return }
        transitionToDate(targetDate)
    }

    private func makeHeatmapSnapshot() -> NSImageView? {
        guard heatmapContainer.bounds.width > 0, heatmapContainer.bounds.height > 0 else { return nil }
        heatmapContainer.layoutSubtreeIfNeeded()

        let bounds = heatmapContainer.bounds
        guard let bitmap = heatmapContainer.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        heatmapContainer.cacheDisplay(in: bounds, to: bitmap)

        let image = NSImage(size: bounds.size)
        image.addRepresentation(bitmap)

        let imageView = NSImageView(image: image)
        imageView.frame = bounds
        imageView.imageScaling = .scaleAxesIndependently
        imageView.autoresizingMask = [.width, .height]
        imageView.wantsLayer = true
        return imageView
    }

    private func animateDayTransition(direction: DaySlideDirection, previousSnapshot: NSImageView?) {
        guard !isDayTransitionAnimating else {
            previousSnapshot?.removeFromSuperview()
            return
        }
        guard let containerLayer = heatmapContainer.layer else {
            previousSnapshot?.removeFromSuperview()
            return
        }

        isDayTransitionAnimating = true
        let duration: CFTimeInterval = 0.16
        let slideDistance = max(260, heatmapContainer.bounds.width * 0.88)
        let timingFunction = CAMediaTimingFunction(name: .easeOut)

        if let previousSnapshot {
            heatmapContainer.addSubview(previousSnapshot, positioned: .above, relativeTo: nil)
        }

        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(timingFunction)
        CATransaction.setCompletionBlock { [weak self] in
            previousSnapshot?.removeFromSuperview()
            self?.isDayTransitionAnimating = false
        }

        if let previousLayer = previousSnapshot?.layer {
            let outgoingAnimation = CAAnimationGroup()
            outgoingAnimation.animations = [
                basicAnimation(keyPath: "transform.translation.x", from: 0, to: direction.outgoingOffset(distance: slideDistance)),
                basicAnimation(keyPath: "opacity", from: 1, to: 0)
            ]
            outgoingAnimation.duration = duration
            outgoingAnimation.timingFunction = timingFunction
            previousLayer.add(outgoingAnimation, forKey: "day-slide-out")
            previousLayer.opacity = 0
        }

        let incomingTargets: [NSView] = [keyboardHeatmapView, keyboardEmptyOverlayView, emptyStateBadgeView]
            .filter { !$0.isHidden }
        for view in incomingTargets {
            view.wantsLayer = true
            guard let layer = view.layer else { continue }
            let targetOpacity = max(0, min(1, view.alphaValue))
            layer.removeAnimation(forKey: "day-slide-in")
            let incomingAnimation = CAAnimationGroup()
            incomingAnimation.animations = [
                basicAnimation(keyPath: "transform.translation.x", from: direction.incomingOffset(distance: slideDistance), to: 0),
                basicAnimation(keyPath: "opacity", from: 0, to: targetOpacity)
            ]
            incomingAnimation.duration = duration
            incomingAnimation.timingFunction = timingFunction
            layer.add(incomingAnimation, forKey: "day-slide-in")
        }

        containerLayer.layoutIfNeeded()
        CATransaction.commit()
    }

    private func basicAnimation(keyPath: String, from: CGFloat, to: CGFloat) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        return animation
    }

    private func updateAppearance() {
        view.layer?.backgroundColor = resolvedCGColor(NSColor.windowBackgroundColor, for: view)
        view.window?.backgroundColor = resolvedColor(NSColor.windowBackgroundColor, for: view)
        heatmapContainer.layer?.backgroundColor = resolvedCGColor(NSColor.controlBackgroundColor, alpha: 0.92, for: view)
        heatmapContainer.layer?.borderColor = resolvedCGColor(NSColor.separatorColor, alpha: 0.18, for: view)
        applyCardShadow(heatmapContainer.layer, for: view)
        keyboardEmptyOverlayView.layer?.backgroundColor = resolvedCGColor(NSColor.windowBackgroundColor, alpha: 0.62, for: view)
        keyboardEmptyOverlayView.layer?.borderWidth = 0.5
        keyboardEmptyOverlayView.layer?.borderColor = resolvedCGColor(NSColor.separatorColor, alpha: 0.22, for: view)
        emptyStateBadgeView.updateAppearance(for: view)
        keyboardHeatmapView.needsDisplay = true
    }
}

private final class EmptyStateBadgeView: NSVisualEffectView {
    private let iconView: NSImageView
    private let messageLabel: NSTextField
    private let borderLayer = CAShapeLayer()

    init(text: String) {
        let iconImage = NSImage(
            systemSymbolName: "keyboard",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
        iconView = NSImageView(image: iconImage ?? NSImage())
        iconView.imageScaling = .scaleProportionallyDown
        iconView.contentTintColor = .secondaryLabelColor
        iconView.translatesAutoresizingMaskIntoConstraints = false

        messageLabel = NSTextField(labelWithString: text)
        messageLabel.font = NSFont.systemFont(ofSize: 17, weight: .semibold)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.alignment = .center
        messageLabel.translatesAutoresizingMaskIntoConstraints = false

        super.init(frame: .zero)
        material = .menu
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true
        borderLayer.fillColor = NSColor.clear.cgColor
        borderLayer.lineWidth = 1
        layer?.addSublayer(borderLayer)
        translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [iconView, messageLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        borderLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        borderLayer.frame = bounds
        let inset = borderLayer.lineWidth / 2
        let corner = max(0, 14 - inset)
        borderLayer.path = CGPath(
            roundedRect: bounds.insetBy(dx: inset, dy: inset),
            cornerWidth: corner,
            cornerHeight: corner,
            transform: nil
        )
    }

    func updateAppearance(for hostView: NSView) {
        let isDarkMode = hostView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let surfaceColor = isDarkMode ? NSColor.windowBackgroundColor : NSColor.controlBackgroundColor
        let neutralColor = surfaceColor.blended(withFraction: isDarkMode ? 0.22 : 0.10, of: .separatorColor)
            ?? (isDarkMode
                ? NSColor(calibratedRed: 0.20, green: 0.22, blue: 0.25, alpha: 1)
                : NSColor(calibratedRed: 0.93, green: 0.94, blue: 0.96, alpha: 1))
        let accentColor = NSColor.controlAccentColor
        let accentBase = neutralColor.blended(withFraction: isDarkMode ? 0.34 : 0.24, of: accentColor) ?? accentColor

        let backgroundColor = neutralColor.blended(withFraction: isDarkMode ? 0.56 : 0.46, of: accentBase) ?? accentBase
        let borderColor = accentBase.blended(withFraction: isDarkMode ? 0.42 : 0.30, of: accentColor) ?? accentColor
        let textColor: NSColor = isDarkMode
            ? NSColor.white.withAlphaComponent(0.96)
            : NSColor.black

        layer?.backgroundColor = resolvedCGColor(backgroundColor, for: hostView)
        borderLayer.strokeColor = resolvedCGColor(borderColor, for: hostView)
        layer?.shadowOpacity = 0
        iconView.contentTintColor = textColor
        messageLabel.textColor = textColor
    }
}

private final class HeatmapDatePickerPopoverViewController: NSViewController {
    private static let contentInset = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
    static let contentSize = NSSize(width: 220, height: 200)

    var onDateSelected: ((Date) -> Void)?
    private var didConfigureConstraints = false

    private lazy var datePicker: NSDatePicker = {
        let picker = NSDatePicker()
        picker.translatesAutoresizingMaskIntoConstraints = false
        picker.datePickerStyle = .clockAndCalendar
        picker.datePickerElements = .yearMonthDay
        picker.datePickerMode = .single
        picker.focusRingType = .none
        picker.drawsBackground = false
        picker.backgroundColor = .clear
        picker.isBordered = false
        picker.isBezeled = false
        picker.target = self
        picker.action = #selector(datePicked(_:))
        return picker
    }()

    override func loadView() {
        view = NSView(frame: .zero)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor

        view.addSubview(datePicker)
        configureConstraintsIfNeeded()
    }

    func update(selectedDate: Date, bounds: (start: Date, end: Date)) {
        datePicker.minDate = bounds.start
        datePicker.maxDate = bounds.end
        datePicker.dateValue = selectedDate
    }

    func prepareForPresentation() {
        _ = view
        configureConstraintsIfNeeded()
        view.layoutSubtreeIfNeeded()
        preferredContentSize = view.fittingSize
    }

    @objc private func datePicked(_ sender: NSDatePicker) {
        onDateSelected?(Calendar.current.startOfDay(for: sender.dateValue))
    }

    private func configureConstraintsIfNeeded() {
        guard !didConfigureConstraints else { return }
        didConfigureConstraints = true

        NSLayoutConstraint.activate([
            datePicker.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            datePicker.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            datePicker.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: Self.contentInset.left),
            view.trailingAnchor.constraint(greaterThanOrEqualTo: datePicker.trailingAnchor, constant: Self.contentInset.right),
            datePicker.topAnchor.constraint(greaterThanOrEqualTo: view.topAnchor, constant: Self.contentInset.top),
            view.bottomAnchor.constraint(greaterThanOrEqualTo: datePicker.bottomAnchor, constant: Self.contentInset.bottom)
        ])
    }
}

private final class KeyboardHeatmapView: NSView {
    private struct RenderMetrics {
        let scale: CGFloat
        let origin: CGPoint
        let layoutBounds: CGRect
    }

    struct KeySpec {
        let id: String
        let label: String
        let frameUnits: CGRect
        let symbolName: String?
        let fallbackCountIDs: [String]
    }

    static let supportedKeyIDs: Set<String> = Set(layout.flatMap { [$0.id] + $0.fallbackCountIDs })
    private static let numberKeyIDs: Set<String> = Set((0...9).map(String.init))
    private static let layoutContentInset: CGFloat = 8
    private static let maximumKeyboardScale: CGFloat = 58

    private static let layout: [KeySpec] = {
        let keyGap: CGFloat = 0.15
        let rowGap: CGFloat = keyGap
        let rowStep: CGFloat = 1.0 + rowGap
        let functionClusterGap: CGFloat = keyGap
        let deleteWidth: CGFloat = 2.38 - keyGap
        let backslashWidth: CGFloat = 1.93 - keyGap
        let rightShiftWidth: CGFloat = 2.93 + keyGap

        var items: [KeySpec] = []

        func appendRow(y: CGFloat, startX: CGFloat, keys: [(id: String, label: String, width: CGFloat, symbolName: String?, fallbackCountIDs: [String])]) {
            var x = startX
            for key in keys {
                items.append(KeySpec(
                    id: key.id,
                    label: key.label,
                    frameUnits: CGRect(x: x, y: y, width: key.width, height: 1.0),
                    symbolName: key.symbolName,
                    fallbackCountIDs: key.fallbackCountIDs
                ))
                x += key.width + keyGap
            }
        }

        let functionKeys = ["F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12"]
        let numberRowWidths: [CGFloat] = Array(repeating: 1.0, count: 13) + [deleteWidth]
        let keyboardRightEdge = numberRowWidths.reduce(0, +) + CGFloat(numberRowWidths.count - 1) * keyGap

        let yFunction: CGFloat = 0
        var x: CGFloat = 0
        let escWidth: CGFloat = 1.45
        let functionGapTotal = functionClusterGap + CGFloat(functionKeys.count - 1) * keyGap
        let functionKeyWidth = (keyboardRightEdge - escWidth - functionGapTotal) / CGFloat(functionKeys.count)

        items.append(KeySpec(id: "Esc", label: "esc", frameUnits: CGRect(x: x, y: yFunction, width: escWidth, height: 1.0), symbolName: nil, fallbackCountIDs: []))
        x += escWidth + functionClusterGap
        for key in functionKeys {
            items.append(KeySpec(
                id: key,
                label: key,
                frameUnits: CGRect(x: x, y: yFunction, width: functionKeyWidth, height: 1.0),
                symbolName: nil,
                fallbackCountIDs: []
            ))
            x += functionKeyWidth + keyGap
        }
        let y1 = rowStep
        appendRow(y: y1, startX: 0, keys: [
            ("`", "~\n`", 1.0, nil, []), ("1", "!\n1", 1.0, nil, []), ("2", "@\n2", 1.0, nil, []), ("3", "#\n3", 1.0, nil, []), ("4", "$\n4", 1.0, nil, []),
            ("5", "%\n5", 1.0, nil, []), ("6", "^\n6", 1.0, nil, []), ("7", "&\n7", 1.0, nil, []), ("8", "*\n8", 1.0, nil, []), ("9", "(\n9", 1.0, nil, []),
            ("0", ")\n0", 1.0, nil, []), ("-", "_\n-", 1.0, nil, []), ("=", "+\n=", 1.0, nil, []), ("Delete", "delete", deleteWidth, nil, [])
        ])

        let y2 = y1 + rowStep
        appendRow(y: y2, startX: 0, keys: [
            ("Tab", "tab", 1.45, nil, []), ("Q", "Q", 1.0, nil, []), ("W", "W", 1.0, nil, []), ("E", "E", 1.0, nil, []), ("R", "R", 1.0, nil, []),
            ("T", "T", 1.0, nil, []), ("Y", "Y", 1.0, nil, []), ("U", "U", 1.0, nil, []), ("I", "I", 1.0, nil, []), ("O", "O", 1.0, nil, []),
            ("P", "P", 1.0, nil, []), ("[", "{\n[", 1.0, nil, []), ("]", "}\n]", 1.0, nil, []), ("\\", "|\n\\", backslashWidth, nil, [])
        ])

        let y3 = y2 + rowStep
        appendRow(y: y3, startX: 0, keys: [
            ("CapsLock", "caps lock", 1.8, nil, []), ("A", "A", 1.0, nil, []), ("S", "S", 1.0, nil, []), ("D", "D", 1.0, nil, []), ("F", "F", 1.0, nil, []),
            ("G", "G", 1.0, nil, []), ("H", "H", 1.0, nil, []), ("J", "J", 1.0, nil, []), ("K", "K", 1.0, nil, []), ("L", "L", 1.0, nil, []),
            (";", ":\n;", 1.0, nil, []), ("'", "\"\n'", 1.0, nil, []), ("Return", "return", 2.58, nil, [])
        ])

        let y4 = y3 + rowStep
        appendRow(y: y4, startX: 0, keys: [
            ("LeftShift", "", 2.45, "shift", ["Shift"]), ("Z", "Z", 1.0, nil, []), ("X", "X", 1.0, nil, []), ("C", "C", 1.0, nil, []), ("V", "V", 1.0, nil, []),
            ("B", "B", 1.0, nil, []), ("N", "N", 1.0, nil, []), ("M", "M", 1.0, nil, []), (",", "<\n,", 1.0, nil, []), (".", ">\n.", 1.0, nil, []),
            ("/", "?\n/", 1.0, nil, []), ("RightShift", "", rightShiftWidth, "shift", [])
        ])

        let y5 = y4 + rowStep
        var bottomX: CGFloat = 0
        let bottomKeys: [(id: String, label: String, width: CGFloat, symbolName: String?, fallbackCountIDs: [String])] = [
            ("Fn", "", 1.0, "globe", []),
            ("Ctrl", "", 1.1, "control", []),
            ("LeftOption", "", 1.1, "option", ["Option"]),
            ("LeftCmd", "", 1.3, "command", ["Cmd"]),
            ("Space", "", 6.0, nil, []),
            ("RightCmd", "", 1.3, "command", []),
            ("RightOption", "", 1.1, "option", [])
        ]
        for key in bottomKeys {
            items.append(KeySpec(
                id: key.id,
                label: key.label,
                frameUnits: CGRect(x: bottomX, y: y5, width: key.width, height: 1.0),
                symbolName: key.symbolName,
                fallbackCountIDs: key.fallbackCountIDs
            ))
            bottomX += key.width + keyGap
        }

        let arrowWidth: CGFloat = 1.0
        let arrowStep = arrowWidth + keyGap
        let arrowClusterWidth = arrowStep * 2 + arrowWidth
        let arrowStartX = keyboardRightEdge - arrowClusterWidth
        let verticalGap: CGFloat = 0.04
        let halfArrowHeight = (1.0 - verticalGap) / 2.0
        items.append(KeySpec(id: "Left", label: "◀", frameUnits: CGRect(x: arrowStartX, y: y5, width: arrowWidth, height: 1.0), symbolName: nil, fallbackCountIDs: []))
        items.append(KeySpec(id: "Up", label: "▲", frameUnits: CGRect(x: arrowStartX + arrowStep, y: y5, width: arrowWidth, height: halfArrowHeight), symbolName: nil, fallbackCountIDs: []))
        items.append(KeySpec(id: "Down", label: "▼", frameUnits: CGRect(x: arrowStartX + arrowStep, y: y5 + halfArrowHeight + verticalGap, width: arrowWidth, height: halfArrowHeight), symbolName: nil, fallbackCountIDs: []))
        items.append(KeySpec(id: "Right", label: "▶", frameUnits: CGRect(x: arrowStartX + arrowStep * 2, y: y5, width: arrowWidth, height: 1.0), symbolName: nil, fallbackCountIDs: []))

        return items
    }()

    private var keyCounts: [String: Int] = [:]
    private var maxCount: Int = 0

    private lazy var toolTipCountFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    override var isFlipped: Bool {
        true
    }

    func apply(keyCounts: [String: Int]) {
        self.keyCounts = keyCounts
        self.maxCount = keyCounts.values.max() ?? 0
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let metrics = renderMetrics() else { return }

        let isDarkMode = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let labelColor: NSColor = isDarkMode ? .white : .labelColor
        for key in Self.layout {
            let frame = keyFrame(for: key, metrics: metrics)

            let count = count(for: key)
            let fillColor = color(for: count, isDarkMode: isDarkMode)

            let keyPath = NSBezierPath(roundedRect: frame, xRadius: max(4, metrics.scale * 0.14), yRadius: max(4, metrics.scale * 0.14))
            fillColor.setFill()
            keyPath.fill()

            let borderColor = isDarkMode ? NSColor.white.withAlphaComponent(0.14) : NSColor.black.withAlphaComponent(0.09)
            borderColor.setStroke()
            keyPath.lineWidth = 0.8
            keyPath.stroke()

            drawKeyLegend(
                for: key,
                in: frame,
                scale: metrics.scale,
                textColor: labelColor
            )
            drawCountBadge(for: count, in: frame, scale: metrics.scale, isDarkMode: isDarkMode)
        }
    }

    private static func layoutBounds() -> CGRect {
        Self.layout.reduce(into: CGRect.null) { partialResult, key in
            partialResult = partialResult.union(key.frameUnits)
        }
    }

    private func renderMetrics() -> RenderMetrics? {
        guard !Self.layout.isEmpty else { return nil }

        let availableBounds = bounds.insetBy(dx: Self.layoutContentInset, dy: Self.layoutContentInset)
        guard availableBounds.width > 0, availableBounds.height > 0 else { return nil }

        let layoutBounds = Self.layoutBounds()
        let scaleX = availableBounds.width / layoutBounds.width
        let scaleY = availableBounds.height / layoutBounds.height
        let scale = min(scaleX, scaleY, Self.maximumKeyboardScale)
        let actualSize = CGSize(width: layoutBounds.width * scale, height: layoutBounds.height * scale)
        let origin = CGPoint(
            x: availableBounds.midX - actualSize.width / 2 - layoutBounds.minX * scale,
            y: availableBounds.midY - actualSize.height / 2 - layoutBounds.minY * scale
        )
        return RenderMetrics(scale: scale, origin: origin, layoutBounds: layoutBounds)
    }

    private func keyFrame(for key: KeySpec, metrics: RenderMetrics) -> CGRect {
        CGRect(
            x: metrics.origin.x + key.frameUnits.minX * metrics.scale,
            y: metrics.origin.y + key.frameUnits.minY * metrics.scale,
            width: key.frameUnits.width * metrics.scale,
            height: key.frameUnits.height * metrics.scale
        )
    }

    private func drawKeyLegend(for key: KeySpec, in frame: CGRect, scale: CGFloat, textColor: NSColor) {
        if let symbolName = key.symbolName {
            drawSymbolLegend(for: key, symbolName: symbolName, in: frame, scale: scale, textColor: textColor)
            return
        }

        guard !key.label.isEmpty else { return }

        if key.label.contains("\n") {
            drawDualLineLegend(for: key, in: frame, scale: scale, textColor: textColor)
            return
        }

        let font = NSFont.systemFont(ofSize: max(9, min(13, scale * 0.28)), weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor
        ]
        let size = key.label.size(withAttributes: attributes)

        let horizontalInset = max(4, scale * 0.16)
        let verticalInset = max(3, scale * 0.14)
        let point = CGPoint(
            x: frame.maxX - size.width - horizontalInset,
            y: frame.maxY - size.height - verticalInset
        )

        key.label.draw(at: point, withAttributes: attributes)
    }

    private func drawSymbolLegend(for key: KeySpec, symbolName: String, in frame: CGRect, scale: CGFloat, textColor: NSColor) {
        let symbolPointSize = max(10, min(15, scale * 0.30))
        let symbolWeight: NSFont.Weight = key.id.contains("Shift") ? .semibold : .medium
        let horizontalInset = max(4, scale * 0.14)
        let bottomInset = max(3, scale * 0.12)
        let symbolRect = CGRect(
            x: frame.maxX - symbolPointSize * 1.04 - horizontalInset,
            y: frame.maxY - symbolPointSize * 1.04 - bottomInset,
            width: symbolPointSize * 1.04,
            height: symbolPointSize * 1.04
        )

        if let symbolImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: symbolPointSize, weight: symbolWeight)) {
            symbolImage.draw(in: symbolRect)
        }

        guard !key.label.isEmpty else { return }

        let labelFont = NSFont.systemFont(ofSize: max(7.5, min(9.5, scale * 0.19)), weight: .medium)
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: textColor.withAlphaComponent(0.86)
        ]
        let labelSize = key.label.size(withAttributes: labelAttributes)
        let labelBottomGap = max(2, scale * 0.08)
        let labelPoint = CGPoint(
            x: frame.maxX - labelSize.width - horizontalInset,
            y: max(frame.minY + 2, symbolRect.minY - labelSize.height - labelBottomGap)
        )
        key.label.draw(at: labelPoint, withAttributes: labelAttributes)
    }

    private func drawDualLineLegend(for key: KeySpec, in frame: CGRect, scale: CGFloat, textColor: NSColor) {
        let components = key.label
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .map(String.init)
        guard components.count == 2 else { return }

        let upper = components[0]
        let lower = components[1]

        let upperFont = NSFont.systemFont(ofSize: max(8, min(11, scale * 0.23)), weight: .regular)
        let lowerFont = NSFont.systemFont(ofSize: max(9.5, min(13, scale * 0.28)), weight: .medium)
        let upperAttributes: [NSAttributedString.Key: Any] = [
            .font: upperFont,
            .foregroundColor: textColor.withAlphaComponent(0.84)
        ]
        let lowerAttributes: [NSAttributedString.Key: Any] = [
            .font: lowerFont,
            .foregroundColor: textColor
        ]

        let upperSize = upper.size(withAttributes: upperAttributes)
        let lowerSize = lower.size(withAttributes: lowerAttributes)
        let horizontalInset = max(4, scale * 0.16)
        let bottomInset = max(2.5, scale * 0.11)
        let lineSpacing = max(1.5, scale * 0.05)

        let lowerPoint = CGPoint(
            x: frame.maxX - lowerSize.width - horizontalInset,
            y: frame.maxY - lowerSize.height - bottomInset
        )

        if Self.numberKeyIDs.contains(key.id) {
            lower.draw(at: lowerPoint, withAttributes: lowerAttributes)
            return
        }

        let upperPoint = CGPoint(
            x: frame.maxX - upperSize.width - horizontalInset,
            y: max(frame.minY + 2, lowerPoint.y - upperSize.height - lineSpacing)
        )

        upper.draw(at: upperPoint, withAttributes: upperAttributes)
        lower.draw(at: lowerPoint, withAttributes: lowerAttributes)
    }

    private func count(for key: KeySpec) -> Int {
        if let direct = keyCounts[key.id] {
            return direct
        }

        for fallbackID in key.fallbackCountIDs {
            if let fallbackCount = keyCounts[fallbackID] {
                return fallbackCount
            }
        }

        return 0
    }

    private func drawCountBadge(for count: Int, in frame: CGRect, scale: CGFloat, isDarkMode: Bool) {
        guard count > 0 else { return }

        let inset = max(3, scale * 0.08)
        let horizontalPadding = max(4, scale * 0.10)
        let verticalPadding = max(1.5, scale * 0.05)
        let maxBadgeWidth = max(14, frame.width - inset * 2)
        guard maxBadgeWidth > 10 else { return }

        let font = NSFont.monospacedDigitSystemFont(ofSize: max(7, min(10.5, scale * 0.20)), weight: .semibold)
        let textColor = isDarkMode
            ? NSColor.white.withAlphaComponent(0.95)
            : NSColor(calibratedWhite: 0.12, alpha: 0.95)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor
        ]

        var text = toolTipCountFormatter.string(from: NSNumber(value: count)) ?? "\(count)"
        let fullTextWidth = text.size(withAttributes: attributes).width + horizontalPadding * 2
        if fullTextWidth > maxBadgeWidth {
            text = compactCountText(for: count)
        }

        var textSize = text.size(withAttributes: attributes)
        let badgeHeight = max(max(12, scale * 0.30), textSize.height + verticalPadding * 2)
        var badgeWidth = max(badgeHeight, textSize.width + horizontalPadding * 2)
        if badgeWidth > maxBadgeWidth {
            badgeWidth = maxBadgeWidth
            text = compactCountText(for: count, maximumLength: 3)
            textSize = text.size(withAttributes: attributes)
        }

        let badgeRect = CGRect(
            x: frame.minX + inset,
            y: frame.minY + inset,
            width: badgeWidth,
            height: badgeHeight
        )

        let badgePath = NSBezierPath(
            roundedRect: badgeRect,
            xRadius: badgeHeight * 0.5,
            yRadius: badgeHeight * 0.5
        )
        let backgroundColor = isDarkMode
            ? NSColor.black.withAlphaComponent(0.38)
            : NSColor.white.withAlphaComponent(0.84)
        backgroundColor.setFill()
        badgePath.fill()

        let borderColor = isDarkMode
            ? NSColor.white.withAlphaComponent(0.22)
            : NSColor.black.withAlphaComponent(0.14)
        borderColor.setStroke()
        badgePath.lineWidth = 0.7
        badgePath.stroke()

        let textPoint = CGPoint(
            x: badgeRect.minX + (badgeRect.width - textSize.width) / 2,
            y: badgeRect.minY + (badgeRect.height - textSize.height) / 2 + font.descender * 0.45
        )
        text.draw(at: textPoint, withAttributes: attributes)
    }

    private func compactCountText(for count: Int, maximumLength: Int = 4) -> String {
        let compact: String
        if count >= 1_000_000_000 {
            compact = compactUnit(Double(count) / 1_000_000_000, suffix: "B")
        } else if count >= 1_000_000 {
            compact = compactUnit(Double(count) / 1_000_000, suffix: "M")
        } else if count >= 1_000 {
            compact = compactUnit(Double(count) / 1_000, suffix: "K")
        } else {
            compact = "\(count)"
        }

        if compact.count <= maximumLength {
            return compact
        }

        if count >= 1_000_000_000 {
            return "\(Int(round(Double(count) / 1_000_000_000)))B"
        }
        if count >= 1_000_000 {
            return "\(Int(round(Double(count) / 1_000_000)))M"
        }
        if count >= 1_000 {
            return "\(Int(round(Double(count) / 1_000)))K"
        }
        return compact
    }

    private func compactUnit(_ value: Double, suffix: String) -> String {
        let rounded = (value * 10).rounded() / 10
        let numberText: String
        if abs(rounded.rounded() - rounded) < 0.05 {
            numberText = "\(Int(rounded.rounded()))"
        } else {
            numberText = String(format: "%.1f", rounded)
        }
        return "\(numberText)\(suffix)"
    }

    private func color(for count: Int, isDarkMode: Bool) -> NSColor {
        let surfaceColor = isDarkMode ? NSColor.windowBackgroundColor : NSColor.controlBackgroundColor
        let neutralColor = surfaceColor.blended(withFraction: isDarkMode ? 0.22 : 0.10, of: .separatorColor)
            ?? (isDarkMode
                ? NSColor(calibratedRed: 0.20, green: 0.22, blue: 0.25, alpha: 1)
                : NSColor(calibratedRed: 0.93, green: 0.94, blue: 0.96, alpha: 1))

        if count <= 0 {
            return neutralColor
        }

        let normalized = maxCount > 0
            ? CGFloat(log(Double(count) + 1) / log(Double(maxCount) + 1))
            : 0
        let eased = pow(normalized, 0.82)

        let accentColor = NSColor.controlAccentColor
        let lowColor = neutralColor.blended(withFraction: isDarkMode ? 0.34 : 0.24, of: accentColor)
            ?? blendColor(from: neutralColor, to: accentColor, t: isDarkMode ? 0.34 : 0.24)
        let highColor = accentColor.blended(withFraction: isDarkMode ? 0.18 : 0.10, of: isDarkMode ? .white : .black)
            ?? blendColor(from: accentColor, to: isDarkMode ? .white : .black, t: isDarkMode ? 0.18 : 0.10)

        return blendColor(from: lowColor, to: highColor, t: eased)
    }

    private func blendColor(from: NSColor, to: NSColor, t: CGFloat) -> NSColor {
        let progress = max(0, min(1, t))
        let fromRGB = from.usingColorSpace(.deviceRGB) ?? from
        let toRGB = to.usingColorSpace(.deviceRGB) ?? to

        let red = fromRGB.redComponent + (toRGB.redComponent - fromRGB.redComponent) * progress
        let green = fromRGB.greenComponent + (toRGB.greenComponent - fromRGB.greenComponent) * progress
        let blue = fromRGB.blueComponent + (toRGB.blueComponent - fromRGB.blueComponent) * progress
        let alpha = fromRGB.alphaComponent + (toRGB.alphaComponent - fromRGB.alphaComponent) * progress

        return NSColor(calibratedRed: red, green: green, blue: blue, alpha: alpha)
    }
}
