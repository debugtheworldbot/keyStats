import Foundation
import Cocoa
import UserNotifications

private let metersPerPixel: Double = 0.000264583

private func baseKeyComponent(_ keyName: String) -> String {
    let trimmed = keyName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }
    if let last = trimmed.split(separator: "+").last {
        return String(last).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return trimmed
}

/// 统计数据结构
struct DailyStats: Codable {
    var date: Date
    var keyPresses: Int
    var keyPressCounts: [String: Int]
    var leftClicks: Int
    var rightClicks: Int
    var mouseDistance: Double  // 以像素为单位
    var scrollDistance: Double // 以像素为单位
    var appStats: [String: AppStats]
    
    init() {
        self.date = Calendar.current.startOfDay(for: Date())
        self.keyPresses = 0
        self.keyPressCounts = [:]
        self.leftClicks = 0
        self.rightClicks = 0
        self.mouseDistance = 0
        self.scrollDistance = 0
        self.appStats = [:]
    }

    init(date: Date) {
        self.date = Calendar.current.startOfDay(for: date)
        self.keyPresses = 0
        self.keyPressCounts = [:]
        self.leftClicks = 0
        self.rightClicks = 0
        self.mouseDistance = 0
        self.scrollDistance = 0
        self.appStats = [:]
    }

    enum CodingKeys: String, CodingKey {
        case date
        case keyPresses
        case keyPressCounts
        case leftClicks
        case rightClicks
        case mouseDistance
        case scrollDistance
        case appStats
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = try container.decodeIfPresent(Date.self, forKey: .date) ?? Calendar.current.startOfDay(for: Date())
        keyPresses = try container.decodeIfPresent(Int.self, forKey: .keyPresses) ?? 0
        keyPressCounts = try container.decodeIfPresent([String: Int].self, forKey: .keyPressCounts) ?? [:]
        leftClicks = try container.decodeIfPresent(Int.self, forKey: .leftClicks) ?? 0
        rightClicks = try container.decodeIfPresent(Int.self, forKey: .rightClicks) ?? 0
        mouseDistance = try container.decodeIfPresent(Double.self, forKey: .mouseDistance) ?? 0
        scrollDistance = try container.decodeIfPresent(Double.self, forKey: .scrollDistance) ?? 0
        appStats = try container.decodeIfPresent([String: AppStats].self, forKey: .appStats) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(date, forKey: .date)
        try container.encode(keyPresses, forKey: .keyPresses)
        try container.encode(keyPressCounts, forKey: .keyPressCounts)
        try container.encode(leftClicks, forKey: .leftClicks)
        try container.encode(rightClicks, forKey: .rightClicks)
        try container.encode(mouseDistance, forKey: .mouseDistance)
        try container.encode(scrollDistance, forKey: .scrollDistance)
        try container.encode(appStats, forKey: .appStats)
    }
    
    var totalClicks: Int {
        return leftClicks + rightClicks
    }

    var hasAnyActivity: Bool {
        return keyPresses > 0 ||
            leftClicks > 0 ||
            rightClicks > 0 ||
            mouseDistance > 0 ||
            scrollDistance > 0 ||
            !keyPressCounts.isEmpty ||
            !appStats.isEmpty
    }
    
    /// 纠错率 (Delete + ForwardDelete / Total Keys)
    var correctionRate: Double {
        guard keyPresses > 0 else { return 0 }
        let deleteLikeCount = keyPressCounts.reduce(0) { partial, entry in
            let base = baseKeyComponent(entry.key)
            guard base == "Delete" || base == "ForwardDelete" else { return partial }
            return partial + entry.value
        }
        return Double(deleteLikeCount) / Double(keyPresses)
    }
    
    /// 键鼠比 (Keys / Clicks)
    var inputRatio: Double {
        let clicks = totalClicks
        guard clicks > 0 else { return keyPresses > 0 ? Double.infinity : 0 }
        return Double(keyPresses) / Double(clicks)
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
            return String(format: "%.1f kPx", scrollDistance / 1000)
        } else {
            return String(format: "%.0f px", scrollDistance)
        }
    }
}

/// 有史以来统计数据结构
struct AllTimeStats {
    var totalKeyPresses: Int
    var totalLeftClicks: Int
    var totalRightClicks: Int
    var totalMouseDistance: Double
    var totalScrollDistance: Double
    var keyPressCounts: [String: Int]
    var firstDate: Date?
    var lastDate: Date?
    var activeDays: Int
    var maxDailyKeyPresses: Int
    var maxDailyKeyPressesDate: Date?
    var maxDailyClicks: Int
    var maxDailyClicksDate: Date?
    var mostActiveWeekday: Int?
    var keyActiveDays: Int
    var clickActiveDays: Int
    
    var totalClicks: Int {
        return totalLeftClicks + totalRightClicks
    }

    /// 纠错率 (Delete + ForwardDelete / Total Keys)
    var correctionRate: Double {
        guard totalKeyPresses > 0 else { return 0 }
        let deleteLikeCount = keyPressCounts.reduce(0) { partial, entry in
            let base = baseKeyComponent(entry.key)
            guard base == "Delete" || base == "ForwardDelete" else { return partial }
            return partial + entry.value
        }
        return Double(deleteLikeCount) / Double(totalKeyPresses)
    }
    
    /// 键鼠比 (Keys / Clicks)
    var inputRatio: Double {
        let clicks = totalClicks
        guard clicks > 0 else { return totalKeyPresses > 0 ? Double.infinity : 0 }
        return Double(totalKeyPresses) / Double(clicks)
    }
    
    /// 格式化鼠标移动距离
    var formattedMouseDistance: String {
        let meters = totalMouseDistance * 0.000264583 // metersPerPixel
        if meters >= 1000 {
            return String(format: "%.2f km", meters / 1000)
        } else if totalMouseDistance >= 1000 {
            return String(format: "%.1f m", meters)
        }
        return String(format: "%.0f px", totalMouseDistance)
    }
    
    /// 格式化滚动距离
    var formattedScrollDistance: String {
        if totalScrollDistance >= 10000 {
            return String(format: "%.1f kPx", totalScrollDistance / 1000)
        } else {
            return String(format: "%.0f px", totalScrollDistance)
        }
    }

    static func initial() -> AllTimeStats {
        return AllTimeStats(
            totalKeyPresses: 0,
            totalLeftClicks: 0,
            totalRightClicks: 0,
            totalMouseDistance: 0,
            totalScrollDistance: 0,
            keyPressCounts: [:],
            firstDate: nil,
            lastDate: nil,
            activeDays: 0,
            maxDailyKeyPresses: 0,
            maxDailyKeyPressesDate: nil,
            maxDailyClicks: 0,
            maxDailyClicksDate: nil,
            mostActiveWeekday: nil,
            keyActiveDays: 0,
            clickActiveDays: 0
        )
    }
}

/// 统计数据管理器 - 单例模式
class StatsManager {
    static let shared = StatsManager()
    
    private let userDefaults = UserDefaults.standard
    private let statsKey = "dailyStats"
    private let historyKey = "dailyStatsHistory"
    private let showKeyPressesKey = "showKeyPressesInMenuBar"
    private let showMouseClicksKey = "showMouseClicksInMenuBar"
    private let appStatsEnabledKey = "appStatsEnabled"
    private let keyPressNotifyThresholdKey = "keyPressNotifyThreshold"
    private let clickNotifyThresholdKey = "clickNotifyThreshold"
    private let notificationsEnabledKey = "notificationsEnabled"
    private let enableDynamicIconColorKey = "enableDynamicIconColor"
    private let dynamicIconColorStyleKey = "dynamicIconColorStyle"
    private let dynamicIconColorWindowKey = "dynamicIconColorWindow"
    private let dateFormatter: DateFormatter
    private var history: [String: DailyStats] = [:]
    private var saveTimer: Timer?
    private var statsUpdateTimer: Timer?
    private var midnightCheckTimer: Timer?
    private let saveInterval: TimeInterval = 2.0
    private let statsUpdateDebounceInterval: TimeInterval = 0.3
    
    private var inputRateWindowSeconds: TimeInterval {
        let val = userDefaults.double(forKey: dynamicIconColorWindowKey)
        return val > 0 ? val : 3.0
    }
    
    private let inputRateBucketInterval: TimeInterval = 0.5
    private let inputRateApmThresholds: [Double] = [0, 80, 160, 240]
    private let inputRateLock = NSLock()
    private var isReadyForUpdates = false
    private lazy var inputRateBuckets: [Int] = {
        let bucketCount = max(1, Int(inputRateWindowSeconds / inputRateBucketInterval))
        return Array(repeating: 0, count: bucketCount)
    }()
    private var inputRateBucketIndex = 0
    private var inputRateTimer: Timer?
    private var inputRateStartTime: Date?
    private(set) var currentInputRatePerSecond: Double = 0
    private(set) var currentIconTintColor: NSColor?
    var menuBarUpdateHandler: (() -> Void)?
    private var statsUpdateHandlers: [UUID: () -> Void] = [:]
    
    // Cache for All-Time Stats
    private var cachedHistoryStats: AllTimeStats?
    private var cachedWeekdayStats: [Int: (total: Int, count: Int)]?
    private var cachedForDateKey: String?
    
    /// 设置：是否在菜单栏显示按键数
    var showKeyPressesInMenuBar: Bool {
        didSet {
            userDefaults.set(showKeyPressesInMenuBar, forKey: showKeyPressesKey)
            notifyMenuBarUpdate()
        }
    }
    
    /// 设置：是否在菜单栏显示点击数
    var showMouseClicksInMenuBar: Bool {
        didSet {
            userDefaults.set(showMouseClicksInMenuBar, forKey: showMouseClicksKey)
            notifyMenuBarUpdate()
        }
    }

    /// 设置：是否开启按应用统计
    var appStatsEnabled: Bool {
        didSet {
            userDefaults.set(appStatsEnabled, forKey: appStatsEnabledKey)
            notifyStatsUpdate()
        }
    }

    /// 设置：是否开启统计通知
    var notificationsEnabled: Bool {
        didSet {
            userDefaults.set(notificationsEnabled, forKey: notificationsEnabledKey)
            if notificationsEnabled {
                updateNotificationBaselines()
            }
        }
    }

    /// 设置：按键通知阈值
    var keyPressNotifyThreshold: Int {
        didSet {
            userDefaults.set(keyPressNotifyThreshold, forKey: keyPressNotifyThresholdKey)
            updateKeyPressNotificationBaseline()
        }
    }

    /// 设置：点击通知阈值
    var clickNotifyThreshold: Int {
        didSet {
            userDefaults.set(clickNotifyThreshold, forKey: clickNotifyThresholdKey)
            updateClickNotificationBaseline()
        }
    }

    /// 设置：动态图标颜色时间窗口（秒）
    var dynamicIconColorWindow: TimeInterval {
        get {
            let val = userDefaults.double(forKey: dynamicIconColorWindowKey)
            return val > 0 ? val : 3.0
        }
        set {
            let newVal = max(1.0, newValue) // Minimum 1 second
            userDefaults.set(newVal, forKey: dynamicIconColorWindowKey)
            
            // Re-initialize buckets if enabled
            if enableDynamicIconColor {
                let applyChanges = { [weak self] in
                    guard let self = self else { return }
                    self.stopInputRateTracking()
                    self.resetInputRateBuckets()
                    self.startInputRateTracking()
                    self.updateCurrentInputRate()
                }
                if Thread.isMainThread {
                    applyChanges()
                } else {
                    DispatchQueue.main.async(execute: applyChanges)
                }
            }
        }
    }

    /// 设置：是否启用动态图标颜色
    var enableDynamicIconColor: Bool {
        didSet {
            userDefaults.set(enableDynamicIconColor, forKey: enableDynamicIconColorKey)
            let applyChanges = { [weak self] in
                guard let self = self else { return }
                if self.enableDynamicIconColor {
                    self.resetInputRateBuckets()
                    self.startInputRateTracking()
                } else {
                    self.stopInputRateTracking()
                }
                self.updateCurrentInputRate()
            }
            if Thread.isMainThread {
                applyChanges()
                return
            }
            DispatchQueue.main.async(execute: applyChanges)
        }
    }

    private var lastNotifiedKeyPresses: Int = 0
    private var lastNotifiedClicks: Int = 0
    
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

        // 加载设置（按键/点击默认 true，通知/动态图标默认 false）
        showKeyPressesInMenuBar = userDefaults.object(forKey: showKeyPressesKey) as? Bool ?? true
        showMouseClicksInMenuBar = userDefaults.object(forKey: showMouseClicksKey) as? Bool ?? true
        appStatsEnabled = userDefaults.object(forKey: appStatsEnabledKey) as? Bool ?? true
        notificationsEnabled = userDefaults.object(forKey: notificationsEnabledKey) as? Bool ?? false
        keyPressNotifyThreshold = userDefaults.object(forKey: keyPressNotifyThresholdKey) as? Int ?? 1000
        clickNotifyThreshold = userDefaults.object(forKey: clickNotifyThresholdKey) as? Int ?? 1000
        enableDynamicIconColor = userDefaults.object(forKey: enableDynamicIconColorKey) as? Bool ?? false

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

        updateNotificationBaselines()
        
        isReadyForUpdates = true
        saveStats()
        if enableDynamicIconColor {
            resetInputRateBuckets()
            startInputRateTracking()
            updateCurrentInputRate()
        }
        
        setupMidnightReset()
    }
    
    // MARK: - 数据更新方法

    private func updateAppStats(for identity: AppIdentity, update: (inout AppStats) -> Void) {
        guard appStatsEnabled else { return }
        let bundleId = identity.bundleId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundleId.isEmpty else { return }
        var stats = currentStats.appStats[bundleId] ?? AppStats(bundleId: bundleId, displayName: identity.displayName)
        stats.updateDisplayName(identity.displayName)
        update(&stats)
        currentStats.appStats[bundleId] = stats
    }

    func incrementKeyPresses(keyName: String? = nil, appIdentity: AppIdentity? = nil) {
        ensureCurrentDay()
        currentStats.keyPresses += 1
        if let keyName = keyName, !keyName.isEmpty {
            currentStats.keyPressCounts[keyName, default: 0] += 1
        }
        if let appIdentity = appIdentity {
            updateAppStats(for: appIdentity) { stats in
                stats.recordKeyPress()
            }
        }
        registerInputEvent()
        notifyMenuBarUpdate()
        notifyStatsUpdate()
        notifyKeyPressThresholdIfNeeded()
    }
    
    func incrementLeftClicks(appIdentity: AppIdentity? = nil) {
        ensureCurrentDay()
        currentStats.leftClicks += 1
        if let appIdentity = appIdentity {
            updateAppStats(for: appIdentity) { stats in
                stats.recordLeftClick()
            }
        }
        registerInputEvent()
        notifyMenuBarUpdate()
        notifyStatsUpdate()
        notifyClickThresholdIfNeeded()
    }
    
    func incrementRightClicks(appIdentity: AppIdentity? = nil) {
        ensureCurrentDay()
        currentStats.rightClicks += 1
        if let appIdentity = appIdentity {
            updateAppStats(for: appIdentity) { stats in
                stats.recordRightClick()
            }
        }
        registerInputEvent()
        notifyMenuBarUpdate()
        notifyStatsUpdate()
        notifyClickThresholdIfNeeded()
    }
    
    func addMouseDistance(_ distance: Double) {
        ensureCurrentDay()
        currentStats.mouseDistance += distance
        scheduleDebouncedStatsUpdate()
    }
    
    func addScrollDistance(_ distance: Double, appIdentity: AppIdentity? = nil) {
        ensureCurrentDay()
        currentStats.scrollDistance += abs(distance)
        if let appIdentity = appIdentity {
            updateAppStats(for: appIdentity) { stats in
                stats.addScrollDistance(distance)
            }
        }
        scheduleDebouncedStatsUpdate()
    }

    // MARK: - 输入速率

    func registerInputEvent() {
        guard enableDynamicIconColor else { return }
        inputRateLock.lock()
        inputRateBuckets[inputRateBucketIndex] += 1
        inputRateLock.unlock()
    }

    private func resetInputRateBuckets() {
        inputRateLock.lock()
        let bucketCount = max(1, Int(inputRateWindowSeconds / inputRateBucketInterval))
        inputRateBuckets = Array(repeating: 0, count: bucketCount)
        inputRateBucketIndex = 0
        inputRateLock.unlock()
    }

    private func startInputRateTracking() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.startInputRateTracking()
            }
            return
        }

        inputRateStartTime = Date()
        inputRateTimer?.invalidate()
        inputRateTimer = Timer.scheduledTimer(withTimeInterval: inputRateBucketInterval, repeats: true) { [weak self] _ in
            self?.advanceInputRateBucket()
        }
        if let timer = inputRateTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func stopInputRateTracking() {
        inputRateStartTime = nil
        inputRateTimer?.invalidate()
        inputRateTimer = nil
    }

    private func advanceInputRateBucket() {
        inputRateLock.lock()
        inputRateBucketIndex = (inputRateBucketIndex + 1) % inputRateBuckets.count
        inputRateBuckets[inputRateBucketIndex] = 0
        inputRateLock.unlock()
        updateCurrentInputRate()
    }

    private func updateCurrentInputRate() {
        inputRateLock.lock()
        let totalEvents = inputRateBuckets.reduce(0, +)
        inputRateLock.unlock()
        
        var effectiveWindow = inputRateWindowSeconds
        // Adjust window for initial ramp-up to avoid diluted rates when monitoring just started
        if let startTime = inputRateStartTime {
            let elapsed = Date().timeIntervalSince(startTime)
            if elapsed < effectiveWindow {
                effectiveWindow = max(inputRateBucketInterval, elapsed)
            }
        }
        
        currentInputRatePerSecond = Double(totalEvents) / effectiveWindow
        currentIconTintColor = enableDynamicIconColor ? colorForRate(currentInputRatePerSecond) : nil
        notifyMenuBarUpdate()
    }

    private func colorForRate(_ ratePerSecond: Double) -> NSColor? {
        let apm = ratePerSecond * 60
        let thresholds = inputRateApmThresholds
        if apm < thresholds[1] { return nil }
        if apm >= thresholds[3] { return .systemRed }

        if apm <= thresholds[2] {
            let progress = (apm - thresholds[1]) / (thresholds[2] - thresholds[1])
            let lightGreen = lightenColor(.systemGreen, fraction: 0.6)
            return interpolateColor(from: lightGreen, to: .systemGreen, progress: progress)
        }

        let progress = (apm - thresholds[2]) / (thresholds[3] - thresholds[2])
        return interpolateColor(from: .systemYellow, to: .systemRed, progress: progress)
    }

    private func interpolateColor(from: NSColor, to: NSColor, progress: Double) -> NSColor {
        let fromColor = from.usingColorSpace(.deviceRGB) ?? from
        let toColor = to.usingColorSpace(.deviceRGB) ?? to
        var fr: CGFloat = 0
        var fg: CGFloat = 0
        var fb: CGFloat = 0
        var fa: CGFloat = 0
        var tr: CGFloat = 0
        var tg: CGFloat = 0
        var tb: CGFloat = 0
        var ta: CGFloat = 0
        fromColor.getRed(&fr, green: &fg, blue: &fb, alpha: &fa)
        toColor.getRed(&tr, green: &tg, blue: &tb, alpha: &ta)
        let t = CGFloat(max(0, min(1, progress)))
        return NSColor(
            red: fr + (tr - fr) * t,
            green: fg + (tg - fg) * t,
            blue: fb + (tb - fb) * t,
            alpha: fa + (ta - fa) * t
        )
    }

    private func lightenColor(_ color: NSColor, fraction: CGFloat) -> NSColor {
        let resolved = color.usingColorSpace(.deviceRGB) ?? color
        return resolved.blended(withFraction: min(max(fraction, 0), 1), of: .white) ?? resolved
    }

    // MARK: - 通知阈值

    private func updateNotificationBaselines() {
        updateKeyPressNotificationBaseline()
        updateClickNotificationBaseline()
    }

    private func updateKeyPressNotificationBaseline() {
        lastNotifiedKeyPresses = normalizedBaseline(currentStats.keyPresses, threshold: keyPressNotifyThreshold)
    }

    private func updateClickNotificationBaseline() {
        lastNotifiedClicks = normalizedBaseline(currentStats.totalClicks, threshold: clickNotifyThreshold)
    }

    private func normalizedBaseline(_ count: Int, threshold: Int) -> Int {
        guard threshold > 0 else { return 0 }
        return (count / threshold) * threshold
    }

    private func notifyKeyPressThresholdIfNeeded() {
        guard notificationsEnabled else { return }
        let threshold = keyPressNotifyThreshold
        guard threshold > 0 else { return }
        let count = currentStats.keyPresses
        guard count % threshold == 0 else { return }
        guard count != lastNotifiedKeyPresses else { return }
        lastNotifiedKeyPresses = count
        NotificationManager.shared.sendThresholdNotification(metric: .keyPresses, count: count, threshold: threshold)
    }

    private func notifyClickThresholdIfNeeded() {
        guard notificationsEnabled else { return }
        let threshold = clickNotifyThreshold
        guard threshold > 0 else { return }
        let count = currentStats.totalClicks
        guard count % threshold == 0 else { return }
        guard count != lastNotifiedClicks else { return }
        lastNotifiedClicks = count
        NotificationManager.shared.sendThresholdNotification(metric: .clicks, count: count, threshold: threshold)
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
        cachedHistoryStats = nil
        cachedWeekdayStats = nil
        cachedForDateKey = nil
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

    // MARK: - 数据导出

    private struct ExportPayload: Codable {
        let version: Int
        let exportedAt: Date
        let currentStats: DailyStats
        let history: [String: DailyStats]
    }

    func exportStatsData() throws -> Data {
        var exportHistory = history
        let normalizedDate = Calendar.current.startOfDay(for: currentStats.date)
        var current = currentStats
        current.date = normalizedDate
        let key = dateFormatter.string(from: normalizedDate)
        exportHistory[key] = current

        let payload = ExportPayload(
            version: 1,
            exportedAt: Date(),
            currentStats: current,
            history: exportHistory
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(payload)
    }

    private func scheduleSave() {
        guard saveTimer == nil else { return }
        saveTimer = Timer.scheduledTimer(withTimeInterval: saveInterval, repeats: false) { [weak self] _ in
            self?.saveTimer = nil
            self?.saveStats()
        }
    }

    @discardableResult
    func addStatsUpdateHandler(_ handler: @escaping () -> Void) -> UUID {
        let token = UUID()
        statsUpdateHandlers[token] = handler
        return token
    }

    func removeStatsUpdateHandler(_ token: UUID) {
        statsUpdateHandlers[token] = nil
    }

    private func notifyMenuBarUpdate() {
        guard menuBarUpdateHandler != nil else { return }
        DispatchQueue.main.async { [weak self] in
            self?.menuBarUpdateHandler?()
        }
    }

    private func notifyStatsUpdate() {
        guard !statsUpdateHandlers.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            for handler in self.statsUpdateHandlers.values {
                handler()
            }
        }
    }

    private func scheduleDebouncedStatsUpdate() {
        guard !statsUpdateHandlers.isEmpty else { return }
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
        inputRateTimer?.invalidate()
        inputRateTimer = nil
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
        updateNotificationBaselines()
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
        let keys = showKeyPressesInMenuBar ? formatMenuBarNumber(currentStats.keyPresses) : ""
        let clicks = showMouseClicksInMenuBar ? formatMenuBarNumber(currentStats.totalClicks) : ""
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

    // MARK: - 热力图数据

    /// 返回从本周周起始日往前推 52 周，到今天为止的数据数组（不包含未来日期）
    /// 缺失日期填充为 0
    func heatmapActivityData() -> [(date: Date, keyPresses: Int, clicks: Int)] {
        assert(Thread.isMainThread)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        // 计算本周周起始日
        let todayWeekday = calendar.component(.weekday, from: today)
        let daysFromWeekStart = (todayWeekday - calendar.firstWeekday + 7) % 7
        guard let weekStart = calendar.date(byAdding: .day, value: -daysFromWeekStart, to: today) else {
            return []
        }

        // 向前推 52 周，当前周作为第 53 列（不包含未来日期）
        let totalWeeks = 53
        let startOffsetDays = (totalWeeks - 1) * 7
        guard let startDate = calendar.date(byAdding: .day, value: -startOffsetDays, to: weekStart) else {
            return []
        }

        var result: [(date: Date, keyPresses: Int, clicks: Int)] = []
        var current = startDate

        while current <= today {
            let key = dateFormatter.string(from: current)

            if calendar.isDate(current, inSameDayAs: currentStats.date) {
                result.append((current, currentStats.keyPresses, currentStats.totalClicks))
            } else if let stats = history[key] {
                result.append((current, stats.keyPresses, stats.totalClicks))
            } else {
                result.append((current, 0, 0))
            }

            guard let next = calendar.date(byAdding: .day, value: 1, to: current) else {
                assertionFailure("Failed to advance date when building heatmap data.")
                break
            }
            current = next
        }

        return result
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
            return String(format: "%.1f kPx", distance / 1000)
        } else {
            return String(format: "%.0f px", distance)
        }
    }
    
    // MARK: - 全量统计
    
    func getAllTimeStats() -> AllTimeStats {
        let todayKey = dateFormatter.string(from: currentStats.date)
        
        // 1. 检查并重建缓存（如果需要）
        // 如果缓存不存在，或者缓存是基于旧的日期（比如昨天）生成的，则需要更新
        if cachedHistoryStats == nil || cachedForDateKey != todayKey {
            var stats = AllTimeStats.initial()
            var wdStats: [Int: (total: Int, count: Int)] = [:]
            
            // 聚合历史数据（排除今天）
            for hStats in history.values {
                if dateFormatter.string(from: hStats.date) == todayKey { continue }
                aggregate(daily: hStats, into: &stats, weekdays: &wdStats)
            }
            
            cachedHistoryStats = stats
            cachedWeekdayStats = wdStats
            cachedForDateKey = todayKey
        }
        
        // 2. 基于缓存开始构建最终结果
        var totalStats = cachedHistoryStats ?? AllTimeStats.initial()
        var weekdayStats = cachedWeekdayStats ?? [:]
        
        // 3. 聚合内存中最新的今日数据
        aggregate(daily: currentStats, into: &totalStats, weekdays: &weekdayStats)

        // 4. 计算衍生数据（如每周最佳）
        var maxAvg = 0.0
        var bestWeekday: Int?
        for (day, data) in weekdayStats {
            guard data.count > 0 else { continue }
            let avg = Double(data.total) / Double(data.count)
            if avg > maxAvg {
                maxAvg = avg
                bestWeekday = day
            }
        }
        totalStats.mostActiveWeekday = bestWeekday

        return totalStats
    }
    
    private func aggregate(daily: DailyStats, into total: inout AllTimeStats, weekdays: inout [Int: (total: Int, count: Int)]) {
        guard daily.hasAnyActivity else { return }
        total.totalKeyPresses += daily.keyPresses
        total.totalLeftClicks += daily.leftClicks
        total.totalRightClicks += daily.rightClicks
        total.totalMouseDistance += daily.mouseDistance
        total.totalScrollDistance += daily.scrollDistance

        for (key, count) in daily.keyPressCounts {
            total.keyPressCounts[key, default: 0] += count
        }

        if daily.keyPresses > total.maxDailyKeyPresses {
            total.maxDailyKeyPresses = daily.keyPresses
            total.maxDailyKeyPressesDate = daily.date
        }
        let dailyClicks = daily.leftClicks + daily.rightClicks
        if dailyClicks > total.maxDailyClicks {
            total.maxDailyClicks = dailyClicks
            total.maxDailyClicksDate = daily.date
        }
        if daily.keyPresses > 0 {
            total.keyActiveDays += 1
        }
        if dailyClicks > 0 {
            total.clickActiveDays += 1
        }

        let date = Calendar.current.startOfDay(for: daily.date)
        
        // Weekday stats
        let weekday = Calendar.current.component(.weekday, from: date)
        let dailyTotal = daily.keyPresses + dailyClicks
        let current = weekdays[weekday, default: (0, 0)]
        let increment = dailyTotal > 0 ? 1 : 0
        weekdays[weekday] = (current.total + dailyTotal, current.count + increment)
        
        if let currentFirst = total.firstDate {
            if date < currentFirst {
                total.firstDate = date
            }
        } else {
            total.firstDate = date
        }
        if let currentLast = total.lastDate {
            if date > currentLast {
                total.lastDate = date
            }
        } else {
            total.lastDate = date
        }
        total.activeDays += 1
    }
}

// MARK: - 按应用统计

extension StatsManager {
    enum AppStatsRange {
        case today
        case week
        case month
        case all
    }

    func appStatsSummary(range: AppStatsRange) -> [AppStats] {
        var totals: [String: AppStats] = [:]
        switch range {
        case .today:
            mergeAppStats(from: currentStats, into: &totals)
        case .week, .month:
            let dates = appStatsDates(in: range)
            for date in dates {
                let daily = dailyStats(for: date)
                mergeAppStats(from: daily, into: &totals)
            }
        case .all:
            let todayKey = dateFormatter.string(from: currentStats.date)
            for daily in history.values {
                if dateFormatter.string(from: daily.date) == todayKey { continue }
                mergeAppStats(from: daily, into: &totals)
            }
            mergeAppStats(from: currentStats, into: &totals)
        }
        return Array(totals.values)
    }

    private func dailyStats(for date: Date) -> DailyStats {
        if Calendar.current.isDate(date, inSameDayAs: currentStats.date) {
            return currentStats
        }
        let key = dateFormatter.string(from: date)
        return history[key] ?? DailyStats(date: date)
    }

    private func appStatsDates(in range: AppStatsRange) -> [Date] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        let startDate: Date
        switch range {
        case .today:
            startDate = today
        case .week:
            startDate = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        case .month:
            startDate = calendar.date(byAdding: .day, value: -29, to: today) ?? today
        case .all:
            startDate = today
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

    private func mergeAppStats(from daily: DailyStats, into totals: inout [String: AppStats]) {
        guard !daily.appStats.isEmpty else { return }
        for (bundleId, appStats) in daily.appStats {
            var total = totals[bundleId] ?? AppStats(bundleId: bundleId, displayName: appStats.displayName)
            if !appStats.displayName.isEmpty {
                total.displayName = appStats.displayName
            }
            total.keyPresses += appStats.keyPresses
            total.leftClicks += appStats.leftClicks
            total.rightClicks += appStats.rightClicks
            total.scrollDistance += appStats.scrollDistance
            totals[bundleId] = total
        }
    }
}
