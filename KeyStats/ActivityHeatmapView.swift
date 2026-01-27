import AppKit

final class ActivityHeatmapView: NSView {
    // MARK: - 数据模型
    struct DayActivity {
        let date: Date
        let keyPresses: Int
        let clicks: Int
        var total: Int { keyPresses + clicks }
    }

    // MARK: - 配置
    private let monthLabelHeight: CGFloat = 14
    private let weekdayLabelWidth: CGFloat = 28
    private let legendHeight: CGFloat = 20
    private let horizontalPadding: CGFloat = 4
    private let minCellSize: CGFloat = 6  // Smallest readable square at default window size
    private let maxCellSize: CGFloat = 12 // Prevents oversized blocks on wide layouts
    private let minCellSpacing: CGFloat = 0.5

    // 动态计算的尺寸
    private var cellSize: CGFloat = 10
    private var cellSpacing: CGFloat = 2
    private var weeksCount: Int = 53
    private var didInitialLayout = false
    private var gridOffsetX: CGFloat = 0
    private var gridWidth: CGFloat = 0

    // MARK: - 翻转坐标系
    override var isFlipped: Bool { true }

    // MARK: - 数据
    var activityData: [DayActivity] = [] {
        didSet {
            weeksCount = (activityData.count + 6) / 7
            didInitialLayout = false
            cellRects.removeAll()
            needsLayout = true
            needsDisplay = true
        }
    }

    // MARK: - 悬停状态
    private var hoveredIndex: Int?
    private var trackingArea: NSTrackingArea?
    private var cellRects: [NSRect] = []
    private var tooltipView: HeatmapTooltipView?
    private var scrollObserver: NSObjectProtocol?

    // MARK: - intrinsicContentSize（供容器获取高度）
    override var intrinsicContentSize: NSSize {
        let weekCount = max(0, weeksCount)
        let spacingCount = max(0, weekCount - 1)
        let width = weekdayLabelWidth + CGFloat(weekCount) * cellSize + CGFloat(spacingCount) * cellSpacing + horizontalPadding
        let height = monthLabelHeight + 7 * cellSize + 6 * cellSpacing + legendHeight
        return NSSize(width: width, height: height)
    }

    // MARK: - 颜色（动态深色模式支持）
    private func colorForLevel(_ level: Int) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            switch level {
            case 0:
                return isDark ? NSColor(white: 0.15, alpha: 1) : NSColor(white: 0.92, alpha: 1)
            case 1:
                return isDark ? NSColor(red: 0.0, green: 0.43, blue: 0.18, alpha: 1) : NSColor(red: 0.61, green: 0.91, blue: 0.66, alpha: 1)
            case 2:
                return isDark ? NSColor(red: 0.0, green: 0.55, blue: 0.24, alpha: 1) : NSColor(red: 0.25, green: 0.77, blue: 0.39, alpha: 1)
            case 3:
                return isDark ? NSColor(red: 0.15, green: 0.68, blue: 0.38, alpha: 1) : NSColor(red: 0.19, green: 0.63, blue: 0.31, alpha: 1)
            default:
                return isDark ? NSColor(red: 0.22, green: 0.82, blue: 0.48, alpha: 1) : NSColor(red: 0.13, green: 0.43, blue: 0.22, alpha: 1)
            }
        }
    }

    // MARK: - 布局计算
    override func layout() {
        super.layout()
        guard !didInitialLayout, bounds.width > 0 else { return }
        recalculateLayout()
        invalidateIntrinsicContentSize()
        didInitialLayout = true
        hideTooltip()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        configureScrollObserver()
        hideTooltip()
    }

    private func recalculateLayout() {
        guard bounds.width > 0, weeksCount > 0 else { return }

        let availableWidth = max(0, bounds.width - weekdayLabelWidth - horizontalPadding)

        var computedCellSize = floor((availableWidth - minCellSpacing * CGFloat(max(0, weeksCount - 1))) / CGFloat(weeksCount))
        computedCellSize = max(minCellSize, min(maxCellSize, computedCellSize))
        let spacingCount = CGFloat(max(1, weeksCount - 1))
        var computedSpacing = (availableWidth - computedCellSize * CGFloat(weeksCount)) / spacingCount
        if computedSpacing < 0 {
            computedSpacing = 0
        }

        cellSize = computedCellSize
        cellSpacing = computedSpacing
        gridWidth = CGFloat(weeksCount) * cellSize + CGFloat(max(0, weeksCount - 1)) * cellSpacing
        let contentWidth = weekdayLabelWidth + gridWidth
        gridOffsetX = max(0, floor((bounds.width - contentWidth) / 2))

        cellRects.removeAll()
        let calendar = Calendar.current

        for (index, activity) in activityData.enumerated() {
            let weekday = calendar.component(.weekday, from: activity.date)
            let adjustedWeekday = (weekday - calendar.firstWeekday + 7) % 7
            let column = index / 7

            let x = gridOffsetX + weekdayLabelWidth + CGFloat(column) * (cellSize + cellSpacing)
            let y = monthLabelHeight + CGFloat(adjustedWeekday) * (cellSize + cellSpacing)

            cellRects.append(NSRect(x: x, y: y, width: cellSize, height: cellSize))
        }
    }

    // MARK: - 鼠标追踪
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        if let trackingArea = trackingArea {
            addTrackingArea(trackingArea)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        var foundIndex: Int?

        for (index, rect) in cellRects.enumerated() {
            if rect.contains(location) {
                foundIndex = index
                break
            }
        }

        if hoveredIndex != foundIndex {
            hoveredIndex = foundIndex
            updateTooltip()
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hoveredIndex = nil
        hideTooltip()
        needsDisplay = true
    }

    // MARK: - 活动等级计算（带边界保护）
    private func activityLevel(for total: Int, percentiles: [Int]) -> Int {
        guard total > 0, !percentiles.isEmpty else { return 0 }
        if total <= percentiles[0] { return 1 }
        if total <= percentiles[1] { return 2 }
        if total <= percentiles[2] { return 3 }
        return 4
    }

    private func calculatePercentiles() -> [Int] {
        let nonZero = activityData.map { $0.total }.filter { $0 > 0 }.sorted()
        guard nonZero.count >= 4 else {
            guard let maxValue = nonZero.last else { return [] }
            if nonZero.count == 1 {
                return [maxValue, maxValue, maxValue]
            }
            if nonZero.count == 2 {
                return [nonZero[0], nonZero[0], nonZero[1]]
            }
            return [nonZero[0], nonZero[1], nonZero[2]]
        }
        let p25 = nonZero[nonZero.count / 4]
        let p50 = nonZero[nonZero.count / 2]
        let p75 = nonZero[nonZero.count * 3 / 4]
        return [p25, p50, p75]
    }

    // MARK: - 绘制
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard !activityData.isEmpty else { return }
        if cellRects.isEmpty { recalculateLayout() }

        let percentiles = calculatePercentiles()

        for (index, rect) in cellRects.enumerated() where index < activityData.count {
            guard rect.intersects(dirtyRect) else { continue }
            let activity = activityData[index]
            let level = activityLevel(for: activity.total, percentiles: percentiles)

            let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
            colorForLevel(level).setFill()
            path.fill()
        }

        drawMonthLabels()
        drawWeekdayLabels()
        drawLegend()
    }

    private func drawMonthLabels() {
        let calendar = Calendar.current
        let monthFormatter = DateFormatter()
        monthFormatter.dateFormat = "MMM"

        var lastMonth = -1
        var lastLabelMaxX: CGFloat = -CGFloat.greatestFiniteMagnitude
        for (index, activity) in activityData.enumerated() {
            let month = calendar.component(.month, from: activity.date)
            if month != lastMonth && index < cellRects.count {
                let label = monthFormatter.string(from: activity.date)
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 9),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
                let labelSize = label.size(withAttributes: attrs)
                let labelX = cellRects[index].minX
                if labelX - lastLabelMaxX >= 6 {
                    label.draw(at: NSPoint(x: labelX, y: 0), withAttributes: attrs)
                    lastLabelMaxX = labelX + labelSize.width
                }
                lastMonth = month
            }
        }
    }

    private func drawWeekdayLabels() {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        let symbols = formatter.shortWeekdaySymbols ?? ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

        let displayRows = [0, 2, 4]
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9),
            .foregroundColor: NSColor.tertiaryLabelColor
        ]

        for row in displayRows {
            let symbolIndex = (row + calendar.firstWeekday - 1) % 7
            let label = String(symbols[symbolIndex].prefix(3))
            let y = monthLabelHeight + CGFloat(row) * (cellSize + cellSpacing)
            label.draw(at: NSPoint(x: gridOffsetX, y: y + 1), withAttributes: attrs)
        }
    }

    private func drawLegend() {
        let legendY = bounds.height - legendHeight + 4
        let lessText = NSLocalizedString("heatmap.less", comment: "")
        let moreText = NSLocalizedString("heatmap.more", comment: "")

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9),
            .foregroundColor: NSColor.tertiaryLabelColor
        ]

        let boxSize: CGFloat = 10
        let boxSpacing: CGFloat = 3
        let moreSize = moreText.size(withAttributes: attrs)
        let legendWidth = lessText.size(withAttributes: attrs).width + 8 + 5 * (boxSize + boxSpacing) + 8 + moreSize.width
        let contentWidth = weekdayLabelWidth + gridWidth
        let rightEdge = gridOffsetX + contentWidth
        var x = rightEdge - legendWidth

        lessText.draw(at: NSPoint(x: x, y: legendY), withAttributes: attrs)
        x += lessText.size(withAttributes: attrs).width + 8

        for level in 0...4 {
            let rect = NSRect(x: x, y: legendY, width: boxSize, height: boxSize)
            let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
            colorForLevel(level).setFill()
            path.fill()
            x += boxSize + boxSpacing
        }

        x += 5
        moreText.draw(at: NSPoint(x: x, y: legendY), withAttributes: attrs)
    }

    private func updateTooltip() {
        guard let index = hoveredIndex,
              index < activityData.count,
              index < cellRects.count else {
            hideTooltip()
            return
        }

        guard let host = window?.contentView ?? superview else {
            hideTooltip()
            return
        }

        let activity = activityData[index]
        let tooltip = ensureTooltipView(in: host)

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        let dateStr = dateFormatter.string(from: activity.date)
        let totalFormat = NSLocalizedString("heatmap.totalFormat", comment: "")
        let detailFormat = NSLocalizedString("heatmap.detailFormat", comment: "")

        tooltip.configure(
            date: dateStr,
            total: String(format: totalFormat, activity.total),
            detail: String(format: detailFormat, activity.keyPresses, activity.clicks)
        )

        let tooltipSize = tooltip.intrinsicContentSize
        let cellRectInWindow = convert(cellRects[index], to: nil)
        let cellRect = host.convert(cellRectInWindow, from: nil)
        let hostBounds = host.bounds

        var origin = NSPoint(
            x: cellRect.midX - tooltipSize.width / 2,
            y: cellRect.minY - tooltipSize.height - 6
        )

        if origin.y < hostBounds.minY {
            origin.y = cellRect.maxY + 6
        }

        origin.x = max(hostBounds.minX, min(origin.x, hostBounds.maxX - tooltipSize.width))

        tooltip.frame = NSRect(origin: origin, size: tooltipSize)
        tooltip.isHidden = false
    }

    private func hideTooltip() {
        tooltipView?.isHidden = true
    }

    private func ensureTooltipView(in host: NSView) -> HeatmapTooltipView {
        if let tooltipView, tooltipView.superview === host {
            return tooltipView
        }

        let tooltip = HeatmapTooltipView()
        tooltip.translatesAutoresizingMaskIntoConstraints = true
        tooltip.isHidden = true
        host.addSubview(tooltip, positioned: .above, relativeTo: self)
        tooltipView = tooltip
        return tooltip
    }

    deinit {
        if let scrollObserver = scrollObserver {
            NotificationCenter.default.removeObserver(scrollObserver)
        }
        tooltipView?.removeFromSuperview()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hideTooltip()
        configureScrollObserver()
    }

    private func configureScrollObserver() {
        if let scrollObserver = scrollObserver {
            NotificationCenter.default.removeObserver(scrollObserver)
            self.scrollObserver = nil
        }

        guard let scrollView = findEnclosingScrollView() else { return }
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.hideTooltip()
        }
    }

    private func findEnclosingScrollView() -> NSScrollView? {
        var view = superview
        while let current = view {
            if let scroll = current as? NSScrollView { return scroll }
            view = current.superview
        }
        return nil
    }
}

private final class HeatmapTooltipView: NSView {
    private let padding: CGFloat = 8
    private let lineSpacing: CGFloat = 2
    private var dateText = ""
    private var totalText = ""
    private var detailText = ""

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }

    func configure(date: String, total: String, detail: String) {
        dateText = date
        totalText = total
        detailText = detail
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override var intrinsicContentSize: NSSize {
        let dateAttr = dateAttributes()
        let textAttr = textAttributes()

        let dateSize = dateText.size(withAttributes: dateAttr)
        let totalSize = totalText.size(withAttributes: textAttr)
        let detailSize = detailText.size(withAttributes: textAttr)

        let width = max(dateSize.width, totalSize.width, detailSize.width) + padding * 2
        let height = dateSize.height + totalSize.height + detailSize.height + lineSpacing * 2 + padding * 2
        return NSSize(width: width, height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let rect = bounds
        let shadow = NSShadow()
        shadow.shadowOffset = NSSize(width: 0, height: 2)
        shadow.shadowBlurRadius = 6
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.15)
        shadow.set()

        let bgPath = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        NSColor.controlBackgroundColor.setFill()
        bgPath.fill()

        NSShadow().set()

        NSColor.separatorColor.withAlphaComponent(0.3).setStroke()
        bgPath.lineWidth = 0.5
        bgPath.stroke()

        let dateAttr = dateAttributes()
        let textAttr = textAttributes()
        let dateSize = dateText.size(withAttributes: dateAttr)
        let totalSize = totalText.size(withAttributes: textAttr)
        let detailSize = detailText.size(withAttributes: textAttr)

        var y = rect.minY + padding
        dateText.draw(at: NSPoint(x: rect.minX + padding, y: y), withAttributes: dateAttr)
        y += dateSize.height + lineSpacing
        totalText.draw(at: NSPoint(x: rect.minX + padding, y: y), withAttributes: textAttr)
        y += totalSize.height + lineSpacing
        detailText.draw(at: NSPoint(x: rect.minX + padding, y: y), withAttributes: textAttr)
    }

    private func dateAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ]
    }

    private func textAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
    }
}
