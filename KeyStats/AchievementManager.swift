import Foundation

extension Notification.Name {
    static let achievementsDidChange = Notification.Name("KeyStatsAchievementsDidChange")
}

/// 成就名称与描述文案，界面和通知共用。
enum AchievementText {
    static func name(for definition: AchievementDefinition) -> String {
        NSLocalizedString("achievement.name.\(definition.id)", comment: "")
    }

    static func description(for definition: AchievementDefinition) -> String {
        let format = NSLocalizedString("achievement.desc.\(definition.category.rawValue)", comment: "")
        return String(format: format, formattedValue(definition.target, category: definition.category))
    }

    /// 数值按类别格式化：公里保留最多 3 位小数，其余取整并加千分位。
    static func formattedValue(_ value: Double, category: AchievementCategory) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
        if category == .mouseDistance {
            formatter.minimumFractionDigits = 0
            formatter.maximumFractionDigits = 3
        } else {
            formatter.maximumFractionDigits = 0
        }
        let safeValue = value.isFinite ? value : 0
        let display = category == .mouseDistance ? safeValue : safeValue.rounded(.down)
        return formatter.string(from: NSNumber(value: display)) ?? "\(display)"
    }
}

/// 成就评估、解锁记录持久化与解锁通知。
/// 启动后评估一次，之后每 60 秒评估一次；首次评估时静默补记已达成的成就，不发通知。
final class AchievementManager {
    static let shared = AchievementManager()

    private let userDefaults = UserDefaults.standard
    private let unlockedKey = "unlockedAchievements"
    private let initializedKey = "achievementsInitialized"
    private let notificationsEnabledKey = "achievementNotificationsEnabled"
    private let evaluationInterval: TimeInterval = 60
    private var timer: Timer?

    private let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private init() {}

    /// 成就解锁通知开关，默认开启。
    var notificationsEnabled: Bool {
        get { userDefaults.object(forKey: notificationsEnabledKey) as? Bool ?? true }
        set { userDefaults.set(newValue, forKey: notificationsEnabledKey) }
    }

    /// 已记录的解锁日期（id → yyyy-MM-dd）。
    var unlockedDates: [String: Date] {
        let stored = userDefaults.dictionary(forKey: unlockedKey) as? [String: String] ?? [:]
        return stored.compactMapValues { dayFormatter.date(from: $0) }
    }

    /// 必须在主线程调用（Timer 挂在主 run loop）。
    func start() {
        guard timer == nil else { return }
        evaluateNow()
        let timer = Timer(timeInterval: evaluationInterval, repeats: true) { [weak self] _ in
            self?.evaluateNow()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// 本机历史 + 今天（不含其他同步设备）。
    func dayInputs() -> [AchievementDayInput] {
        StatsManager.shared.localSyncHistorySnapshot().values.map { stats in
            AchievementDayInput(date: stats.date,
                                keyPresses: stats.keyPresses,
                                clicks: stats.totalClicks,
                                mouseDistance: stats.mouseDistance,
                                peakKPS: Double(stats.peakKPS))
        }
    }

    func currentProgress(days: [AchievementDayInput]? = nil) -> [AchievementProgress] {
        AchievementEvaluator.evaluate(days: days ?? dayInputs(),
                                      metersPerPixel: StatsManager.shared.mouseDistanceMetersPerPixel)
    }

    @discardableResult
    func evaluateNow() -> [AchievementProgress] {
        let progress = currentProgress()
        var stored = userDefaults.dictionary(forKey: unlockedKey) as? [String: String] ?? [:]
        let isInitialized = userDefaults.bool(forKey: initializedKey)

        var newlyUnlocked: [AchievementProgress] = []
        for item in progress {
            guard let unlockedOn = item.unlockedOn, stored[item.definition.id] == nil else { continue }
            stored[item.definition.id] = dayFormatter.string(from: unlockedOn)
            newlyUnlocked.append(item)
        }

        if !newlyUnlocked.isEmpty {
            userDefaults.set(stored, forKey: unlockedKey)
            NotificationCenter.default.post(name: .achievementsDidChange, object: nil)
        }

        if !isInitialized {
            // 首次启用：已达成的成就静默补记，避免一口气弹一堆通知
            userDefaults.set(true, forKey: initializedKey)
        } else if notificationsEnabled {
            for item in newlyUnlocked {
                let title = String(format: NSLocalizedString("achievement.notification.titleFormat", comment: ""),
                                   AchievementText.name(for: item.definition))
                NotificationManager.shared.sendAchievementNotification(identifier: item.definition.id,
                                                                       title: title,
                                                                       body: AchievementText.description(for: item.definition))
            }
        }
        return progress
    }
}
