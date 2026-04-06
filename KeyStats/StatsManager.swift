import Foundation
import Cocoa
import UserNotifications

private func canonicalKeyPart(_ rawKeyPart: String) -> String {
    let trimmed = rawKeyPart.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }

    switch trimmed.uppercased() {
    case "FN", "FUNCTION", "KEY63", "KEY179", "GLOBE", "🌐":
        return "Fn"
    default:
        return trimmed
    }
}

private func canonicalKeyName(_ keyName: String) -> String {
    let trimmed = keyName.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed == "+" {
        return "+"
    }

    // Handle trailing "++" which means the base key is literal "+".
    // e.g. "Cmd++" → ["Cmd", "+"]
    var raw = trimmed
    var trailingPlus = false
    if raw.hasSuffix("++") {
        raw = String(raw.dropLast())   // "Cmd++" → "Cmd+"
        trailingPlus = true
    }

    var rawComponents = raw
        .split(separator: "+")
        .map { canonicalKeyPart(String($0)) }
        .filter { !$0.isEmpty }

    if trailingPlus {
        rawComponents.append("+")
    }

    guard !rawComponents.isEmpty else { return "" }

    var orderedComponents: [String] = []
    var seenComponents: Set<String> = []
    for component in rawComponents {
        if seenComponents.insert(component).inserted {
            orderedComponents.append(component)
        }
    }

    return orderedComponents.joined(separator: "+")
}

extension DailyStats {
    var formattedMouseDistance: String {
        StatsManager.shared.formatMouseDistance(mouseDistance)
    }

    var formattedScrollDistance: String {
        if scrollDistance >= 10000 {
            return String(format: "%.1f kPx", scrollDistance / 1000)
        } else {
            return String(format: "%.0f px", scrollDistance)
        }
    }
}

extension AllTimeStats {
    var formattedMouseDistance: String {
        StatsManager.shared.formatMouseDistance(totalMouseDistance)
    }

    var formattedScrollDistance: String {
        if totalScrollDistance >= 10000 {
            return String(format: "%.1f kPx", totalScrollDistance / 1000)
        } else {
            return String(format: "%.0f px", totalScrollDistance)
        }
    }
}

/// 统计数据管理器 - 单例模式
class StatsManager {
    static let shared = StatsManager()

    enum ImportMode {
        case overwrite
        case merge
    }

    enum MouseDistanceCalibrationResult {
        case success(pixels: Double, factor: Double)
        case failure(pixels: Double)
    }
    
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
    private let mouseDistanceCalibrationFactorKey = "mouseDistanceCalibrationFactor"
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

    // KPS/CPS 峰值追踪（滑动窗口，1 秒，单调时钟）
    private let statsStateLock = NSLock()
    private var recentKeyTimestamps: [TimeInterval] = []  // ProcessInfo.systemUptime values
    private var recentClickTimestamps: [TimeInterval] = []  // ProcessInfo.systemUptime values
    private var keyTimestampsHead: Int = 0
    private var clickTimestampsHead: Int = 0
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

    private var cachedMouseDistanceCalibrationFactor: Double = 1.0
    private let mouseDistanceCalibrationLock = NSLock()
    private enum MouseDistanceCalibrationState {
        case idle
        case armed
        case recording
    }
    private var mouseDistanceCalibrationState: MouseDistanceCalibrationState = .idle
    private var mouseDistanceCalibrationPixels: Double = 0
    private var mouseDistanceCalibrationTargetMeters: Double = 0
    private var mouseDistanceCalibrationMinPixels: Double = 50
    private var mouseDistanceCalibrationCompletion: ((MouseDistanceCalibrationResult) -> Void)?
    
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

    /// 设置：鼠标距离校准系数（默认 1.0）
    var mouseDistanceCalibrationFactor: Double {
        get { cachedMouseDistanceCalibrationFactor }
        set {
            let clamped = max(0.01, newValue)
            guard cachedMouseDistanceCalibrationFactor != clamped else { return }
            cachedMouseDistanceCalibrationFactor = clamped
            userDefaults.set(clamped, forKey: mouseDistanceCalibrationFactorKey)
            notifyMenuBarUpdate()
            notifyStatsUpdate()
        }
    }

    /// 每像素对应的物理距离（米）
    var mouseDistanceMetersPerPixel: Double {
        return baseMetersPerPixel * mouseDistanceCalibrationFactor
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
        let storedCalibration = userDefaults.double(forKey: mouseDistanceCalibrationFactorKey)
        cachedMouseDistanceCalibrationFactor = storedCalibration > 0 ? storedCalibration : 1.0

        // 先初始化 currentStats 为默认值
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        currentStats = DailyStats(date: today)
        history = normalizedHistory(loadHistory())

        // 优先加载 dailyStats；如果缺失或不是今天，回退到 history 里的今天数据。
        let loadedCurrent = loadStats().map(normalizedDailyStats)
        if let savedStats = loadedCurrent, calendar.isDate(savedStats.date, inSameDayAs: today) {
            currentStats = savedStats
        } else {
            let todayKey = dateFormatter.string(from: today)
            if let todayHistory = history[todayKey] {
                currentStats = normalizedDailyStats(todayHistory)
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

    /// 调用前必须持有 statsStateLock
    private func updateAppStatsLocked(for identity: AppIdentity, update: (inout AppStats) -> Void) {
        guard appStatsEnabled else { return }
        let bundleId = identity.bundleId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundleId.isEmpty else { return }
        var stats = currentStats.appStats[bundleId] ?? AppStats(bundleId: bundleId, displayName: identity.displayName)
        stats.updateDisplayName(identity.displayName)
        update(&stats)
        currentStats.appStats[bundleId] = stats
    }

    func incrementKeyPresses(keyName: String? = nil, appIdentity: AppIdentity? = nil) {
        statsStateLock.lock()
        ensureCurrentDayLocked()
        currentStats.keyPresses += 1
        if let keyName = keyName {
            let canonicalName = canonicalKeyName(keyName)
            if !canonicalName.isEmpty {
                currentStats.keyPressCounts[canonicalName, default: 0] += 1
            }
        }
        if let appIdentity = appIdentity {
            updateAppStatsLocked(for: appIdentity) { stats in
                stats.recordKeyPress()
            }
        }
        statsStateLock.unlock()
        registerInputEvent()
        recordKeyForPeakKPS()
        notifyMenuBarUpdate()
        notifyStatsUpdate()
        notifyKeyPressThresholdIfNeeded()
    }

    func incrementLeftClicks(appIdentity: AppIdentity? = nil) {
        statsStateLock.lock()
        ensureCurrentDayLocked()
        currentStats.leftClicks += 1
        if let appIdentity = appIdentity {
            updateAppStatsLocked(for: appIdentity) { stats in
                stats.recordLeftClick()
            }
        }
        statsStateLock.unlock()
        registerInputEvent()
        recordClickForPeakCPS()
        notifyMenuBarUpdate()
        notifyStatsUpdate()
        notifyClickThresholdIfNeeded()
    }

    func incrementRightClicks(appIdentity: AppIdentity? = nil) {
        statsStateLock.lock()
        ensureCurrentDayLocked()
        currentStats.rightClicks += 1
        if let appIdentity = appIdentity {
            updateAppStatsLocked(for: appIdentity) { stats in
                stats.recordRightClick()
            }
        }
        statsStateLock.unlock()
        registerInputEvent()
        recordClickForPeakCPS()
        notifyMenuBarUpdate()
        notifyStatsUpdate()
        notifyClickThresholdIfNeeded()
    }

    func incrementSideBackClicks(appIdentity: AppIdentity? = nil) {
        statsStateLock.lock()
        ensureCurrentDayLocked()
        currentStats.sideBackClicks += 1
        if let appIdentity = appIdentity {
            updateAppStatsLocked(for: appIdentity) { stats in
                stats.recordSideBackClick()
            }
        }
        statsStateLock.unlock()
        registerInputEvent()
        recordClickForPeakCPS()
        notifyMenuBarUpdate()
        notifyStatsUpdate()
        notifyClickThresholdIfNeeded()
    }

    func incrementSideForwardClicks(appIdentity: AppIdentity? = nil) {
        statsStateLock.lock()
        ensureCurrentDayLocked()
        currentStats.sideForwardClicks += 1
        if let appIdentity = appIdentity {
            updateAppStatsLocked(for: appIdentity) { stats in
                stats.recordSideForwardClick()
            }
        }
        statsStateLock.unlock()
        registerInputEvent()
        recordClickForPeakCPS()
        notifyMenuBarUpdate()
        notifyStatsUpdate()
        notifyClickThresholdIfNeeded()
    }
    
    func addMouseDistance(_ distance: Double) {
        statsStateLock.lock()
        ensureCurrentDayLocked()
        currentStats.mouseDistance += distance
        statsStateLock.unlock()
        scheduleDebouncedStatsUpdate()
    }

    func beginMouseDistanceCalibration(knownMeters: Double,
                                       minPixels: Double = 50,
                                       completion: @escaping (MouseDistanceCalibrationResult) -> Void) {
        mouseDistanceCalibrationLock.lock()
        mouseDistanceCalibrationTargetMeters = max(0, knownMeters)
        mouseDistanceCalibrationMinPixels = max(0, minPixels)
        mouseDistanceCalibrationCompletion = completion
        mouseDistanceCalibrationState = .armed
        mouseDistanceCalibrationPixels = 0
        mouseDistanceCalibrationLock.unlock()
        lastMousePosition = nil
    }

    func cancelMouseDistanceCalibration() {
        mouseDistanceCalibrationLock.lock()
        mouseDistanceCalibrationState = .idle
        mouseDistanceCalibrationPixels = 0
        mouseDistanceCalibrationTargetMeters = 0
        mouseDistanceCalibrationCompletion = nil
        mouseDistanceCalibrationLock.unlock()
    }

    func handleMouseDistanceCalibrationKeyPress() -> Bool {
        var completion: ((MouseDistanceCalibrationResult) -> Void)?
        var result: MouseDistanceCalibrationResult?

        mouseDistanceCalibrationLock.lock()
        switch mouseDistanceCalibrationState {
        case .idle:
            mouseDistanceCalibrationLock.unlock()
            return false
        case .armed:
            mouseDistanceCalibrationState = .recording
            mouseDistanceCalibrationPixels = 0
            mouseDistanceCalibrationLock.unlock()
            lastMousePosition = nil
            return true
        case .recording:
            mouseDistanceCalibrationState = .idle
            let pixels = mouseDistanceCalibrationPixels
            let targetMeters = mouseDistanceCalibrationTargetMeters
            let minPixels = mouseDistanceCalibrationMinPixels
            completion = mouseDistanceCalibrationCompletion
            mouseDistanceCalibrationCompletion = nil
            mouseDistanceCalibrationPixels = 0
            mouseDistanceCalibrationTargetMeters = 0
            mouseDistanceCalibrationLock.unlock()

            if targetMeters > 0, pixels >= minPixels {
                let measuredMetersPerPixel = targetMeters / pixels
                let factor = measuredMetersPerPixel / baseMetersPerPixel
                mouseDistanceCalibrationFactor = factor
                result = .success(pixels: pixels, factor: factor)
            } else {
                result = .failure(pixels: pixels)
            }
        }

        if let completion = completion, let result = result {
            DispatchQueue.main.async {
                completion(result)
            }
        }
        return true
    }

    func recordMouseDistanceCalibration(_ distance: Double) {
        mouseDistanceCalibrationLock.lock()
        if mouseDistanceCalibrationState == .recording {
            mouseDistanceCalibrationPixels += distance
        }
        mouseDistanceCalibrationLock.unlock()
    }

    var isMouseDistanceCalibrating: Bool {
        mouseDistanceCalibrationLock.lock()
        let value = mouseDistanceCalibrationState == .recording
        mouseDistanceCalibrationLock.unlock()
        return value
    }

    var isMouseDistanceCalibrationActive: Bool {
        mouseDistanceCalibrationLock.lock()
        let value = mouseDistanceCalibrationState != .idle
        mouseDistanceCalibrationLock.unlock()
        return value
    }

    func currentMouseDistanceCalibrationPixels() -> Double {
        mouseDistanceCalibrationLock.lock()
        let pixels = mouseDistanceCalibrationPixels
        mouseDistanceCalibrationLock.unlock()
        return pixels
    }
    
    func addScrollDistance(_ distance: Double, appIdentity: AppIdentity? = nil) {
        statsStateLock.lock()
        ensureCurrentDayLocked()
        currentStats.scrollDistance += abs(distance)
        if let appIdentity = appIdentity {
            updateAppStatsLocked(for: appIdentity) { stats in
                stats.addScrollDistance(distance)
            }
        }
        statsStateLock.unlock()
        scheduleDebouncedStatsUpdate()
    }

    // MARK: - 输入速率

    func registerInputEvent() {
        guard enableDynamicIconColor else { return }
        inputRateLock.lock()
        inputRateBuckets[inputRateBucketIndex] += 1
        inputRateLock.unlock()
    }

    // MARK: - KPS/CPS 峰值追踪

    /// Trailing 1-second sliding-window count of key events.
    /// Peak KPS = max trailing 1-second sliding-window count observed today.
    func recordKeyForPeakKPS() {
        let now = ProcessInfo.processInfo.systemUptime
        let cutoff = now - 1.0
        statsStateLock.lock()
        recentKeyTimestamps.append(now)
        pruneKeyTimestamps(before: cutoff)
        let currentKPS = recentKeyTimestamps.count - keyTimestampsHead
        if currentKPS > currentStats.peakKPS {
            currentStats.peakKPS = currentKPS
        }
        statsStateLock.unlock()
    }

    /// Trailing 1-second sliding-window count of click events.
    /// Peak CPS = max trailing 1-second sliding-window count observed today.
    func recordClickForPeakCPS() {
        let now = ProcessInfo.processInfo.systemUptime
        let cutoff = now - 1.0
        statsStateLock.lock()
        recentClickTimestamps.append(now)
        pruneClickTimestamps(before: cutoff)
        let currentCPS = recentClickTimestamps.count - clickTimestampsHead
        if currentCPS > currentStats.peakCPS {
            currentStats.peakCPS = currentCPS
        }
        statsStateLock.unlock()
    }

    // MARK: - 实时 KPS/CPS 查询

    /// 获取当前实时 KPS（过去 1 秒内的按键数）
    func getCurrentKPS() -> Int {
        let cutoff = ProcessInfo.processInfo.systemUptime - 1.0
        statsStateLock.lock()
        pruneKeyTimestamps(before: cutoff)
        let count = recentKeyTimestamps.count - keyTimestampsHead
        statsStateLock.unlock()
        return count
    }

    /// 获取当前实时 CPS（过去 1 秒内的点击数）
    func getCurrentCPS() -> Int {
        let cutoff = ProcessInfo.processInfo.systemUptime - 1.0
        statsStateLock.lock()
        pruneClickTimestamps(before: cutoff)
        let count = recentClickTimestamps.count - clickTimestampsHead
        statsStateLock.unlock()
        return count
    }

    /// 获取当前 KPS/CPS 和峰值的快照（线程安全）
    func currentRatesSnapshot() -> (currentKPS: Int, currentCPS: Int, peakKPS: Int, peakCPS: Int) {
        let cutoff = ProcessInfo.processInfo.systemUptime - 1.0
        statsStateLock.lock()
        pruneKeyTimestamps(before: cutoff)
        pruneClickTimestamps(before: cutoff)
        let kps = recentKeyTimestamps.count - keyTimestampsHead
        let cps = recentClickTimestamps.count - clickTimestampsHead
        let peakKPS = currentStats.peakKPS
        let peakCPS = currentStats.peakCPS
        statsStateLock.unlock()
        return (kps, cps, peakKPS, peakCPS)
    }

    // MARK: - 滑动窗口内部方法（调用前必须持有 statsStateLock）

    private func pruneKeyTimestamps(before cutoff: TimeInterval) {
        while keyTimestampsHead < recentKeyTimestamps.count && recentKeyTimestamps[keyTimestampsHead] <= cutoff {
            keyTimestampsHead += 1
        }
        compactKeyTimestampsIfNeeded()
    }

    private func pruneClickTimestamps(before cutoff: TimeInterval) {
        while clickTimestampsHead < recentClickTimestamps.count && recentClickTimestamps[clickTimestampsHead] <= cutoff {
            clickTimestampsHead += 1
        }
        compactClickTimestampsIfNeeded()
    }

    private func compactKeyTimestampsIfNeeded() {
        if keyTimestampsHead > 128 {
            recentKeyTimestamps.removeFirst(keyTimestampsHead)
            keyTimestampsHead = 0
        }
    }

    private func compactClickTimestampsIfNeeded() {
        if clickTimestampsHead > 128 {
            recentClickTimestamps.removeFirst(clickTimestampsHead)
            clickTimestampsHead = 0
        }
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
        statsStateLock.lock()
        let statsSnapshot = currentStats
        let calendar = Calendar.current
        let normalizedDate = calendar.startOfDay(for: statsSnapshot.date)
        let key = dateFormatter.string(from: normalizedDate)
        var normalizedStats = statsSnapshot
        normalizedStats.date = normalizedDate
        history[key] = normalizedStats
        cachedHistoryStats = nil
        cachedWeekdayStats = nil
        cachedForDateKey = nil
        let historySnapshot = history
        statsStateLock.unlock()

        if let encoded = try? JSONEncoder().encode(statsSnapshot) {
            userDefaults.set(encoded, forKey: statsKey)
        }
        if let encoded = try? JSONEncoder().encode(historySnapshot) {
            userDefaults.set(encoded, forKey: historyKey)
        }
    }

    private func loadStats() -> DailyStats? {
        guard let data = userDefaults.data(forKey: statsKey),
              let stats = try? JSONDecoder().decode(DailyStats.self, from: data) else {
            return nil
        }
        return stats
    }

    private func loadHistory() -> [String: DailyStats] {
        guard let data = userDefaults.data(forKey: historyKey),
              let stored = try? JSONDecoder().decode([String: DailyStats].self, from: data) else {
            return [:]
        }
        return stored
    }

    // MARK: - 数据导入导出

    private struct ExportPayload: Codable {
        let version: Int
        let exportedAt: Date
        let currentStats: DailyStats
        let history: [String: DailyStats]
    }

    private enum ImportError: LocalizedError {
        case invalidFormat
        case unsupportedVersion
        case emptyData

        var errorDescription: String? {
            switch self {
            case .invalidFormat:
                return NSLocalizedString("import.error.invalidFormat", comment: "")
            case .unsupportedVersion:
                return NSLocalizedString("import.error.unsupportedVersion", comment: "")
            case .emptyData:
                return NSLocalizedString("import.error.emptyData", comment: "")
            }
        }
    }

    func exportStatsData() throws -> Data {
        statsStateLock.lock()
        var exportHistory = history
        var current = currentStats
        statsStateLock.unlock()
        let normalizedDate = Calendar.current.startOfDay(for: current.date)
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

    func importStatsData(from data: Data, mode: ImportMode = .overwrite) throws {
        guard !data.isEmpty else { throw ImportError.emptyData }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let payload: ExportPayload
        do {
            payload = try decoder.decode(ExportPayload.self, from: data)
        } catch {
            throw ImportError.invalidFormat
        }

        guard payload.version == 1 else { throw ImportError.unsupportedVersion }

        applyImportedPayload(payload, mode: mode)
    }

    private func applyImportedPayload(_ payload: ExportPayload, mode: ImportMode) {
        saveTimer?.invalidate()
        saveTimer = nil

        var importedHistory = normalizedHistory(payload.history)
        let importedCurrent = normalizedDailyStats(payload.currentStats)
        importedHistory[dateFormatter.string(from: importedCurrent.date)] = importedCurrent

        let today = Calendar.current.startOfDay(for: Date())
        let todayKey = dateFormatter.string(from: today)
        let resolvedHistory: [String: DailyStats]
        switch mode {
        case .overwrite:
            resolvedHistory = importedHistory
        case .merge:
            resolvedHistory = mergedHistory(base: currentHistorySnapshot(), imported: importedHistory)
        }

        statsStateLock.lock()
        history = resolvedHistory
        currentStats = resolvedHistory[todayKey] ?? DailyStats(date: today)
        recentKeyTimestamps.removeAll()
        recentClickTimestamps.removeAll()
        keyTimestampsHead = 0
        clickTimestampsHead = 0
        cachedHistoryStats = nil
        cachedWeekdayStats = nil
        cachedForDateKey = nil
        statsStateLock.unlock()

        saveTimer?.invalidate()
        saveTimer = nil
        updateNotificationBaselines()
        saveStats()
        notifyMenuBarUpdate()
        notifyStatsUpdate()
    }

    private func currentHistorySnapshot() -> [String: DailyStats] {
        statsStateLock.lock()
        let historySnap = history
        let current = currentStats
        statsStateLock.unlock()
        var snapshot = normalizedHistory(historySnap)
        let normalizedCurrent = normalizedDailyStats(current)
        snapshot[dateFormatter.string(from: normalizedCurrent.date)] = normalizedCurrent
        return snapshot
    }

    private func mergedHistory(base: [String: DailyStats], imported: [String: DailyStats]) -> [String: DailyStats] {
        var merged = base

        for (dayKey, importedStats) in imported {
            if let existingStats = merged[dayKey] {
                merged[dayKey] = mergedDailyStats(existingStats, importedStats)
            } else {
                merged[dayKey] = importedStats
            }
        }

        return merged
    }

    private func mergedDailyStats(_ lhs: DailyStats, _ rhs: DailyStats) -> DailyStats {
        var merged = DailyStats(date: lhs.date)
        merged.keyPresses = safeAdd(lhs.keyPresses, rhs.keyPresses)
        merged.leftClicks = safeAdd(lhs.leftClicks, rhs.leftClicks)
        merged.rightClicks = safeAdd(lhs.rightClicks, rhs.rightClicks)
        merged.sideBackClicks = safeAdd(lhs.sideBackClicks, rhs.sideBackClicks)
        merged.sideForwardClicks = safeAdd(lhs.sideForwardClicks, rhs.sideForwardClicks)
        merged.mouseDistance = safeAddDistance(lhs.mouseDistance, rhs.mouseDistance)
        merged.scrollDistance = safeAddDistance(lhs.scrollDistance, rhs.scrollDistance)
        merged.peakKPS = max(lhs.peakKPS, rhs.peakKPS)
        merged.peakCPS = max(lhs.peakCPS, rhs.peakCPS)
        merged.keyPressCounts = mergedCounterMap(lhs.keyPressCounts, rhs.keyPressCounts)
        merged.appStats = mergedAppStats(lhs.appStats, rhs.appStats)
        return merged
    }

    private func mergedCounterMap(_ lhs: [String: Int], _ rhs: [String: Int]) -> [String: Int] {
        var merged = normalizedKeyPressCounts(lhs)
        for (key, value) in rhs {
            let canonicalName = canonicalKeyName(key)
            let count = max(0, value)
            guard !canonicalName.isEmpty, count > 0 else { continue }
            merged[canonicalName] = safeAdd(merged[canonicalName] ?? 0, count)
        }
        return merged
    }

    private func normalizedKeyPressCounts(_ counts: [String: Int]) -> [String: Int] {
        var normalized: [String: Int] = [:]

        for (key, value) in counts {
            let canonicalName = canonicalKeyName(key)
            let count = max(0, value)
            guard !canonicalName.isEmpty, count > 0 else { continue }
            normalized[canonicalName] = safeAdd(normalized[canonicalName] ?? 0, count)
        }

        return normalized
    }

    private func mergedAppStats(_ lhs: [String: AppStats], _ rhs: [String: AppStats]) -> [String: AppStats] {
        var merged = lhs

        for (bundleId, importedStats) in rhs {
            if var existing = merged[bundleId] {
                existing.bundleId = bundleId
                existing.keyPresses = safeAdd(existing.keyPresses, importedStats.keyPresses)
                existing.leftClicks = safeAdd(existing.leftClicks, importedStats.leftClicks)
                existing.rightClicks = safeAdd(existing.rightClicks, importedStats.rightClicks)
                existing.sideBackClicks = safeAdd(existing.sideBackClicks, importedStats.sideBackClicks)
                existing.sideForwardClicks = safeAdd(existing.sideForwardClicks, importedStats.sideForwardClicks)
                existing.scrollDistance = safeAddDistance(existing.scrollDistance, importedStats.scrollDistance)

                let importedName = importedStats.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !importedName.isEmpty {
                    existing.displayName = importedName
                }

                merged[bundleId] = existing
            } else {
                merged[bundleId] = importedStats
            }
        }

        return merged
    }

    private func safeAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : sum
    }

    private func safeAddDistance(_ lhs: Double, _ rhs: Double) -> Double {
        let sum = lhs + rhs
        return sum.isFinite ? max(0, sum) : Double.greatestFiniteMagnitude
    }

    private func normalizedHistory(_ importedHistory: [String: DailyStats]) -> [String: DailyStats] {
        var normalized: [String: DailyStats] = [:]
        for stats in importedHistory.values {
            let daily = normalizedDailyStats(stats)
            normalized[dateFormatter.string(from: daily.date)] = daily
        }
        return normalized
    }

    private func normalizedDailyStats(_ stats: DailyStats) -> DailyStats {
        var normalized = stats
        normalized.date = Calendar.current.startOfDay(for: normalized.date)
        normalized.keyPresses = max(0, normalized.keyPresses)
        normalized.leftClicks = max(0, normalized.leftClicks)
        normalized.rightClicks = max(0, normalized.rightClicks)
        normalized.sideBackClicks = max(0, normalized.sideBackClicks)
        normalized.sideForwardClicks = max(0, normalized.sideForwardClicks)
        normalized.mouseDistance = normalized.mouseDistance.isFinite ? max(0, normalized.mouseDistance) : 0
        normalized.scrollDistance = normalized.scrollDistance.isFinite ? max(0, normalized.scrollDistance) : 0
        normalized.peakKPS = max(0, normalized.peakKPS)
        normalized.peakCPS = max(0, normalized.peakCPS)
        normalized.keyPressCounts = normalizedKeyPressCounts(normalized.keyPressCounts)
        normalized.appStats = normalizedAppStats(normalized.appStats)
        return normalized
    }

    private func normalizedAppStats(_ appStats: [String: AppStats]) -> [String: AppStats] {
        var normalized: [String: AppStats] = [:]

        for (rawBundleId, value) in appStats {
            let bundleId = value.bundleId.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallbackBundleId = rawBundleId.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedBundleId = bundleId.isEmpty ? fallbackBundleId : bundleId
            guard !resolvedBundleId.isEmpty else { continue }

            var stats = value
            stats.bundleId = resolvedBundleId
            stats.keyPresses = max(0, stats.keyPresses)
            stats.leftClicks = max(0, stats.leftClicks)
            stats.rightClicks = max(0, stats.rightClicks)
            stats.sideBackClicks = max(0, stats.sideBackClicks)
            stats.sideForwardClicks = max(0, stats.sideForwardClicks)
            stats.scrollDistance = stats.scrollDistance.isFinite ? max(0, stats.scrollDistance) : 0
            normalized[resolvedBundleId] = stats
        }

        return normalized
    }

    private func scheduleSave() {
        let schedule = { [weak self] in
            guard let self = self, self.saveTimer == nil else { return }
            self.saveTimer = Timer.scheduledTimer(withTimeInterval: self.saveInterval, repeats: false) { [weak self] _ in
                self?.saveTimer = nil
                self?.saveStats()
            }
        }
        if Thread.isMainThread {
            schedule()
        } else {
            DispatchQueue.main.async(execute: schedule)
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
        let doSchedule = { [weak self] in
            guard let self = self else { return }
            self.midnightCheckTimer?.invalidate()

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

            self.midnightCheckTimer = Timer.scheduledTimer(withTimeInterval: timeToMidnight, repeats: false) { [weak self] _ in
                self?.performMidnightReset()
            }

            // 确保 timer 在所有 RunLoop 模式下都能运行
            if let timer = self.midnightCheckTimer {
                RunLoop.main.add(timer, forMode: .common)
            }
        }
        if Thread.isMainThread {
            doSchedule()
        } else {
            DispatchQueue.main.async(execute: doSchedule)
        }
    }

    private func performMidnightReset() {
        let now = Date()
        print("🌙 午夜重置触发：\(now)")

        var didReset = false
        statsStateLock.lock()
        if !Calendar.current.isDate(currentStats.date, inSameDayAs: now) {
            resetStatsLocked(for: now)
            didReset = true
        }
        statsStateLock.unlock()

        if didReset {
            updateNotificationBaselines()
            notifyMenuBarUpdate()
            notifyStatsUpdate()
        }

        scheduleNextMidnightReset()
    }
    
    func resetStats() {
        statsStateLock.lock()
        resetStatsLocked(for: Date())
        statsStateLock.unlock()
        updateNotificationBaselines()
        notifyMenuBarUpdate()
        notifyStatsUpdate()
    }

    /// 调用前必须持有 statsStateLock
    private func ensureCurrentDayLocked() {
        let now = Date()
        if !Calendar.current.isDate(currentStats.date, inSameDayAs: now) {
            resetStatsLocked(for: now)
        }
    }

    private func resetStats(for date: Date) {
        statsStateLock.lock()
        resetStatsLocked(for: date)
        statsStateLock.unlock()
        updateNotificationBaselines()
        notifyMenuBarUpdate()
        notifyStatsUpdate()
    }

    /// 调用前必须持有 statsStateLock — 原子重置 currentStats 和滑动窗口
    private func resetStatsLocked(for date: Date) {
        currentStats = DailyStats(date: date)
        recentKeyTimestamps.removeAll()
        recentClickTimestamps.removeAll()
        keyTimestampsHead = 0
        clickTimestampsHead = 0
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
        return normalizedKeyPressCounts(currentStats.keyPressCounts)
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
    struct KeyboardHeatmapDay {
        let date: Date
        let totalKeyPresses: Int
        let keyCounts: [String: Int]

        var maxCount: Int {
            keyCounts.values.max() ?? 0
        }
    }

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

    /// 键盘热力图可切换日期边界（按天连续切换）
    /// 起始日取「首次出现键盘数据」与今天之间的最早日期；若没有任何键盘数据则今天=起始日。
    func keyboardHeatmapDateBounds() -> (start: Date, end: Date) {
        assert(Thread.isMainThread)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        var earliestDate: Date?

        if currentStats.keyPresses > 0 || !currentStats.keyPressCounts.isEmpty {
            earliestDate = calendar.startOfDay(for: currentStats.date)
        }

        for daily in history.values {
            guard daily.keyPresses > 0 || !daily.keyPressCounts.isEmpty else { continue }
            let date = calendar.startOfDay(for: daily.date)
            if date > today { continue }
            if let existing = earliestDate {
                if date < existing {
                    earliestDate = date
                }
            } else {
                earliestDate = date
            }
        }

        let start = earliestDate ?? today
        return (start: min(start, today), end: today)
    }

    /// 按天获取键盘热力图数据。
    /// 组合键（如 Cmd+A）会拆分并分别累加到各个按键：Cmd +1、A +1。
    func keyboardHeatmapDay(for date: Date) -> KeyboardHeatmapDay {
        assert(Thread.isMainThread)
        let normalizedDate = Calendar.current.startOfDay(for: date)
        let daily = dailyStats(for: normalizedDate)
        let aggregated = aggregateKeyboardHeatmapCounts(from: daily.keyPressCounts)
        return KeyboardHeatmapDay(
            date: normalizedDate,
            totalKeyPresses: max(0, daily.keyPresses),
            keyCounts: aggregated
        )
    }

    private func aggregateKeyboardHeatmapCounts(from keyPressCounts: [String: Int]) -> [String: Int] {
        var aggregated: [String: Int] = [:]

        for (rawKey, rawCount) in keyPressCounts {
            let count = max(0, rawCount)
            guard count > 0 else { continue }

            let components = rawKey
                .split(separator: "+")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            let sourceKeys = components.isEmpty ? [rawKey] : components
            for sourceKey in sourceKeys {
                guard let normalizedKey = normalizedKeyboardHeatmapKey(sourceKey) else { continue }
                aggregated[normalizedKey] = safeAdd(aggregated[normalizedKey] ?? 0, count)
            }
        }

        return aggregated
    }

    private func normalizedKeyboardHeatmapKey(_ rawKey: String) -> String? {
        let trimmed = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let upper = trimmed.uppercased()
        if upper.count == 1 {
            return upper
        }

        if upper.hasPrefix("F"), Int(upper.dropFirst()) != nil {
            return upper
        }

        switch upper {
        case "CMD", "COMMAND", "⌘":
            return "Cmd"
        case "CTRL", "CONTROL", "⌃":
            return "Ctrl"
        case "OPTION", "OPT", "ALT", "⌥":
            return "Option"
        case "SHIFT", "⇧":
            return "Shift"
        case "FN", "FUNCTION", "🌐":
            return "Fn"
        case "SPACE", "SPACEBAR":
            return "Space"
        case "ESCAPE", "ESC", "⎋":
            return "Esc"
        case "RETURN", "↩":
            return "Return"
        case "ENTER", "⌅":
            return "Enter"
        case "BACKSPACE":
            return "Delete"
        case "DELETE", "⌫":
            return "Delete"
        case "FORWARDDELETE", "DEL", "⌦":
            return "ForwardDelete"
        case "INSERT", "INS", "HELP":
            return "Insert"
        case "PAGEUP":
            return "PageUp"
        case "PAGEDOWN":
            return "PageDown"
        case "HOME":
            return "Home"
        case "END":
            return "End"
        case "PRINTSCREEN", "PRTSC", "PRTSCN", "SNAPSHOT":
            return "PrintScreen"
        case "SCROLLLOCK", "SCROLL":
            return "ScrollLock"
        case "PAUSE", "BREAK":
            return "Pause"
        case "LEFT", "ARROWLEFT", "LEFTARROW":
            return "Left"
        case "RIGHT", "ARROWRIGHT", "RIGHTARROW":
            return "Right"
        case "UP", "ARROWUP", "UPARROW":
            return "Up"
        case "DOWN", "ARROWDOWN", "DOWNARROW":
            return "Down"
        default:
            return trimmed
        }
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
    
    func formatMouseDistance(_ distance: Double) -> String {
        let meters = distance * mouseDistanceMetersPerPixel
        if meters >= 1000 {
            return String(format: "%.2f km", meters / 1000)
        } else if distance >= 1000 {
            return String(format: "%.1f m", meters)
        }
        return String(format: "%.0f px", distance)
    }
    
    private func formatScrollDistance(_ distance: Double) -> String {
        if distance >= 1_000_000 {
            return String(format: "%.1f MPx", distance / 1_000_000)
        } else if distance >= 1000 {
            return String(format: "%.1f kPx", distance / 1000)
        } else {
            return String(format: "%.0f Px", distance)
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
        total.totalSideBackClicks += daily.sideBackClicks
        total.totalSideForwardClicks += daily.sideForwardClicks
        total.totalMouseDistance += daily.mouseDistance
        total.totalScrollDistance += daily.scrollDistance

        for (key, count) in normalizedKeyPressCounts(daily.keyPressCounts) {
            total.keyPressCounts[key, default: 0] += count
        }

        if daily.keyPresses > total.maxDailyKeyPresses {
            total.maxDailyKeyPresses = daily.keyPresses
            total.maxDailyKeyPressesDate = daily.date
        }
        let dailyClicks = daily.totalClicks
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
            total.sideBackClicks += appStats.sideBackClicks
            total.sideForwardClicks += appStats.sideForwardClicks
            total.scrollDistance += appStats.scrollDistance
            totals[bundleId] = total
        }
    }
}
