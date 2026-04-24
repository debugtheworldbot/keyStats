import Cocoa
import SwiftUI

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

/// 统计详情弹出视图控制器
class StatsPopoverViewController: NSViewController {
    var preferredSizeDidChange: ((NSSize) -> Void)?

    private let updatePermissionNoticeSuppressedKey = "update.permissionNoticeSuppressed"
    private let popoverContentWidth: CGFloat = 360
    private let keyBreakdownGridHeight: CGFloat = 124
    private let chartHeight: CGFloat = 140
    
    // MARK: - UI 组件
    private var containerView: NSView!
    private var titleLabel: NSTextField!
    private var statsStackView: NSStackView!
    private var keyBreakdownTitleLabel: NSTextField!
    private var keyBreakdownGridStack: NSStackView!
    private var keyBreakdownColumns: [NSStackView] = []
    private var keyBreakdownSeparators: [NSView] = []
    private var keyBreakdownRowCache: [String: KeyCountRowView] = [:]
    private var keyBreakdownDisplayedKeys: [String] = []
    private var historyTitleLabel: NSTextField!
    private var rangeControl: NSSegmentedControl!
    private var metricControl: NSSegmentedControl!
    private var chartStyleControl: NSSegmentedControl!
    private var chartView: StatsChartView!
    private var historySummaryLabel: NSTextField!
    private var settingsButton: NSButton!
    private var appStatsButton: NSButton!
    private var allTimeStatsButton: NSButton!
    private var keyboardHeatmapButton: NSButton!
    private var pendingStatsRefresh = false
    private var statsUpdateToken: UUID?
    private var updateAvailabilityToken: UUID?
    private var appearanceObservation: NSKeyValueObservation?
    
    // 统计项视图
    private var keyPressView: StatItemView!
    private var kpsBadge: KPSBadgeView!

    private var kpsRefreshTimer: Timer?
    private var kpsPopover: NSPopover?
    private var leftClickView: StatItemView!
    private var rightClickView: StatItemView!
    private var sideBackClickView: StatItemView!
    private var sideForwardClickView: StatItemView!
    private var sideClickRow: NSStackView!
    private var mouseDistanceView: StatItemView!
    private var scrollDistanceView: StatItemView!

    
    // 底部按钮
    private var quitButton: NSButton!
    private var checkUpdatesButton: NSButton!
    private var permissionButton: NSButton!
    private var lastRangeSegment = 0
    private var lastMetricSegment = 0
    private var lastChartStyleSegment = 0
    
    // MARK: - 生命周期
    
    override func loadView() {
        // 创建主视图
        let mainView = AppearanceTrackingView(frame: NSRect(x: 0, y: 0, width: 360, height: 640))
        mainView.onEffectiveAppearanceChange = { [weak self] in
            self?.updateAppearance()
        }
        mainView.wantsLayer = true
        self.view = mainView
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        updateStats()
        updateAppearance()
        updatePreferredPopoverSizeIfNeeded()
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.updateAppearance()
            }
        }
        HelperXPCClient.shared.addStateObserver { [weak self] _ in
            DispatchQueue.main.async {
                self?.updatePermissionButtonVisibility()
            }
        }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        updateStats()
        startLiveUpdates()
        startUpdateAvailabilityUpdates()
        startKPSRefreshTimer()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        focusPrimaryControl()
        updateAppearance()
        updatePreferredPopoverSizeIfNeeded()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        stopLiveUpdates()
        stopUpdateAvailabilityUpdates()
        stopKPSRefreshTimer()
        closeKPSPopover()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updatePreferredPopoverSizeIfNeeded()
    }
    
    deinit {
        stopLiveUpdates()
        stopUpdateAvailabilityUpdates()
        appearanceObservation = nil
    }
    
    // MARK: - UI 设置
    
    private func setupUI() {
        containerView = NSView()
        containerView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(containerView)

        NSLayoutConstraint.activate([
            containerView.topAnchor.constraint(equalTo: view.topAnchor),
            containerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            containerView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        // 标题
        titleLabel = createLabel(text: "KeyStats", fontSize: 14, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(titleLabel)

        // KPS 徽章（放在标题右侧，单行显示 KPS|CPS）
        kpsBadge = KPSBadgeView()
        kpsBadge.onTap = { [weak self] in self?.toggleKPSPopover() }
        kpsBadge.translatesAutoresizingMaskIntoConstraints = false
        updateKPSBadge()
        containerView.addSubview(kpsBadge)

        permissionButton = NSButton(title: NSLocalizedString("button.permission", comment: ""), target: self, action: #selector(requestPermission))
        permissionButton.bezelStyle = .rounded
        permissionButton.controlSize = .regular
        permissionButton.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(permissionButton)
        
        // 统计项
        keyPressView = StatItemView(icon: "⌨️", title: NSLocalizedString("stats.keyPresses", comment: ""), value: "0")

        leftClickView = StatItemView(icon: "🖱️", title: NSLocalizedString("stats.leftClicks", comment: ""), value: "0")
        rightClickView = StatItemView(icon: "🖱️", title: NSLocalizedString("stats.rightClicks", comment: ""), value: "0")
        sideBackClickView = StatItemView(icon: "🖱️", title: NSLocalizedString("stats.sideBackClicks", comment: ""), value: "0")
        sideForwardClickView = StatItemView(icon: "🖱️", title: NSLocalizedString("stats.sideForwardClicks", comment: ""), value: "0")
        mouseDistanceView = StatItemView(icon: "↔️", title: NSLocalizedString("stats.mouseDistance", comment: ""), value: "0 px")
        scrollDistanceView = StatItemView(icon: "↕️", title: NSLocalizedString("stats.scrollDistance", comment: ""), value: "0 px")
        
        let clickRow = NSStackView(views: [leftClickView, rightClickView])
        clickRow.orientation = .horizontal
        clickRow.spacing = 16
        clickRow.distribution = .fillEqually
        clickRow.alignment = .centerY
        clickRow.setContentHuggingPriority(.required, for: .vertical)
        clickRow.setContentCompressionResistancePriority(.required, for: .vertical)
        clickRow.translatesAutoresizingMaskIntoConstraints = false
        clickRow.heightAnchor.constraint(equalTo: leftClickView.heightAnchor).isActive = true

        sideClickRow = NSStackView(views: [sideBackClickView, sideForwardClickView])
        sideClickRow.orientation = .horizontal
        sideClickRow.spacing = 16
        sideClickRow.distribution = .fillEqually
        sideClickRow.alignment = .centerY
        sideClickRow.setContentHuggingPriority(.required, for: .vertical)
        sideClickRow.setContentCompressionResistancePriority(.required, for: .vertical)
        sideClickRow.translatesAutoresizingMaskIntoConstraints = false
        sideClickRow.heightAnchor.constraint(equalTo: sideBackClickView.heightAnchor).isActive = true

        let isChinese = Locale.current.language.languageCode?.identifier == "zh"

        if isChinese {
            // 中文环境：鼠标移动和滚动距离并排显示
            let distanceRow = NSStackView(views: [mouseDistanceView, scrollDistanceView])
            distanceRow.orientation = .horizontal
            distanceRow.spacing = 16
            distanceRow.distribution = .fillEqually
            distanceRow.alignment = .centerY
            distanceRow.setContentHuggingPriority(.required, for: .vertical)
            distanceRow.setContentCompressionResistancePriority(.required, for: .vertical)
            distanceRow.translatesAutoresizingMaskIntoConstraints = false
            distanceRow.heightAnchor.constraint(equalTo: mouseDistanceView.heightAnchor).isActive = true

            statsStackView = NSStackView(views: [
                keyPressView,
                clickRow,
                sideClickRow,
                distanceRow
            ])
        } else {
            // 英文环境：鼠标移动和滚动距离分行显示
            statsStackView = NSStackView(views: [
                keyPressView,
                clickRow,
                sideClickRow,
                mouseDistanceView,
                scrollDistanceView
            ])
        }
        statsStackView.orientation = .vertical
        statsStackView.distribution = .fill
        statsStackView.spacing = 8
        statsStackView.detachesHiddenViews = true
        statsStackView.setContentHuggingPriority(.required, for: .vertical)
        statsStackView.setContentCompressionResistancePriority(.required, for: .vertical)
        statsStackView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(statsStackView)
        
        // 键位统计标题
        keyBreakdownTitleLabel = createLabel(text: NSLocalizedString("section.keyBreakdown", comment: ""), fontSize: 14, weight: .semibold)
        keyBreakdownTitleLabel.translatesAutoresizingMaskIntoConstraints = false

        let heatmapEntryTitle = isChinese ? "热力图" : "Heatmap"
        let heatmapTooltipTitle = isChinese ? "键盘热力图" : "Keyboard Heatmap"
        keyboardHeatmapButton = NSButton(title: heatmapEntryTitle, target: self, action: #selector(showKeyboardHeatmap))
        keyboardHeatmapButton.bezelStyle = .rounded
        keyboardHeatmapButton.controlSize = .small
        keyboardHeatmapButton.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        keyboardHeatmapButton.toolTip = heatmapTooltipTitle
        keyboardHeatmapButton.setAccessibilityLabel(heatmapTooltipTitle)
        keyboardHeatmapButton.translatesAutoresizingMaskIntoConstraints = false
        keyboardHeatmapButton.setContentHuggingPriority(.required, for: .horizontal)
        keyboardHeatmapButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        containerView.addSubview(keyBreakdownTitleLabel)
        containerView.addSubview(keyboardHeatmapButton)

        // 键位统计列表（最多 3 列，每列 5 个）
        keyBreakdownGridStack = NSStackView()
        keyBreakdownGridStack.orientation = .horizontal
        keyBreakdownGridStack.spacing = 10
        keyBreakdownGridStack.distribution = .fill
        keyBreakdownGridStack.alignment = .top
        keyBreakdownGridStack.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(keyBreakdownGridStack)

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
        containerView.addSubview(historyTitleLabel)
        
        // 时间范围
        rangeControl = NSSegmentedControl(labels: [
            NSLocalizedString("history.range.week", comment: ""),
            NSLocalizedString("history.range.month", comment: "")
        ],
                                          trackingMode: .selectOne,
                                          target: self,
                                          action: #selector(historyControlsChanged))
        rangeControl.selectedSegment = 0
        rangeControl.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(rangeControl)
        
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
        containerView.addSubview(metricControl)
        
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
        containerView.addSubview(chartStyleControl)
        
        // 图表视图
        chartView = StatsChartView()
        chartView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(chartView)
        lastRangeSegment = rangeControl.selectedSegment
        lastMetricSegment = metricControl.selectedSegment
        lastChartStyleSegment = chartStyleControl.selectedSegment
        
        // 汇总
        historySummaryLabel = createLabel(
            text: String(format: NSLocalizedString("history.total", comment: ""), "0"),
            fontSize: 12,
            weight: .regular
        )
        historySummaryLabel.textColor = .secondaryLabelColor
        historySummaryLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(historySummaryLabel)
        
        // 底部分隔线
        let bottomSeparator = NSBox()
        bottomSeparator.boxType = .separator
        bottomSeparator.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(bottomSeparator)
        
        // 按钮容器
        let buttonStack = NSStackView()
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 12
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        

        checkUpdatesButton = NSButton(title: NSLocalizedString("button.checkUpdates", comment: ""), target: self, action: #selector(checkForUpdates))
        checkUpdatesButton.bezelStyle = .rounded
        checkUpdatesButton.controlSize = .regular
        checkUpdatesButton.isHidden = true
        
        // 退出按钮
        quitButton = NSButton(title: NSLocalizedString("button.quit", comment: ""), target: self, action: #selector(quitApp))
        quitButton.bezelStyle = .rounded
        quitButton.controlSize = .regular
        
        buttonStack.addArrangedSubview(checkUpdatesButton)
        buttonStack.addArrangedSubview(quitButton)

        settingsButton = makeSymbolButton(systemName: "gearshape",
                                          fallbackTitle: NSLocalizedString("settings.title", comment: ""),
                                          pointSize: 16,
                                          weight: .semibold,
                                          action: #selector(openSettings))
        settingsButton.toolTip = NSLocalizedString("settings.title", comment: "")
        settingsButton.setAccessibilityLabel(NSLocalizedString("settings.title", comment: ""))
        settingsButton.imageScaling = .scaleProportionallyDown
        settingsButton.setContentHuggingPriority(.required, for: .horizontal)
        settingsButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        if let hoverButton = settingsButton as? HoverIconButton {
            hoverButton.padding = 4
            hoverButton.cornerRadius = 6
        }
        NSLayoutConstraint.activate([
            settingsButton.widthAnchor.constraint(equalToConstant: 28),
            settingsButton.heightAnchor.constraint(equalToConstant: 28)
        ])

        appStatsButton = makeSymbolButton(systemName: "square.grid.2x2",
                                          fallbackTitle: NSLocalizedString("appStats.button", comment: ""),
                                          pointSize: 16,
                                          weight: .semibold,
                                          action: #selector(showAppStats))
        appStatsButton.toolTip = NSLocalizedString("appStats.button", comment: "")
        appStatsButton.setAccessibilityLabel(NSLocalizedString("appStats.button", comment: ""))
        appStatsButton.imageScaling = .scaleProportionallyDown
        appStatsButton.setContentHuggingPriority(.required, for: .horizontal)
        appStatsButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        if let hoverButton = appStatsButton as? HoverIconButton {
            hoverButton.padding = 4
            hoverButton.cornerRadius = 6
        }
        NSLayoutConstraint.activate([
            appStatsButton.widthAnchor.constraint(equalToConstant: 28),
            appStatsButton.heightAnchor.constraint(equalToConstant: 28)
        ])

        allTimeStatsButton = makeSymbolButton(systemName: "chart.bar.xaxis",
                                              fallbackTitle: NSLocalizedString("allTimeStats.button", comment: ""),
                                              pointSize: 16,
                                              weight: .semibold,
                                              action: #selector(showAllTimeStats))
        allTimeStatsButton.toolTip = NSLocalizedString("allTimeStats.button", comment: "")
        allTimeStatsButton.setAccessibilityLabel(NSLocalizedString("allTimeStats.button", comment: ""))
        allTimeStatsButton.imageScaling = .scaleProportionallyDown
        allTimeStatsButton.setContentHuggingPriority(.required, for: .horizontal)
        allTimeStatsButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        if let hoverButton = allTimeStatsButton as? HoverIconButton {
            hoverButton.padding = 4
            hoverButton.cornerRadius = 6
        }
        NSLayoutConstraint.activate([
            allTimeStatsButton.widthAnchor.constraint(equalToConstant: 28),
            allTimeStatsButton.heightAnchor.constraint(equalToConstant: 28)
        ])

        let footerStack = NSStackView()
        footerStack.orientation = .horizontal
        footerStack.alignment = .centerY
        footerStack.spacing = 12
        footerStack.translatesAutoresizingMaskIntoConstraints = false

        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        footerSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        buttonStack.setContentHuggingPriority(.required, for: .horizontal)
        buttonStack.setContentCompressionResistancePriority(.required, for: .horizontal)

        footerStack.addArrangedSubview(settingsButton)
        footerStack.addArrangedSubview(appStatsButton)
        footerStack.addArrangedSubview(allTimeStatsButton)
        footerStack.setCustomSpacing(6, after: settingsButton)
        footerStack.setCustomSpacing(6, after: appStatsButton)
        footerStack.setCustomSpacing(6, after: allTimeStatsButton)
        footerStack.addArrangedSubview(footerSpacer)
        footerStack.addArrangedSubview(buttonStack)

        containerView.addSubview(footerStack)
        
        // 布局约束
        NSLayoutConstraint.activate([
            // 标题
            titleLabel.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),

            kpsBadge.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            kpsBadge.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 8),

            permissionButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            permissionButton.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16),
            
            // 统计项
            statsStackView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            statsStackView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
            statsStackView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16),
            
            // 键位统计
            keyBreakdownTitleLabel.topAnchor.constraint(equalTo: statsStackView.bottomAnchor, constant: 12),
            keyBreakdownTitleLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),

            keyboardHeatmapButton.centerYAnchor.constraint(equalTo: keyBreakdownTitleLabel.centerYAnchor),
            keyboardHeatmapButton.leadingAnchor.constraint(greaterThanOrEqualTo: keyBreakdownTitleLabel.trailingAnchor, constant: 8),
            keyboardHeatmapButton.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16),

            keyBreakdownGridStack.topAnchor.constraint(equalTo: keyBreakdownTitleLabel.bottomAnchor, constant: 8),
            keyBreakdownGridStack.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
            keyBreakdownGridStack.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16),
            keyBreakdownGridStack.heightAnchor.constraint(equalToConstant: 124),

            // 历史趋势
            historyTitleLabel.topAnchor.constraint(equalTo: keyBreakdownGridStack.bottomAnchor, constant: 16),
            historyTitleLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
            
            rangeControl.topAnchor.constraint(equalTo: historyTitleLabel.bottomAnchor, constant: 8),
            rangeControl.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
            rangeControl.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16),
            
            metricControl.topAnchor.constraint(equalTo: rangeControl.bottomAnchor, constant: 8),
            metricControl.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
            metricControl.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16),
            
            chartStyleControl.topAnchor.constraint(equalTo: metricControl.bottomAnchor, constant: 8),
            chartStyleControl.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
            chartStyleControl.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16),
            
            chartView.topAnchor.constraint(equalTo: chartStyleControl.bottomAnchor, constant: 8),
            chartView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
            chartView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16),
            chartView.heightAnchor.constraint(equalToConstant: 140),
            
            historySummaryLabel.topAnchor.constraint(equalTo: chartView.bottomAnchor, constant: 6),
            historySummaryLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
            
            // 底部分隔线
            bottomSeparator.topAnchor.constraint(equalTo: historySummaryLabel.bottomAnchor, constant: 16),
            bottomSeparator.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
            bottomSeparator.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16),
            
            // 按钮
            footerStack.topAnchor.constraint(equalTo: bottomSeparator.bottomAnchor, constant: 6),
            footerStack.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
            footerStack.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16),
            footerStack.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -10)
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
        // 在 Dark Mode 下使用更高的透明度以提高可见性
        let isDarkMode = self.view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let alpha: CGFloat = isDarkMode ? 0.35 : 0.15
        view.layer?.backgroundColor = resolvedCGColor(NSColor.separatorColor, alpha: alpha, for: self.view)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: 1).isActive = true
        return view
    }

    private func makeSymbolButton(systemName: String,
                                  fallbackTitle: String,
                                  pointSize: CGFloat? = nil,
                                  weight: NSFont.Weight = .regular,
                                  action: Selector) -> NSButton {
        var image = NSImage(systemSymbolName: systemName, accessibilityDescription: nil)
        if let pointSize = pointSize, let baseImage = image {
            let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
            image = baseImage.withSymbolConfiguration(configuration)
        }

        if let image = image {
            let button = HoverIconButton(image: image, target: self, action: action)
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.contentTintColor = .labelColor
            button.translatesAutoresizingMaskIntoConstraints = false
            return button
        }

        let button = NSButton(title: fallbackTitle, target: self, action: action)
        button.bezelStyle = .rounded
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    // MARK: - 更新统计数据
    
    private func updateStats() {
        let stats = StatsManager.shared.currentStats
        let hasSideClickData = (stats.sideBackClicks + stats.sideForwardClicks) > 0
        
        keyPressView.updateValue(formatNumber(stats.keyPresses))
        updateKPSBadge()
        leftClickView.updateValue(formatNumber(stats.leftClicks))
        rightClickView.updateValue(formatNumber(stats.rightClicks))
        sideBackClickView.updateValue(formatNumber(stats.sideBackClicks))
        sideForwardClickView.updateValue(formatNumber(stats.sideForwardClicks))
        applySideClickRowVisibility(hasSideClickData)
        mouseDistanceView.updateValue(stats.formattedMouseDistance)
        scrollDistanceView.updateValue(stats.formattedScrollDistance)
        updateKeyBreakdown()
        updateHistorySection()
        updatePermissionButtonVisibility()
        updatePreferredPopoverSizeIfNeeded()
    }

    func prepareForPopoverPresentation() {
        if !isViewLoaded {
            _ = view
        }
        updateStats()
        updatePreferredPopoverSizeIfNeeded()
    }

    private func startLiveUpdates() {
        statsUpdateToken = StatsManager.shared.addStatsUpdateHandler { [weak self] in
            self?.scheduleStatsRefresh()
        }
    }

    private func stopLiveUpdates() {
        if let token = statsUpdateToken {
            StatsManager.shared.removeStatsUpdateHandler(token)
        }
        statsUpdateToken = nil
        pendingStatsRefresh = false
    }

    // MARK: - KPS 实时刷新

    private func updateKPSBadge() {
        let stats = StatsManager.shared.currentStats
        kpsBadge.update(peakKPS: stats.peakKPS, peakCPS: stats.peakCPS)
    }

    private func startKPSRefreshTimer() {
        kpsRefreshTimer?.invalidate()
        kpsRefreshTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.updateKPSBadge()
        }
        if let timer = kpsRefreshTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func stopKPSRefreshTimer() {
        kpsRefreshTimer?.invalidate()
        kpsRefreshTimer = nil
    }

    private func toggleKPSPopover() {
        if let popover = kpsPopover, popover.isShown {
            closeKPSPopover()
        } else {
            showKPSPopover()
        }
    }

    private func showKPSPopover() {
        closeKPSPopover()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: KPSDetailView())
        popover.contentSize = NSSize(width: 220, height: 170)
        self.kpsPopover = popover
        // 在徽章正下方弹出：用徽章底边的零高度矩形作为锚点
        let bottomRect = NSRect(x: 0, y: 0, width: kpsBadge.bounds.width, height: 1)
        popover.show(relativeTo: bottomRect, of: kpsBadge, preferredEdge: .minY)
    }

    private func closeKPSPopover() {
        kpsPopover?.performClose(nil)
        kpsPopover = nil
    }

    private func startUpdateAvailabilityUpdates() {
        if let token = updateAvailabilityToken {
            UpdateManager.shared.removeUpdateAvailabilityHandler(token)
        }

        updateAvailabilityToken = UpdateManager.shared.addUpdateAvailabilityHandler { [weak self] hasUpdate in
            self?.checkUpdatesButton.isHidden = !hasUpdate
        }
        UpdateManager.shared.probeForUpdateAvailability()
    }

    private func stopUpdateAvailabilityUpdates() {
        if let token = updateAvailabilityToken {
            UpdateManager.shared.removeUpdateAvailabilityHandler(token)
        }
        updateAvailabilityToken = nil
    }

    private func scheduleStatsRefresh() {
        guard !pendingStatsRefresh else { return }
        pendingStatsRefresh = true
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.updateStats()
            self.pendingStatsRefresh = false
        }
    }
    
    private func formatNumber(_ number: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: number)) ?? "\(number)"
    }

    private func formatRate(_ rate: Double) -> String {
        if rate <= 0 { return "0" }
        return String(format: "%.1f", rate)
    }

    private func updateKeyBreakdown() {
        let items = StatsManager.shared.keyPressBreakdownSorted()
        let hasItems = !items.isEmpty
        keyBreakdownSeparators.forEach { $0.isHidden = !hasItems }
        guard hasItems else {
            keyBreakdownDisplayedKeys = []
            for column in keyBreakdownColumns {
                column.arrangedSubviews.forEach {
                    column.removeArrangedSubview($0)
                    $0.removeFromSuperview()
                }
            }
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
        let newKeys = limitedItems.map { $0.key }
        if newKeys == keyBreakdownDisplayedKeys {
            for item in limitedItems {
                if let row = keyBreakdownRowCache[item.key] {
                    row.update(key: item.key, count: formatNumber(item.count))
                }
            }
            return
        }
        for column in keyBreakdownColumns {
            column.arrangedSubviews.forEach {
                column.removeArrangedSubview($0)
                $0.removeFromSuperview()
            }
        }
        for (index, item) in limitedItems.enumerated() {
            let columnIndex = index / 5
            if columnIndex >= keyBreakdownColumns.count { break }
            let row = keyBreakdownRowCache[item.key] ?? {
                let row = KeyCountRowView(key: item.key, count: formatNumber(item.count))
                keyBreakdownRowCache[item.key] = row
                return row
            }()
            let column = keyBreakdownColumns[columnIndex]
            column.addArrangedSubview(row)
            row.constrainWidth(to: column)
            row.update(key: item.key, count: formatNumber(item.count))
        }
        keyBreakdownDisplayedKeys = newKeys
    }

    @objc private func historyControlsChanged() {
        let currentRange = rangeControl.selectedSegment
        let currentMetric = metricControl.selectedSegment
        let currentStyle = chartStyleControl.selectedSegment
        let direction: StatsChartView.SlideDirection
        if currentMetric != lastMetricSegment {
            direction = currentMetric > lastMetricSegment ? .right : .left
        } else if currentRange != lastRangeSegment {
            direction = currentRange > lastRangeSegment ? .right : .left
        } else if currentStyle != lastChartStyleSegment {
            direction = currentStyle > lastChartStyleSegment ? .right : .left
        } else {
            direction = .right
        }
        if currentRange != lastRangeSegment {
            AppDelegate.trackClick("chart_range", properties: [
                "range": currentRange == 0 ? "7d" : "30d"
            ])
        }
        if currentMetric != lastMetricSegment {
            let metric = currentMetricName(for: currentMetric)
            AppDelegate.trackClick("chart_metric", properties: [
                "metric": metric
            ])
        }
        if currentStyle != lastChartStyleSegment {
            AppDelegate.trackClick("chart_style", properties: [
                "style": currentStyle == 0 ? "line" : "bar"
            ])
        }
        lastRangeSegment = currentRange
        lastMetricSegment = currentMetric
        lastChartStyleSegment = currentStyle
        updateHistorySection(animated: true, slideDirection: direction)
    }

    private func updatePermissionButtonVisibility() {
        if case .connected(_, let granted) = HelperXPCClient.shared.state {
            permissionButton.isHidden = granted
        } else {
            permissionButton.isHidden = false
        }
    }

    private func focusPrimaryControl() {
        if !permissionButton.isHidden {
            view.window?.makeFirstResponder(permissionButton)
        }
    }
    
    private func updateHistorySection(animated: Bool = false, slideDirection: StatsChartView.SlideDirection? = nil) {
        let range = selectedRange()
        let metric = selectedMetric()
        let style = selectedChartStyle()
        
        let series = StatsManager.shared.historySeries(range: range, metric: metric)
        chartView.apply(series: series,
                        metric: metric,
                        range: range,
                        style: style,
                        animated: animated,
                        slideDirection: slideDirection)
        
        let total = series.reduce(0) { $0 + $1.value }
        let formatted = StatsManager.shared.formatHistoryValue(metric: metric, value: total)
        historySummaryLabel.stringValue = String(format: NSLocalizedString("history.total", comment: ""), formatted)
    }

    // MARK: - Appearance Updates

    private func updateAppearance() {
        updateKeyBreakdown()
        updateKeyBreakdownSeparatorColors()
        chartView.needsDisplay = true
    }

    private func updateKeyBreakdownSeparatorColors() {
        let isDarkMode = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let alpha: CGFloat = isDarkMode ? 0.35 : 0.15
        let separatorColor = resolvedCGColor(NSColor.separatorColor, alpha: alpha, for: view)
        keyBreakdownSeparators.forEach { $0.layer?.backgroundColor = separatorColor }
    }
    
    private func selectedRange() -> StatsManager.HistoryRange {
        switch rangeControl.selectedSegment {
        case 0: return .week
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

    @objc private func openSettings() {
        AppDelegate.trackClick("open_settings")
        SettingsWindowController.shared.show()
        view.window?.performClose(nil)
    }

    @objc private func showAllTimeStats() {
        AppDelegate.trackClick("open_all_time_stats")
        AllTimeStatsWindowController.shared.show()
        view.window?.performClose(nil)
    }

    @objc private func showAppStats() {
        AppDelegate.trackClick("open_app_stats")
        AppStatsWindowController.shared.show()
        view.window?.performClose(nil)
    }

    @objc private func showKeyboardHeatmap() {
        AppDelegate.trackClick("open_keyboard_heatmap")
        KeyboardHeatmapWindowController.shared.show()
        view.window?.performClose(nil)
    }

    private func currentMetricName(for index: Int) -> String {
        switch index {
        case 0: return "key_presses"
        case 1: return "clicks"
        case 2: return "mouse_distance"
        case 3: return "scroll_distance"
        default: return "unknown"
        }
    }

    @objc private func requestPermission() {
        AppDelegate.shared?.requestAccessibilityPermission(analyticsSource: "popover_button")
        updatePermissionButtonVisibility()
    }

    @objc private func checkForUpdates() {
        guard showUpdatePermissionNoticeIfNeeded() else { return }
        UpdateManager.shared.checkForUpdates()
    }
    
    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    private func showUpdatePermissionNoticeIfNeeded() -> Bool {
        guard !UserDefaults.standard.bool(forKey: updatePermissionNoticeSuppressedKey) else {
            return true
        }

        let alert = NSAlert()
        if let appIcon = NSApp.applicationIconImage {
            alert.icon = appIcon
        }
        alert.messageText = NSLocalizedString("update.notice.title", comment: "")
        alert.informativeText = NSLocalizedString("update.notice.message", comment: "")
        alert.alertStyle = .informational
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = NSLocalizedString("update.notice.suppress", comment: "")
        alert.addButton(withTitle: NSLocalizedString("update.notice.continue", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("update.notice.cancel", comment: ""))

        let response = alert.runModal()
        if alert.suppressionButton?.state == .on {
            UserDefaults.standard.set(true, forKey: updatePermissionNoticeSuppressedKey)
        }
        return response == .alertFirstButtonReturn
    }

    private func applySideClickRowVisibility(_ shouldShow: Bool) {
        let hasRow = statsStackView.arrangedSubviews.contains(sideClickRow)
        if shouldShow {
            guard !hasRow else { return }
            let insertIndex = min(2, statsStackView.arrangedSubviews.count)
            statsStackView.insertArrangedSubview(sideClickRow, at: insertIndex)
            sideClickRow.isHidden = false
            return
        }

        guard hasRow else { return }
        statsStackView.removeArrangedSubview(sideClickRow)
        sideClickRow.removeFromSuperview()
    }

    private func updatePreferredPopoverSizeIfNeeded() {
        guard isViewLoaded else { return }
        view.layoutSubtreeIfNeeded()

        let statsRows = statsStackView.arrangedSubviews
        let statsRowsHeight = statsRows.reduce(CGFloat.zero) { partialResult, row in
            partialResult + row.fittingSize.height
        }
        let statsSpacing = CGFloat(max(0, statsRows.count - 1)) * statsStackView.spacing

        let titleRowHeight = max(
            titleLabel.fittingSize.height,
            kpsBadge.fittingSize.height,
            permissionButton.isHidden ? 0 : permissionButton.fittingSize.height
        )

        let footerHeight = max(
            settingsButton.fittingSize.height,
            appStatsButton.fittingSize.height,
            allTimeStatsButton.fittingSize.height,
            quitButton.fittingSize.height,
            checkUpdatesButton.isHidden ? 0 : checkUpdatesButton.fittingSize.height
        )

        let keyBreakdownHeaderHeight = max(keyBreakdownTitleLabel.fittingSize.height, keyboardHeatmapButton.fittingSize.height)

        let computedHeight =
            16 + titleRowHeight +
            8 + // title -> stats stack
            statsRowsHeight + statsSpacing +
            12 + // stats stack -> key breakdown title
            keyBreakdownHeaderHeight +
            8 + // key breakdown title -> grid
            keyBreakdownGridHeight +
            16 + // grid -> history title
            historyTitleLabel.fittingSize.height +
            8 + rangeControl.fittingSize.height +
            8 + metricControl.fittingSize.height +
            8 + chartStyleControl.fittingSize.height +
            8 + chartHeight +
            6 + historySummaryLabel.fittingSize.height +
            16 + // summary -> bottom separator
            6 + // bottom separator -> footer
            footerHeight +
            10   // footer -> container bottom

        let targetSize = NSSize(width: popoverContentWidth, height: ceil(computedHeight))
        guard preferredContentSize != targetSize else { return }
        preferredContentSize = targetSize
        preferredSizeDidChange?(targetSize)
    }
}

// MARK: - 统计项动画数值

final class AnimatedStatValueViewModel: ObservableObject {
    @Published var text: String

    init(text: String) {
        self.text = text
    }
}

struct AnimatedStatValueView: View {
    @ObservedObject var viewModel: AnimatedStatValueViewModel

    var body: some View {
        Group {
            if #available(macOS 14.0, *) {
                Text(viewModel.text)
                    .font(.system(size: 14, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color(nsColor: .systemBlue))
                    .contentTransition(.numericText())
            } else {
                Text(viewModel.text)
                    .font(.system(size: 14, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color(nsColor: .systemBlue))
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .animation(.default, value: viewModel.text)
    }
}

final class AnimatedKeyCountViewModel: ObservableObject {
    @Published var text: String

    init(text: String) {
        self.text = text
    }
}

struct AnimatedKeyCountView: View {
    @ObservedObject var viewModel: AnimatedKeyCountViewModel

    var body: some View {
        Group {
            if #available(macOS 14.0, *) {
                Text(viewModel.text)
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .contentTransition(.numericText())
            } else {
                Text(viewModel.text)
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            }
        }
        .animation(.default, value: viewModel.text)
    }
}

// MARK: - 统计项视图

class StatItemView: NSView {
    private var iconLabel: NSTextField!
    private var titleLabel: NSTextField!
    private var valueViewModel: AnimatedStatValueViewModel!
    private var valueHostingView: NSHostingView<AnimatedStatValueView>!
    
    init(icon: String, title: String, value: String) {
        super.init(frame: .zero)
        setupUI(icon: icon, title: title, value: value)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupUI(icon: String, title: String, value: String) {
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
        
        // 图标
        iconLabel = NSTextField(labelWithString: icon)
        iconLabel.font = NSFont.systemFont(ofSize: 20)
        iconLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconLabel)
        
        // 标题
        titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)
        
        // 数值（SwiftUI 动画）
        valueViewModel = AnimatedStatValueViewModel(text: value)
        valueHostingView = NSHostingView(rootView: AnimatedStatValueView(viewModel: valueViewModel))
        valueHostingView.translatesAutoresizingMaskIntoConstraints = false
        valueHostingView.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        valueHostingView.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(valueHostingView)
        
        // 布局
        NSLayoutConstraint.activate([
            iconLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            iconLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            iconLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            iconLabel.widthAnchor.constraint(equalToConstant: 24),
            
            titleLabel.leadingAnchor.constraint(equalTo: iconLabel.trailingAnchor, constant: 4),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            
            valueHostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            valueHostingView.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueHostingView.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8)
        ])
    }
    
    func updateValue(_ value: String) {
        let updateBlock = {
            self.valueViewModel.text = value
        }

        if Thread.isMainThread {
            updateBlock()
        } else {
            DispatchQueue.main.async {
                updateBlock()
            }
        }

        valueHostingView.invalidateIntrinsicContentSize()
        needsLayout = true
    }
}

// MARK: - 键位统计行

class KeyCountRowView: NSView {
    private var keyLabel: NSTextField!
    private var countViewModel: AnimatedKeyCountViewModel!
    private var countHostingView: NSHostingView<AnimatedKeyCountView>!
    private var widthConstraint: NSLayoutConstraint?
    private var currentKey: String
    private static let symbolNameMap: [String: String] = [
        "Cmd": "command",
        "Shift": "shift",
        "Option": "option",
        "Ctrl": "control",
        "Fn": "globe",
        "Esc": "escape",
        "Escape": "escape",
        "Tab": "tab",
        "Return": "return",
        "Enter": "return",
        "Delete": "delete.left",
        "ForwardDelete": "delete.right",
        "Left": "arrow.left",
        "Right": "arrow.right",
        "Up": "arrow.up",
        "Down": "arrow.down"
    ]
    private static let squareSymbolKeys: Set<String> = ["Ctrl", "Control"]

    init(key: String, count: String) {
        self.currentKey = key
        super.init(frame: .zero)
        setupUI(key: key, count: count)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI(key: String, count: String) {
        translatesAutoresizingMaskIntoConstraints = false
        let keyFont = NSFont.systemFont(ofSize: 12, weight: .medium)
        keyLabel = NSTextField(labelWithAttributedString: Self.attributedKeyLabel(for: key, font: keyFont, appearance: effectiveAppearance))
        keyLabel.font = keyFont
        keyLabel.textColor = .labelColor
        keyLabel.lineBreakMode = .byTruncatingTail
        keyLabel.maximumNumberOfLines = 1
        keyLabel.cell?.truncatesLastVisibleLine = true
        keyLabel.toolTip = key
        keyLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(keyLabel)

        countViewModel = AnimatedKeyCountViewModel(text: count)
        countHostingView = NSHostingView(rootView: AnimatedKeyCountView(viewModel: countViewModel))
        countHostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(countHostingView)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 20),

            keyLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            keyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            keyLabel.trailingAnchor.constraint(lessThanOrEqualTo: countHostingView.leadingAnchor, constant: -8),

            countHostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            countHostingView.centerYAnchor.constraint(equalTo: centerYAnchor),
            countHostingView.leadingAnchor.constraint(greaterThanOrEqualTo: keyLabel.trailingAnchor, constant: 8)
        ])
    }

    func update(key: String, count: String) {
        currentKey = key
        applyKeyLabel()
        keyLabel.toolTip = key
        let updateBlock = {
            self.countViewModel.text = count
        }

        if Thread.isMainThread {
            updateBlock()
        } else {
            DispatchQueue.main.async {
                updateBlock()
            }
        }

        countHostingView.invalidateIntrinsicContentSize()
        needsLayout = true
    }

    func constrainWidth(to column: NSView) {
        widthConstraint?.isActive = false
        widthConstraint = widthAnchor.constraint(equalTo: column.widthAnchor)
        widthConstraint?.isActive = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyKeyLabel()
    }

    private func applyKeyLabel() {
        if let font = keyLabel.font {
            keyLabel.attributedStringValue = Self.attributedKeyLabel(for: currentKey, font: font, appearance: effectiveAppearance)
        } else {
            keyLabel.stringValue = currentKey
        }
    }

    static func attributedKeyLabel(for key: String, font: NSFont, appearance: NSAppearance? = nil) -> NSAttributedString {
        let currentAppearance = appearance ?? NSApp.effectiveAppearance
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor
        ]
        let result = NSMutableAttributedString()

        for (index, part) in keyParts(from: key).enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "\u{200A}", attributes: textAttributes))
            }
            if let badge = makeKeyBadge(for: part, font: font, appearance: currentAppearance) {
                let attachment = NSTextAttachment()
                attachment.image = badge
                let baselineOffset = (font.ascender + font.descender - badge.size.height) / 2 + 1
                attachment.bounds = CGRect(x: 0, y: baselineOffset, width: badge.size.width, height: badge.size.height)
                result.append(NSAttributedString(attachment: attachment))
            } else {
                result.append(NSAttributedString(string: part, attributes: textAttributes))
            }
        }

        return result
    }

    private static func makeKeyBadge(for keyPart: String, font: NSFont, appearance: NSAppearance) -> NSImage? {
        let contentPointSize = max(font.pointSize - 1, 10)
        let padding: CGFloat = 4
        let lineWidth: CGFloat = 0.8
        let cornerRadiusScale: CGFloat = 0.3
        let textFont = NSFont.systemFont(ofSize: contentPointSize, weight: .medium)
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: textFont,
            .foregroundColor: NSColor.labelColor
        ]
        let textMetricsHeight = ("M" as NSString).size(withAttributes: textAttributes).height
        let badgeHeight = ceil(max(textMetricsHeight, contentPointSize) + padding * 2)

        if let symbolName = Self.symbolNameMap[keyPart],
           let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: keyPart)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: contentPointSize, weight: .medium)) {
            let symbolSize = symbol.size
            let forceSquare = Self.squareSymbolKeys.contains(keyPart)
            let symbolRectSize: NSSize
            let badgeWidth: CGFloat

            if forceSquare {
                let maxSide = contentPointSize
                let scale = min(maxSide / symbolSize.width, maxSide / symbolSize.height)
                symbolRectSize = NSSize(width: symbolSize.width * scale, height: symbolSize.height * scale)
                badgeWidth = badgeHeight
            } else {
                let aspectRatio = symbolSize.height > 0 ? (symbolSize.width / symbolSize.height) : 1
                let symbolHeight = contentPointSize
                let symbolWidth = symbolHeight * aspectRatio
                symbolRectSize = NSSize(width: symbolWidth, height: symbolHeight)
                badgeWidth = ceil(max(badgeHeight, symbolWidth + padding * 2))
            }
            let badgeSize = NSSize(width: badgeWidth, height: badgeHeight)
            return drawBadge(size: badgeSize, cornerRadius: badgeHeight * cornerRadiusScale, lineWidth: lineWidth, appearance: appearance) { rect in
                let symbolRect = NSRect(
                    x: rect.midX - symbolRectSize.width / 2,
                    y: rect.midY - symbolRectSize.height / 2,
                    width: symbolRectSize.width,
                    height: symbolRectSize.height
                )
                // 使用正确的方式绘制带颜色的 SF Symbol
                if let tintedSymbol = tintImage(symbol, with: NSColor.labelColor) {
                    tintedSymbol.draw(in: symbolRect)
                } else {
                    symbol.draw(in: symbolRect)
                }
            }
        }

        let text = keyPart
        let textSize = (text as NSString).size(withAttributes: textAttributes)
        let contentHeight = max(contentPointSize, textSize.height)
        let badgeWidth = ceil(max(badgeHeight, textSize.width + padding * 2))
        let badgeSize = NSSize(width: badgeWidth, height: badgeHeight)
        return drawBadge(size: badgeSize, cornerRadius: badgeHeight * cornerRadiusScale, lineWidth: lineWidth, appearance: appearance) { rect in
            let textRect = NSRect(
                x: rect.midX - textSize.width / 2,
                y: rect.midY - textSize.height / 2,
                width: textSize.width,
                height: textSize.height
            )
            (text as NSString).draw(in: textRect, withAttributes: textAttributes)
        }
    }

    private static func drawBadge(size: NSSize, cornerRadius: CGFloat, lineWidth: CGFloat, appearance: NSAppearance, content: (NSRect) -> Void) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        appearance.performAsCurrentDrawingAppearance {
            NSGraphicsContext.current?.shouldAntialias = true
            NSGraphicsContext.current?.imageInterpolation = .high

            let rect = NSRect(
                x: lineWidth / 2,
                y: lineWidth / 2,
                width: size.width - lineWidth,
                height: size.height - lineWidth
            )
            let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
            path.lineJoinStyle = .round
            path.lineCapStyle = .round

            // 使用动态透明度以支持 Dark Mode
            let isDarkMode = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let fillAlpha: CGFloat = isDarkMode ? 0.6 : 0.6

            NSColor.separatorColor.withAlphaComponent(fillAlpha).setFill()
            path.fill()

            content(rect)
        }
        image.unlockFocus()
        return image
    }

    private static func keyParts(from key: String) -> [String] {
        guard key.contains("+") else { return [displayKeyPart(key)] }
        if key.hasSuffix("+") {
            var trimmed = String(key.dropLast())
            if trimmed.hasSuffix("+") {
                trimmed = String(trimmed.dropLast())
            }
            var parts = trimmed.split(separator: "+").map { displayKeyPart(String($0)) }
            parts.append("+")
            return parts.isEmpty ? [displayKeyPart(key)] : parts
        }
        return key.split(separator: "+").map { displayKeyPart(String($0)) }
    }

    private static func displayKeyPart(_ keyPart: String) -> String {
        switch keyPart {
        case "LeftShift":
            return "L Shift"
        case "RightShift":
            return "R Shift"
        case "LeftOption":
            return "L Option"
        case "RightOption":
            return "R Option"
        case "LeftCmd":
            return "L Cmd"
        case "RightCmd":
            return "R Cmd"
        default:
            return keyPart
        }
    }

    private static func tintImage(_ image: NSImage, with color: NSColor) -> NSImage? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let tinted = NSImage(size: image.size)
        tinted.lockFocus()

        guard let context = NSGraphicsContext.current?.cgContext else {
            tinted.unlockFocus()
            return nil
        }

        let imageRect = NSRect(origin: .zero, size: image.size)

        // 使用图像作为遮罩，然后填充颜色
        context.saveGState()
        context.clip(to: imageRect, mask: cgImage)
        color.setFill()
        imageRect.fill()
        context.restoreGState()

        tinted.unlockFocus()
        return tinted
    }
}

// MARK: - 图表视图

class StatsChartView: NSView {
    enum Style {
        case line
        case bar
    }

    enum SlideDirection {
        case left
        case right
    }
    
    var series: [(date: Date, value: Double)] = [] {
        didSet {
            hoverIndex = nil
            needsDisplay = true
        }
    }
    
    var metric: StatsManager.HistoryMetric = .keyPresses {
        didSet { needsDisplay = true }
    }
    
    var range: StatsManager.HistoryRange = .week {
        didSet { needsDisplay = true }
    }
    
    var style: Style = .line {
        didSet { needsDisplay = true }
    }
    
    private var hoverIndex: Int? {
        didSet {
            if hoverIndex != oldValue {
                needsDisplay = true
                updateHoverLabels()
            }
        }
    }

    private lazy var hoverYBlurView: NSVisualEffectView = makeHoverBlurView()
    private lazy var hoverYTextField: NSTextField = makeHoverTextField(parent: hoverYBlurView)
    private lazy var hoverDateBlurView: NSVisualEffectView = makeHoverBlurView()
    private lazy var hoverDateTextField: NSTextField = makeHoverTextField(parent: hoverDateBlurView)
    
    private var trackingArea: NSTrackingArea?
    private let transitionDuration: CFTimeInterval = 0.22
    
    private lazy var dayDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("M/d")
        return formatter
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    func apply(series: [(date: Date, value: Double)],
               metric: StatsManager.HistoryMetric,
               range: StatsManager.HistoryRange,
               style: Style,
               animated: Bool,
               slideDirection: SlideDirection? = nil) {
        if animated {
            addSlideTransition(direction: slideDirection ?? .right)
        }
        self.series = series
        self.metric = metric
        self.range = range
        self.style = style
    }
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }
    
    override func updateTrackingAreas() {
        if let trackingArea = trackingArea {
            removeTrackingArea(trackingArea)
        }
        let options: NSTrackingArea.Options = [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect]
        let area = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }
    
    override func mouseMoved(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        updateHoverIndex(for: location)
    }
    
    override func mouseExited(with event: NSEvent) {
        hoverIndex = nil
    }
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let backgroundRect = bounds.insetBy(dx: 0, dy: 6)

        // 在 Dark Mode 下使用更高的透明度以提高可见性
        let isDarkMode = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let gridAlpha: CGFloat = isDarkMode ? 0.5 : 0.35
        let axisAlpha: CGFloat = isDarkMode ? 0.75 : 0.6
        let backgroundAlpha: CGFloat = isDarkMode ? 0.25 : 0.15

        let gridColor = NSColor.separatorColor.withAlphaComponent(gridAlpha)
        let axisColor = NSColor.separatorColor.withAlphaComponent(axisAlpha)

        NSColor.controlBackgroundColor.withAlphaComponent(backgroundAlpha).setFill()
        NSBezierPath(roundedRect: backgroundRect, xRadius: 6, yRadius: 6).fill()

        guard let maxValue = series.map({ $0.value }).max(), maxValue > 0 else {
            let text = NSLocalizedString("history.empty", comment: "")
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            let size = text.size(withAttributes: attributes)
            let point = NSPoint(x: backgroundRect.midX - size.width / 2, y: backgroundRect.midY - size.height / 2)
            text.draw(at: point, withAttributes: attributes)
            return
        }

        let plotRect = plotRect(in: backgroundRect, maxValue: maxValue)
        drawGrid(in: plotRect, color: gridColor)
        drawAxes(in: plotRect, color: axisColor)
        drawAxisLabels(in: plotRect, maxValue: maxValue)
        
        switch style {
        case .line:
            drawLineChart(in: plotRect, maxValue: maxValue)
        case .bar:
            drawBarChart(in: plotRect, maxValue: maxValue)
        }
        
        drawHover(in: plotRect, maxValue: maxValue, backgroundRect: backgroundRect)
    }
    
    private func drawGrid(in rect: NSRect, color: NSColor) {
        for i in 1...3 {
            let y = rect.minY + rect.height * CGFloat(i) / 4
            let path = NSBezierPath()
            path.move(to: NSPoint(x: rect.minX, y: y))
            path.line(to: NSPoint(x: rect.maxX, y: y))
            color.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }
    
    private func drawAxes(in rect: NSRect, color: NSColor) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX, y: rect.minY))
        path.line(to: NSPoint(x: rect.minX, y: rect.maxY))
        path.move(to: NSPoint(x: rect.minX, y: rect.minY))
        path.line(to: NSPoint(x: rect.maxX, y: rect.minY))
        color.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
    
    private func drawAxisLabels(in rect: NSRect, maxValue: Double) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        
        drawLabel(formatValue(0), at: NSPoint(x: rect.minX - 4, y: rect.minY), alignment: .right, attributes: attributes)
        drawLabel(formatValue(maxValue / 2), at: NSPoint(x: rect.minX - 4, y: rect.midY), alignment: .right, attributes: attributes)
        drawLabel(formatValue(maxValue), at: NSPoint(x: rect.minX - 4, y: rect.maxY), alignment: .right, attributes: attributes)
        
        guard !series.isEmpty else { return }
        let labels = series.map { dateLabel(for: $0.date) }
        let maxLabelWidth = labels
            .map { $0.size(withAttributes: attributes).width }
            .max() ?? 0
        let minSpacing: CGFloat = 6
        let maxLabels = max(2, Int(rect.width / max(1, maxLabelWidth + minSpacing)))
        let count = labels.count
        let step: Int
        if count <= 7 {
            step = 2
        } else if maxLabels >= count {
            step = 1
        } else {
            step = Int(ceil(Double(count - 1) / Double(maxLabels - 1)))
        }
        let xPositions = xPositions(in: rect)
        let y = rect.minY - 14
        var indices = Array(stride(from: 0, to: count, by: step))
        if indices.last != count - 1 {
            // 如果最后一个 stride 索引与末尾太近，替换而非追加，避免标签重叠
            if let last = indices.last, (count - 1 - last) < step / 2, indices.count > 1 {
                indices[indices.count - 1] = count - 1
            } else {
                indices.append(count - 1)
            }
        }
        for index in indices {
            let text = labels[index]
            let x = xPositions[index]
            drawClampedLabel(text, center: NSPoint(x: x, y: y), within: rect, attributes: attributes)
        }
    }
    
    private func drawLineChart(in rect: NSRect, maxValue: Double) {
        let count = series.count
        guard count > 0 else { return }
        let xPositions = xPositions(in: rect)
        let points: [NSPoint] = series.enumerated().map { index, item in
            let x = xPositions[index]
            let y = yPosition(for: item.value, in: rect, maxValue: maxValue)
            return NSPoint(x: x, y: y)
        }

        let path = NSBezierPath()
        path.move(to: points[0])

        if points.count > 1 {
            let tangents = monotoneTangents(for: points)
            for index in 0..<(points.count - 1) {
                let current = points[index]
                let next = points[index + 1]
                let dx = next.x - current.x
                guard dx > 0 else {
                    path.line(to: next)
                    continue
                }

                let controlPoint1 = NSPoint(
                    x: current.x + dx / 3,
                    y: current.y + tangents[index] * dx / 3
                )
                let controlPoint2 = NSPoint(
                    x: next.x - dx / 3,
                    y: next.y - tangents[index + 1] * dx / 3
                )
                path.curve(to: next, controlPoint1: controlPoint1, controlPoint2: controlPoint2)
            }
        }
        
        NSColor.systemBlue.setStroke()
        path.lineWidth = 2
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
        path.stroke()
        
        for point in points {
            let x = point.x
            let y = point.y
            let dotRect = NSRect(x: x - 2.5, y: y - 2.5, width: 5, height: 5)
            let dot = NSBezierPath(ovalIn: dotRect)
            NSColor.systemBlue.setFill()
            dot.fill()
        }
    }

    private func monotoneTangents(for points: [NSPoint]) -> [CGFloat] {
        let count = points.count
        guard count > 1 else { return [0] }

        var dx = Array(repeating: CGFloat(0), count: count - 1)
        var slopes = Array(repeating: CGFloat(0), count: count - 1)

        for index in 0..<(count - 1) {
            let deltaX = max(0.0001, points[index + 1].x - points[index].x)
            dx[index] = deltaX
            slopes[index] = (points[index + 1].y - points[index].y) / deltaX
        }

        var tangents = Array(repeating: CGFloat(0), count: count)
        tangents[0] = slopes[0]
        tangents[count - 1] = slopes[count - 2]

        if count > 2 {
            for index in 1..<(count - 1) {
                let previousSlope = slopes[index - 1]
                let nextSlope = slopes[index]

                if previousSlope == 0 || nextSlope == 0 || (previousSlope > 0) != (nextSlope > 0) {
                    tangents[index] = 0
                    continue
                }

                let previousDX = dx[index - 1]
                let nextDX = dx[index]
                let weight1 = 2 * nextDX + previousDX
                let weight2 = nextDX + 2 * previousDX
                tangents[index] = (weight1 + weight2) / ((weight1 / previousSlope) + (weight2 / nextSlope))
            }
        }

        for index in 0..<(count - 1) {
            let slope = slopes[index]
            if slope == 0 {
                tangents[index] = 0
                tangents[index + 1] = 0
                continue
            }

            let alpha = tangents[index] / slope
            let beta = tangents[index + 1] / slope
            let magnitude = alpha * alpha + beta * beta

            if magnitude > 9 {
                let scale = CGFloat(3.0 / sqrt(Double(magnitude)))
                tangents[index] = scale * alpha * slope
                tangents[index + 1] = scale * beta * slope
            }
        }

        return tangents
    }
    
    private func drawBarChart(in rect: NSRect, maxValue: Double) {
        let count = series.count
        guard count > 0 else { return }
        let stepX = rect.width / CGFloat(count)
        let barWidth = min(stepX * 0.6, 22)
        
        for (index, item) in series.enumerated() {
            let height = (CGFloat(item.value) / CGFloat(maxValue)) * rect.height
            let x = rect.minX + CGFloat(index) * stepX + (stepX - barWidth) / 2
            let barRect = NSRect(x: x, y: rect.minY, width: barWidth, height: height)
            let barPath = NSBezierPath(roundedRect: barRect, xRadius: 2, yRadius: 2)
            NSColor.systemBlue.setFill()
            barPath.fill()
        }
    }
    
    private func drawHover(in rect: NSRect, maxValue: Double, backgroundRect: NSRect) {
        guard let hoverIndex = hoverIndex, hoverIndex >= 0, hoverIndex < series.count else { return }
        let xPositions = xPositions(in: rect)
        let value = series[hoverIndex].value
        let x = xPositions[hoverIndex]
        let y = yPosition(for: value, in: rect, maxValue: maxValue)

        let crosshairColor = NSColor.systemBlue.withAlphaComponent(0.25)
        let crosshairPath = NSBezierPath()
        crosshairPath.move(to: NSPoint(x: x, y: rect.minY))
        crosshairPath.line(to: NSPoint(x: x, y: rect.maxY))
        crosshairPath.move(to: NSPoint(x: rect.minX, y: y))
        crosshairPath.line(to: NSPoint(x: rect.maxX, y: y))
        crosshairColor.setStroke()
        crosshairPath.lineWidth = 1
        crosshairPath.stroke()

        let radius: CGFloat = 5
        let dotRect = NSRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
        let dot = NSBezierPath(ovalIn: dotRect)
        NSColor.systemBlue.setFill()
        dot.fill()
        NSColor.white.withAlphaComponent(0.9).setStroke()
        dot.lineWidth = 2
        dot.stroke()

        // hover 标签通过 NSVisualEffectView 子视图绘制，见 updateHoverLabels()
    }
    
    private func updateHoverIndex(for location: NSPoint) {
        guard !series.isEmpty else {
            hoverIndex = nil
            return
        }
        let backgroundRect = bounds.insetBy(dx: 0, dy: 6)
        let maxValue = series.map({ $0.value }).max() ?? 0
        let rect = plotRect(in: backgroundRect, maxValue: maxValue)
        guard rect.contains(location) else {
            hoverIndex = nil
            return
        }
        let positions = xPositions(in: rect)
        var nearestIndex = 0
        var nearestDistance = abs(location.x - positions[0])
        for (index, x) in positions.enumerated() {
            let distance = abs(location.x - x)
            if distance < nearestDistance {
                nearestDistance = distance
                nearestIndex = index
            }
        }
        hoverIndex = nearestIndex
    }
    
    private func plotRect(in rect: NSRect, maxValue: Double? = nil) -> NSRect {
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10)
        ]
        let leftPadding: CGFloat
        if let maxValue = maxValue, maxValue > 0 {
            let maxLabel = formatValue(maxValue)
            let midLabel = formatValue(maxValue / 2)
            let maxWidth = max(
                maxLabel.size(withAttributes: labelAttributes).width,
                midLabel.size(withAttributes: labelAttributes).width
            )
            leftPadding = ceil(maxWidth) + 8
        } else {
            leftPadding = 36
        }
        let rightPadding: CGFloat = 10
        let topPadding: CGFloat = 10
        let bottomPadding: CGFloat = 20
        let width = max(1, rect.width - leftPadding - rightPadding)
        let height = max(1, rect.height - topPadding - bottomPadding)
        return NSRect(
            x: rect.minX + leftPadding,
            y: rect.minY + bottomPadding,
            width: width,
            height: height
        )
    }
    
    private func xPositions(in rect: NSRect) -> [CGFloat] {
        let count = series.count
        guard count > 0 else { return [] }
        if count == 1 {
            return [rect.midX]
        }
        switch style {
        case .bar:
            let stepX = rect.width / CGFloat(count)
            return (0..<count).map { rect.minX + (CGFloat($0) + 0.5) * stepX }
        case .line:
            let stepX = rect.width / CGFloat(count - 1)
            return (0..<count).map { rect.minX + CGFloat($0) * stepX }
        }
    }
    
    private func yPosition(for value: Double, in rect: NSRect, maxValue: Double) -> CGFloat {
        let ratio = maxValue > 0 ? CGFloat(value / maxValue) : 0
        return rect.minY + ratio * rect.height
    }
    
    private func formatValue(_ value: Double) -> String {
        return StatsManager.shared.formatHistoryValue(metric: metric, value: value)
    }
    
    private func dateLabel(for date: Date) -> String {
        return dayDateFormatter.string(from: date)
    }
    
    private enum LabelAlignment {
        case left
        case center
        case right
    }
    
    private func drawLabel(_ text: String, at point: NSPoint, alignment: LabelAlignment, attributes: [NSAttributedString.Key: Any]) {
        let size = text.size(withAttributes: attributes)
        var x = point.x
        switch alignment {
        case .left:
            break
        case .center:
            x -= size.width / 2
        case .right:
            x -= size.width
        }
        let y = point.y - size.height / 2
        text.draw(at: NSPoint(x: x, y: y), withAttributes: attributes)
    }
    
    private func drawClampedLabel(_ text: String, center: NSPoint, within rect: NSRect, attributes: [NSAttributedString.Key: Any]) {
        let size = text.size(withAttributes: attributes)
        var x = center.x - size.width / 2
        x = min(max(x, rect.minX), rect.maxX - size.width)
        let y = center.y - size.height / 2
        text.draw(at: NSPoint(x: x, y: y), withAttributes: attributes)
    }

    private func makeHoverBlurView() -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .withinWindow
        v.state = .active
        v.wantsLayer = true
        v.layer?.cornerRadius = 4
        v.layer?.masksToBounds = true
        v.isHidden = true
        addSubview(v)
        return v
    }

    private func makeHoverTextField(parent: NSVisualEffectView) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .labelColor
        label.backgroundColor = .clear
        label.drawsBackground = false
        label.isBezeled = false
        label.isEditable = false
        label.isSelectable = false
        parent.addSubview(label)
        return label
    }

    private func updateHoverLabels() {
        guard let hoverIndex = hoverIndex, hoverIndex >= 0, hoverIndex < series.count else {
            hoverYBlurView.isHidden = true
            hoverDateBlurView.isHidden = true
            return
        }

        let backgroundRect = bounds.insetBy(dx: 0, dy: 6)
        guard let maxValue = series.map({ $0.value }).max(), maxValue > 0 else {
            hoverYBlurView.isHidden = true
            hoverDateBlurView.isHidden = true
            return
        }
        let rect = plotRect(in: backgroundRect, maxValue: maxValue)
        guard !rect.isEmpty else {
            hoverYBlurView.isHidden = true
            hoverDateBlurView.isHidden = true
            return
        }

        let xPos = xPositions(in: rect)
        let x = xPos[hoverIndex]
        let value = series[hoverIndex].value
        let y = yPosition(for: value, in: rect, maxValue: maxValue)
        let padding: CGFloat = 3

        // Y 轴数值标签
        let valueText = formatValue(value)
        hoverYTextField.stringValue = valueText
        hoverYTextField.sizeToFit()
        let ySize = hoverYTextField.fittingSize
        let yLabelOriginX = rect.minX - 4 - ySize.width
        let yLabelOriginY = y - ySize.height / 2
        hoverYBlurView.frame = NSRect(
            x: yLabelOriginX - padding,
            y: yLabelOriginY - padding,
            width: ySize.width + padding * 2,
            height: ySize.height + padding * 2
        )
        hoverYTextField.frame = NSRect(x: padding, y: padding, width: ySize.width, height: ySize.height)
        hoverYBlurView.isHidden = false

        // X 轴日期标签
        let dateText = dateLabel(for: series[hoverIndex].date)
        hoverDateTextField.stringValue = dateText
        hoverDateTextField.sizeToFit()
        let dateSize = hoverDateTextField.fittingSize
        var dateX = x - dateSize.width / 2
        dateX = min(max(dateX, backgroundRect.minX), backgroundRect.maxX - dateSize.width)
        let dateY = rect.minY - 14 - dateSize.height / 2
        hoverDateBlurView.frame = NSRect(
            x: dateX - padding,
            y: dateY - padding,
            width: dateSize.width + padding * 2,
            height: dateSize.height + padding * 2
        )
        hoverDateTextField.frame = NSRect(x: padding, y: padding, width: dateSize.width, height: dateSize.height)
        hoverDateBlurView.isHidden = false
    }

    private func addSlideTransition(direction: SlideDirection) {
        guard let layer = layer else { return }
        let timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0.0, 0.2, 1.0)
        let transition = CATransition()
        transition.type = .push
        transition.subtype = direction == .right ? .fromRight : .fromLeft
        transition.duration = transitionDuration
        transition.timingFunction = timingFunction
        layer.add(transition, forKey: "contentSlide")

        let scaleAnimation = CABasicAnimation(keyPath: "transform")
        scaleAnimation.fromValue = CATransform3DMakeScale(0.98, 0.98, 1)
        scaleAnimation.toValue = CATransform3DIdentity
        scaleAnimation.duration = transitionDuration
        scaleAnimation.timingFunction = timingFunction
        layer.add(scaleAnimation, forKey: "contentScale")
    }
}

// MARK: - KPS 徽章视图

/// 单行 KPS/CPS 胶囊入口，展示为 `⚡️ 25|7`
class KPSBadgeView: NSView {
    var onTap: (() -> Void)?

    private let iconLabel: NSTextField
    private let rateLabel: NSTextField

    override init(frame frameRect: NSRect) {
        iconLabel = NSTextField(labelWithString: "⚡️")
        rateLabel = NSTextField(labelWithString: "0|0")
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        wantsLayer = true
        updateAppearance()
        toolTip = "KPS / CPS"

        iconLabel.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        iconLabel.textColor = NSColor.systemOrange.withAlphaComponent(0.9)
        iconLabel.alignment = .center
        iconLabel.translatesAutoresizingMaskIntoConstraints = false
        iconLabel.setContentHuggingPriority(.required, for: .horizontal)

        rateLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        rateLabel.textColor = .secondaryLabelColor
        rateLabel.translatesAutoresizingMaskIntoConstraints = false

        let mainStack = NSStackView(views: [iconLabel, rateLabel])
        mainStack.orientation = .horizontal
        mainStack.alignment = .centerY
        mainStack.spacing = 2
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(mainStack)

        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            mainStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            mainStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            mainStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7)
        ])

        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        layer?.backgroundColor = resolvedCGColor(NSColor.controlBackgroundColor, alpha: 0.7, for: self)
    }

    func update(peakKPS: Int, peakCPS: Int) {
        let textColor = NSColor.secondaryLabelColor
        let separatorColor = NSColor.tertiaryLabelColor.withAlphaComponent(0.5)
        let font = rateLabel.font ?? NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)

        let attributed = NSMutableAttributedString(
            string: "\(peakKPS)",
            attributes: [
                .font: font,
                .foregroundColor: textColor
            ]
        )
        attributed.append(
            NSAttributedString(
                string: " · ",
                attributes: [
                    .font: font,
                    .foregroundColor: separatorColor
                ]
            )
        )
        attributed.append(
            NSAttributedString(
                string: "\(peakCPS)",
                attributes: [
                    .font: font,
                    .foregroundColor: textColor
                ]
            )
        )

        rateLabel.attributedStringValue = attributed
    }

    override func mouseDown(with event: NSEvent) {
        onTap?()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
