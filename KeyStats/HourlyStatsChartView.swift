import Cocoa

/// Two aggregate series, with gaps for hours outside the recording period.
final class HourlyStatsChartView: NSView {
    var points: [HourlyStats.Point] = [] {
        didSet {
            needsDisplay = true
            if !hasData {
                clearHover()
                setAccessibilityValue(NSLocalizedString("hourly.empty", comment: ""))
                return
            }
            setAccessibilityValue(points.enumerated().map { index, point in
                let total = point.counts.map { String(value($0)) } ?? "—"
                let local = localPoints.indices.contains(index) ? localPoints[index].counts.map { String(value($0)) } ?? "—" : "—"
                return "\(hourLabel(point.date)): \(total) / \(local)"
            }.joined(separator: "; "))
        }
    }
    var localPoints: [HourlyStats.Point] = []
    var showsClicks = false
    var timeZone = TimeZone.current
    var onHover: ((HourlyStats.Point?) -> Void)?
    private var hoverIndex: Int?
    private var area: NSTrackingArea?

    var hasData: Bool { points.contains { $0.counts != nil } }

    var hoveredPoint: HourlyStats.Point? {
        guard let hoverIndex, points.indices.contains(hoverIndex) else { return nil }
        return points[hoverIndex]
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(NSLocalizedString("hourly.chartAccessibility", comment: ""))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        self.area = area
    }

    override func mouseMoved(with event: NSEvent) {
        let position = convert(event.locationInWindow, from: nil)
        guard plotRect.contains(position), hasData else { clearHover(); return }
        let fraction = (position.x - plotRect.minX) / plotRect.width
        hoverIndex = min(points.count - 1, max(0, Int((fraction * CGFloat(points.count - 1)).rounded())))
        needsDisplay = true
        onHover?(hoveredPoint)
    }

    override func mouseExited(with event: NSEvent) { clearHover() }

    func clearHover() {
        hoverIndex = nil
        needsDisplay = true
        onHover?(nil)
    }

    func hourLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private var plotRect: NSRect {
        NSRect(x: 52, y: 32, width: max(1, bounds.width - 72), height: max(1, bounds.height - 64))
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.controlBackgroundColor.withAlphaComponent(0.5).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
        guard hasData else {
            drawEmptyState()
            return
        }
        let rect = plotRect
        let maximum = max(4, points.reduce(0) { max($0, $1.counts.map(value) ?? 0) })
        for step in 0...4 {
            let y = rect.minY + rect.height * CGFloat(step) / 4
            stroke(from: NSPoint(x: rect.minX, y: y), to: NSPoint(x: rect.maxX, y: y), color: .separatorColor, width: 0.5)
            label(String(format: "%.0f", Double(maximum) * Double(step) / 4),
                  at: NSPoint(x: 4, y: y - 6), color: .secondaryLabelColor)
        }
        let keyLabel = legendLabel(title: NSLocalizedString("history.series.synced", comment: ""), series: points)
        let clickLabel = legendLabel(title: NSLocalizedString("history.series.local", comment: ""), series: localPoints)
        let syncedLegend = "● " + keyLabel
        let syncedLegendWidth = syncedLegend.size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)]).width
        label(syncedLegend, at: NSPoint(x: rect.minX, y: bounds.height - 22), color: .systemBlue)
        label("◆ " + clickLabel, at: NSPoint(x: rect.minX + syncedLegendWidth + 16, y: bounds.height - 22), color: .systemOrange)
        guard !points.isEmpty else { return }
        for index in points.indices where index % 3 == 0 || index == points.count - 1 {
            // Avoid colliding with the last tick on 23/25-hour daylight-saving days.
            if index != points.count - 1 && points.count - 1 - index < 2 { continue }
            label(hourLabel(points[index].date), at: NSPoint(x: x(index) - 16, y: 10), color: .secondaryLabelColor)
        }
        drawSeries(points, color: .systemBlue, maximum: maximum, dashed: false)
        drawSeries(localPoints, color: .systemOrange, maximum: maximum, dashed: true)
        if let hoverIndex, points.indices.contains(hoverIndex) {
            stroke(from: NSPoint(x: x(hoverIndex), y: rect.minY), to: NSPoint(x: x(hoverIndex), y: rect.maxY), color: .secondaryLabelColor, width: 1)
        }
    }

    private func drawEmptyState() {
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let badge = NSRect(x: center.x - 26, y: center.y + 6, width: 52, height: 52)
        NSColor.systemBlue.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 16, yRadius: 16).fill()
        let symbol = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.systemBlue]))
        symbol?.draw(in: badge.insetBy(dx: 13, dy: 13))

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let textWidth = max(1, min(420, bounds.width - 48))
        let textX = center.x - textWidth / 2
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ]
        NSLocalizedString("hourly.empty", comment: "").draw(
            in: NSRect(x: textX, y: center.y - 30, width: textWidth, height: 22),
            withAttributes: titleAttributes)
        NSLocalizedString("hourly.empty.hint", comment: "").draw(
            in: NSRect(x: textX, y: center.y - 70, width: textWidth, height: 34),
            withAttributes: [.font: NSFont.systemFont(ofSize: 12),
                             .foregroundColor: NSColor.secondaryLabelColor,
                             .paragraphStyle: paragraph])
    }

    private func x(_ index: Int) -> CGFloat {
        plotRect.minX + plotRect.width * CGFloat(index) / CGFloat(max(1, points.count - 1))
    }

    func value(_ counts: HourlyStats.Counts) -> Int { showsClicks ? counts.clicks : counts.keys }

    private func drawSeries(_ series: [HourlyStats.Point], color: NSColor, maximum: Int, dashed: Bool) {
        let path = NSBezierPath()
        var segment: [NSPoint] = []
        for (index, point) in series.enumerated() {
            guard let counts = point.counts else {
                appendSmoothSegment(segment, to: path)
                segment.removeAll(keepingCapacity: true)
                continue
            }
            let value = value(counts)
            let position = NSPoint(x: x(index), y: plotRect.minY + plotRect.height * CGFloat(value) / CGFloat(maximum))
            segment.append(position)
            color.setFill()
            if dashed {
                let diamond = NSBezierPath()
                diamond.move(to: NSPoint(x: position.x, y: position.y + 3))
                diamond.line(to: NSPoint(x: position.x + 3, y: position.y))
                diamond.line(to: NSPoint(x: position.x, y: position.y - 3))
                diamond.line(to: NSPoint(x: position.x - 3, y: position.y))
                diamond.close()
                diamond.fill()
            } else {
                NSBezierPath(ovalIn: NSRect(x: position.x - 2.5, y: position.y - 2.5, width: 5, height: 5)).fill()
            }
        }
        appendSmoothSegment(segment, to: path)
        color.setStroke()
        path.lineWidth = 2
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
        if dashed { path.setLineDash([5, 3], count: 2, phase: 0) }
        path.stroke()
    }

    private func legendLabel(title: String, series: [HourlyStats.Point]) -> String {
        guard let hoveredPoint else { return title }
        let counts = series.first(where: { $0.date == hoveredPoint.date })?.counts
        let text = counts.map { String(value($0)) } ?? "—"
        return String(format: NSLocalizedString("history.series.value", comment: ""), title, text)
    }

    private func appendSmoothSegment(_ points: [NSPoint], to path: NSBezierPath) {
        guard let first = points.first else { return }
        path.move(to: first)
        let tangents = monotoneTangents(for: points)
        for index in 0..<(points.count - 1) {
            let current = points[index]
            let next = points[index + 1]
            let dx = next.x - current.x
            path.curve(to: next,
                       controlPoint1: NSPoint(x: current.x + dx / 3, y: current.y + tangents[index] * dx / 3),
                       controlPoint2: NSPoint(x: next.x - dx / 3, y: next.y - tangents[index + 1] * dx / 3))
        }
    }

    // Same shape-preserving interpolation as the main trend chart, applied separately across gaps.
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

    private func stroke(from start: NSPoint, to end: NSPoint, color: NSColor, width: CGFloat) {
        let path = NSBezierPath()
        path.move(to: start)
        path.line(to: end)
        path.lineWidth = width
        color.setStroke()
        path.stroke()
    }

    private func label(_ text: String, at point: NSPoint, color: NSColor) {
        text.draw(at: point, withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: color])
    }
}
