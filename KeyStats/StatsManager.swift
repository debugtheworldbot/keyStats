import Foundation
import Cocoa

private let metersPerPixel: Double = 0.000264583

/// 统计数据结构
struct DailyStats: Codable {
    var date: Date
    var keyPresses: Int
    var keyPressCounts: [String: Int]
    var leftClicks: Int
    var rightClicks: Int
    var mouseDistance: Double  // 以像素为单位
    var scrollDistance: Double // 以像素为单位
    
    init() {
        self.date = Calendar.current.startOfDay(for: Date())
        self.keyPresses = 0
        self.keyPressCounts = [:]
        self.leftClicks = 0
        self.rightClicks = 0
        self.mouseDistance = 0
        self.scrollDistance = 0
    }

    init(date: Date) {
        self.date = Calendar.current.startOfDay(for: date)
        self.keyPresses = 0
        self.keyPressCounts = [:]
        self.leftClicks = 0
        self.rightClicks = 0
        self.mouseDistance = 0
        self.scrollDistance = 0
    }
    
    var totalClicks: Int {
        return leftClicks + rightClicks
    }
    
    /// 格式化鼠标移动距离
    var formattedMouseDistance: String {
        let meters = mouseDistance * metersPerPixel
        if meters >= 1000 {
            return String(format: "%.2f km", meters / 1000)
        } else if mouseDistance >= 1000 {
            return String(format: "%.1f m", meters)
        }
        return String(format: "%.0f px", mouseDistance)
    }
    
    /// 格式化滚动距离
    var formattedScrollDistance: String {
        if scrollDistance >= 10000 {
            return String(format: "%.1f k", scrollDistance / 1000)
        } else {
            return String(format: "%.0f px", scrollDistance)
        }
    }
}

/// 统计数据管理器 - 单例模式
class StatsManager {
    static let shared = StatsManager()
    
    private let userDefaults = UserDefaults.standard
    private let statsKey = "dailyStats"
    private let historyKey = "dailyStatsHistory"
    private let dateFormatter: DateFormatter
    private var history: [String: DailyStats] = [:]
    private var saveTimer: Timer?
    private var statsUpdateTimer: Timer?
    private var midnightCheckTimer: Timer?
    private let saveInterval: TimeInterval = 2.0
    private let statsUpdateDebounceInterval: TimeInterval = 0.3
    private var isReadyForUpdates = false
    var menuBarUpdateHandler: (() -> Void)?
    var statsUpdateHandler: (() -> Void)?
    
    /// 当前统计数据
    private(set) var currentStats: DailyStats {
        didSet {
            guard isReadyForUpdates else { return }
            scheduleSave()
        }
    }
    
    /// 上次鼠标位置（用于计算移动距离）
    var lastMousePosition: NSPoint?
    
    private init() {
        dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"

        // 先初始化 currentStats 为默认值
        let calendar = Calendar.current
        currentStats = DailyStats(date: calendar.startOfDay(for: Date()))
        history = loadHistory()
        
        // 然后尝试加载保存的数据（使用静态方法）
        if let savedStats = loadStats() {
            if Calendar.current.isDateInToday(savedStats.date) {
                currentStats = savedStats
            }
        }
        
        isReadyForUpdates = true
        saveStats()
        
        setupMidnightReset()
    }
    
    // MARK: - 数据更新方法
    
    func incrementKeyPresses(keyName: String? = nil) {
        ensureCurrentDay()
        currentStats.keyPresses += 1
        if let keyName = keyName, !keyName.isEmpty {
            currentStats.keyPressCounts[keyName, default: 0] += 1
        }
        notifyMenuBarUpdate()
        notifyStatsUpdate()
    }
    
    func incrementLeftClicks() {
        ensureCurrentDay()
        currentStats.leftClicks += 1
        notifyMenuBarUpdate()
        notifyStatsUpdate()
    }
    
    func incrementRightClicks() {
        ensureCurrentDay()
        currentStats.rightClicks += 1
        notifyMenuBarUpdate()
        notifyStatsUpdate()
    }
    
    func addMouseDistance(_ distance: Double) {
        ensureCurrentDay()
        currentStats.mouseDistance += distance
        scheduleDebouncedStatsUpdate()
    }
    
    func addScrollDistance(_ distance: Double) {
        ensureCurrentDay()
        currentStats.scrollDistance += abs(distance)
        scheduleDebouncedStatsUpdate()
    }
    
    // MARK: - 数据持久化
    
    private func saveStats() {
        if let encoded = try? JSONEncoder().encode(currentStats) {
            userDefaults.set(encoded, forKey: statsKey)
        }
        recordCurrentStatsToHistory()
    }
    
    private func loadStats() -> DailyStats? {
        guard let data = userDefaults.data(forKey: statsKey),
              let stats = try? JSONDecoder().decode(DailyStats.self, from: data) else {
            return nil
        }
        return stats
    }

    private func recordCurrentStatsToHistory() {
        let calendar = Calendar.current
        let normalizedDate = calendar.startOfDay(for: currentStats.date)
        let key = dateFormatter.string(from: normalizedDate)
        var stats = currentStats
        stats.date = normalizedDate
        history[key] = stats
        saveHistory()
    }
    
    private func loadHistory() -> [String: DailyStats] {
        guard let data = userDefaults.data(forKey: historyKey),
              let stored = try? JSONDecoder().decode([String: DailyStats].self, from: data) else {
            return [:]
        }
        return stored
    }
    
    private func saveHistory() {
        if let encoded = try? JSONEncoder().encode(history) {
            userDefaults.set(encoded, forKey: historyKey)
        }
    }

    private func scheduleSave() {
        guard saveTimer == nil else { return }
        saveTimer = Timer.scheduledTimer(withTimeInterval: saveInterval, repeats: false) { [weak self] _ in
            self?.saveTimer = nil
            self?.saveStats()
        }
    }

    private func notifyMenuBarUpdate() {
        guard menuBarUpdateHandler != nil else { return }
        DispatchQueue.main.async { [weak self] in
            self?.menuBarUpdateHandler?()
        }
    }

    private func notifyStatsUpdate() {
        guard statsUpdateHandler != nil else { return }
        DispatchQueue.main.async { [weak self] in
            self?.statsUpdateHandler?()
        }
    }

    private func scheduleDebouncedStatsUpdate() {
        guard statsUpdateHandler != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // 取消旧的 timer，实现真正的防抖
            self.statsUpdateTimer?.invalidate()
            self.statsUpdateTimer = Timer.scheduledTimer(withTimeInterval: self.statsUpdateDebounceInterval, repeats: false) { [weak self] _ in
                self?.statsUpdateTimer = nil
                self?.notifyStatsUpdate()
            }
        }
    }

    func flushPendingSave() {
        saveTimer?.invalidate()
        saveTimer = nil
        statsUpdateTimer?.invalidate()
        statsUpdateTimer = nil
        midnightCheckTimer?.invalidate()
        midnightCheckTimer = nil
        saveStats()
    }
    
    // MARK: - 午夜重置

    private func setupMidnightReset() {
        scheduleNextMidnightReset()
    }

    private func scheduleNextMidnightReset() {
        midnightCheckTimer?.invalidate()

        // 使用日历计算下一次午夜，避免睡眠/时区变化导致的漂移
        let calendar = Calendar.current
        let now = Date()
        guard let nextMidnight = calendar.nextDate(
            after: now,
            matching: DateComponents(hour: 0, minute: 0, second: 0),
            matchingPolicy: .nextTime
        ) else {
            print("⚠️ 无法计算午夜时间")
            return
        }

        let timeToMidnight = nextMidnight.timeIntervalSince(now)
        print("📅 设置午夜重置：将在 \(Int(timeToMidnight)) 秒后（\(nextMidnight)）执行重置")

        midnightCheckTimer = Timer.scheduledTimer(withTimeInterval: timeToMidnight, repeats: false) { [weak self] _ in
            self?.performMidnightReset()
        }

        // 确保 timer 在所有 RunLoop 模式下都能运行
        if let timer = midnightCheckTimer {
            RunLoop.current.add(timer, forMode: .common)
        }
    }

    private func performMidnightReset() {
        let now = Date()
        print("🌙 午夜重置触发：\(now)")

        if !Calendar.current.isDate(currentStats.date, inSameDayAs: now) {
            resetStats(for: now)
        }

        scheduleNextMidnightReset()
    }
    
    func resetStats() {
        resetStats(for: Date())
    }

    private func ensureCurrentDay() {
        let now = Date()
        if !Calendar.current.isDate(currentStats.date, inSameDayAs: now) {
            resetStats(for: now)
        }
    }

    private func resetStats(for date: Date) {
        currentStats = DailyStats(date: date)
        notifyMenuBarUpdate()
        notifyStatsUpdate()
    }
    
    // MARK: - 格式化显示
    
    /// 获取菜单栏显示的简短文本
    func getMenuBarText() -> String {
        let parts = getMenuBarTextParts()
        return "\(parts.keys) \(parts.clicks)"
    }

    /// 获取菜单栏显示的数字部分
    func getMenuBarTextParts() -> (keys: String, clicks: String) {
        let keys = formatMenuBarNumber(currentStats.keyPresses)
        let clicks = formatMenuBarNumber(currentStats.totalClicks)
        return (keys, clicks)
    }
    
    /// 菜单栏紧凑显示（多一位小数）
    private func formatMenuBarNumber(_ number: Int) -> String {
        if number >= 1000000 {
            return String(format: "%.2fM", Double(number) / 1000000)
        } else if number >= 1000 {
            return String(format: "%.2fk", Double(number) / 1000)
        } else {
            return "\(number)"
        }
    }

    /// 通用紧凑显示
    private func formatNumber(_ number: Int) -> String {
        if number >= 1000000 {
            return String(format: "%.1fM", Double(number) / 1000000)
        } else if number >= 1000 {
            return String(format: "%.1fk", Double(number) / 1000)
        } else {
            return "\(number)"
        }
    }

    /// 按次数排序的键位统计
    func keyPressBreakdownSorted() -> [(key: String, count: Int)] {
        return currentStats.keyPressCounts
            .sorted {
                if $0.value != $1.value {
                    return $0.value > $1.value
                }
                return $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending
            }
            .map { (key: $0.key, count: $0.value) }
    }
}

// MARK: - 历史数据

extension StatsManager {
    enum HistoryRange {
        case today
        case yesterday
        case week
        case month
    }
    
    enum HistoryMetric {
        case keyPresses
        case clicks
        case mouseDistance
        case scrollDistance
    }
    
    func historySeries(range: HistoryRange, metric: HistoryMetric) -> [(date: Date, value: Double)] {
        let dates = datesInRange(range)
        return dates.map { date in
            let key = dateFormatter.string(from: date)
            let stats = history[key] ?? DailyStats(date: date)
            return (date, metricValue(metric, for: stats))
        }
    }
    
    func formatHistoryValue(metric: HistoryMetric, value: Double) -> String {
        switch metric {
        case .keyPresses, .clicks:
            return formatNumber(Int(value))
        case .mouseDistance:
            return formatMouseDistance(value)
        case .scrollDistance:
            return formatScrollDistance(value)
        }
    }
    
    private func datesInRange(_ range: HistoryRange) -> [Date] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        
        let startDate: Date
        switch range {
        case .today:
            startDate = today
        case .yesterday:
            startDate = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        case .week:
            startDate = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        case .month:
            startDate = calendar.date(byAdding: .day, value: -29, to: today) ?? today
        }
        
        var dates: [Date] = []
        var date = startDate
        while date <= today {
            dates.append(date)
            guard let next = calendar.date(byAdding: .day, value: 1, to: date) else { break }
            date = next
        }
        if dates.isEmpty {
            dates = [today]
        }
        return dates
    }
    
    private func metricValue(_ metric: HistoryMetric, for stats: DailyStats) -> Double {
        switch metric {
        case .keyPresses:
            return Double(stats.keyPresses)
        case .clicks:
            return Double(stats.totalClicks)
        case .mouseDistance:
            return stats.mouseDistance
        case .scrollDistance:
            return stats.scrollDistance
        }
    }
    
    private func formatMouseDistance(_ distance: Double) -> String {
        let meters = distance * metersPerPixel
        if meters >= 1000 {
            return String(format: "%.2f km", meters / 1000)
        } else if distance >= 1000 {
            return String(format: "%.1f m", meters)
        }
        return String(format: "%.0f px", distance)
    }
    
    private func formatScrollDistance(_ distance: Double) -> String {
        if distance >= 10000 {
            return String(format: "%.1f k", distance / 1000)
        } else {
            return String(format: "%.0f px", distance)
        }
    }
}
