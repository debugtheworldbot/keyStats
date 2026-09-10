import Cocoa

/// Two aggregate series, with gaps for hours outside the recording period.
final class HourlyStatsChartView: NSView {
    var points: [HourlyStats.Point] = [] {
        didSet {
            needsDisplay = true
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
        guard plotRect.contains(position), !points.isEmpty else { clearHover(); return }
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
        let rect = plotRect
        let maximum = max(4, points.reduce(0) { max($0, $1.counts.map(value) ?? 0) })
        for step in 0...4 {
            let y = rect.minY + rect.height * CGFloat(step) / 4
            stroke(from: NSPoint(x: rect.minX, y: y), to: NSPoint(x: rect.maxX, y: y), color: .separatorColor, width: 0.5)
            label(String(format: "%.0f", Double(maximum) * Double(step) / 4),
                  at: NSPoint(x: 4, y: y - 6), color: .secondaryLabelColor)
        }
        let keyLabel = NSLocalizedString("history.series.synced", comment: "")
        let clickLabel = NSLocalizedString("history.series.local", comment: "")
        label("● " + keyLabel, at: NSPoint(x: rect.minX, y: bounds.height - 22), color: .systemBlue)
        label("◆ " + clickLabel, at: NSPoint(x: rect.minX + 160, y: bounds.height - 22), color: .systemOrange)
        guard !points.isEmpty else { return }
        for index in points.indices where index % 3 == 0 || index == points.count - 1 {
            // Avoid colliding with the last tick on 23/25-hour daylight-saving days.
            if index != points.count - 1 && points.count - 1 - index < 2 { continue }
            label(hourLabel(points[index].date), at: NSPoint(x: x(index) - 16, y: 10), color: .secondaryLabelColor)
        }
        drawSeries(points, color: .systemBlue, maximum: maximum, dashed: false)
        drawSeries(localPoints, color: .systemOrange, maximum: maximum, dashed: true)
        if points.allSatisfy({ $0.counts == nil }) {
            label(NSLocalizedString("hourly.empty", comment: ""), at: NSPoint(x: rect.minX + 16, y: rect.midY), color: .secondaryLabelColor)
        }
        if let hoverIndex, points.indices.contains(hoverIndex) {
            stroke(from: NSPoint(x: x(hoverIndex), y: rect.minY), to: NSPoint(x: x(hoverIndex), y: rect.maxY), color: .secondaryLabelColor, width: 1)
        }
    }

    private func x(_ index: Int) -> CGFloat {
        plotRect.minX + plotRect.width * CGFloat(index) / CGFloat(max(1, points.count - 1))
    }

    func value(_ counts: HourlyStats.Counts) -> Int { showsClicks ? counts.clicks : counts.keys }

    private func drawSeries(_ series: [HourlyStats.Point], color: NSColor, maximum: Int, dashed: Bool) {
        let path = NSBezierPath()
        var previous: NSPoint?
        for (index, point) in series.enumerated() {
            guard let counts = point.counts else { previous = nil; continue }
            let value = value(counts)
            let position = NSPoint(x: x(index), y: plotRect.minY + plotRect.height * CGFloat(value) / CGFloat(maximum))
            if previous != nil { path.line(to: position) } else { path.move(to: position) }
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
            previous = position
        }
        color.setStroke()
        path.lineWidth = 2
        if dashed { path.setLineDash([5, 3], count: 2, phase: 0) }
        path.stroke()
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
