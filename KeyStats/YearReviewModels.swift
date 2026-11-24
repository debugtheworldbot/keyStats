import Foundation

// MARK: - 键盘人格

enum KeyboardPersonaKind: String, CaseIterable {
    case shortcutMaster
    case copyPasteEngineer
    case perfectionist
    case arrowKeyWalker
    case mousePerson
    case keyboardPurist
    case balancedPlayer
}

struct KeyboardPersonaKeyCount: Equatable {
    let name: String
    let count: Int
}

struct KeyboardPersonaResult: Equatable {
    let totalKeyPresses: Int
    let totalClicks: Int
    let shortcutCount: Int
    let regretCount: Int
    let copyCount: Int
    let pasteCount: Int
    let undoCount: Int
    let arrowCount: Int
    let topKeys: [KeyboardPersonaKeyCount]
    /// 主称号；总按键不足 `KeyboardPersonaAnalyzer.minimumKeyPresses` 时为 nil。
    let primary: KeyboardPersonaKind?
    /// 其余命中的称号，按优先级排列。
    let secondary: [KeyboardPersonaKind]

    var hasEnoughData: Bool { primary != nil }
    var shortcutRatio: Double { ratio(shortcutCount) }
    var regretRatio: Double { ratio(regretCount) }
    var arrowRatio: Double { ratio(arrowCount) }

    /// 每次按键对应的点击次数；没有按键时为 0。
    var clicksPerKeyPress: Double {
        guard totalKeyPresses > 0 else { return 0 }
        return Double(totalClicks) / Double(totalKeyPresses)
    }

    private func ratio(_ count: Int) -> Double {
        guard totalKeyPresses > 0 else { return 0 }
        return Double(count) / Double(totalKeyPresses)
    }
}

/// 根据按键分布推断「键盘人格」。纯函数，不依赖 UI，Windows 端使用同一套阈值。
enum KeyboardPersonaAnalyzer {
    static let minimumKeyPresses = 200
    static let topKeyLimit = 3

    private static let shortcutModifiers: Set<String> = ["Cmd", "Ctrl", "Option"]
    private static let regretKeys: Set<String> = ["Delete", "ForwardDelete"]
    private static let arrowKeys: Set<String> = ["Up", "Down", "Left", "Right"]
    private static let modifierDisplayOrder = ["Cmd", "Ctrl", "Option", "Shift", "Fn"]

    static func analyze(keyCounts: [String: Int], totalKeyPresses: Int, totalClicks: Int) -> KeyboardPersonaResult {
        var shortcutCount = 0
        var regretCount = 0
        var copyCount = 0
        var pasteCount = 0
        var undoCount = 0
        var arrowCount = 0
        var mergedCounts: [String: Int] = [:]

        for (rawName, rawCount) in keyCounts {
            let count = max(0, rawCount)
            guard count > 0 else { continue }
            let parsed = parseKeyName(rawName)
            guard !parsed.base.isEmpty else { continue }

            if !parsed.modifiers.isDisjoint(with: shortcutModifiers) {
                shortcutCount += count
            }
            if regretKeys.contains(parsed.base) {
                regretCount += count
            }
            if arrowKeys.contains(parsed.base) {
                arrowCount += count
            }
            if parsed.modifiers == ["Cmd"] {
                switch parsed.base.uppercased() {
                case "C": copyCount += count
                case "V": pasteCount += count
                case "Z": undoCount += count
                default: break
                }
            }
            mergedCounts[parsed.displayName, default: 0] += count
        }

        let topKeys = mergedCounts
            .filter { $0.key != "Space" }
            .sorted { lhs, rhs in
                lhs.value != rhs.value ? lhs.value > rhs.value : lhs.key < rhs.key
            }
            .prefix(topKeyLimit)
            .map { KeyboardPersonaKeyCount(name: $0.key, count: $0.value) }

        let keys = max(0, totalKeyPresses)
        let clicks = max(0, totalClicks)
        var matched: [KeyboardPersonaKind] = []
        if keys >= minimumKeyPresses {
            // 用整数比较阈值，避免浮点误差导致恰好卡在阈值上时判定不一致
            if shortcutCount * 100 >= keys * 12 { matched.append(.shortcutMaster) }
            if pasteCount >= 30 && pasteCount >= copyCount * 2 { matched.append(.copyPasteEngineer) }
            if regretCount * 10 >= keys { matched.append(.perfectionist) }
            if arrowCount * 100 >= keys * 8 { matched.append(.arrowKeyWalker) }
            if clicks >= keys { matched.append(.mousePerson) }
            if clicks * 100 <= keys * 15 { matched.append(.keyboardPurist) }
            if matched.isEmpty { matched.append(.balancedPlayer) }
        }

        return KeyboardPersonaResult(
            totalKeyPresses: keys,
            totalClicks: clicks,
            shortcutCount: shortcutCount,
            regretCount: regretCount,
            copyCount: copyCount,
            pasteCount: pasteCount,
            undoCount: undoCount,
            arrowCount: arrowCount,
            topKeys: Array(topKeys),
            primary: matched.first,
            secondary: Array(matched.dropFirst())
        )
    }

    /// 拆出修饰键与基础键。左右修饰键统一归一，例如 "LeftCmd+C" → (["Cmd"], "C")。
    static func parseKeyName(_ keyName: String) -> (modifiers: Set<String>, base: String, displayName: String) {
        let trimmed = keyName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ([], "", "") }
        if trimmed == "+" { return ([], "+", "+") }

        var body = trimmed
        var literalPlus = false
        if body.hasSuffix("++") {
            // "Cmd++" 表示基础键就是 "+"
            body = String(body.dropLast(2))
            literalPlus = true
        }

        var parts = body
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if literalPlus {
            parts.append("+")
        }
        guard let base = parts.last else { return ([], "", "") }

        let modifiers = Set(parts.dropLast().map(normalizedModifier))
        let orderedModifiers = modifierDisplayOrder.filter { modifiers.contains($0) }
            + modifiers.subtracting(modifierDisplayOrder).sorted()
        let displayName = (orderedModifiers + [base]).joined(separator: "+")
        return (modifiers, base, displayName)
    }

    private static func normalizedModifier(_ token: String) -> String {
        switch token {
        case "Cmd", "LeftCmd", "RightCmd", "Command":
            return "Cmd"
        case "Ctrl", "Control", "LeftCtrl", "RightCtrl":
            return "Ctrl"
        case "Option", "LeftOption", "RightOption", "Alt":
            return "Option"
        case "Shift", "LeftShift", "RightShift":
            return "Shift"
        default:
            return token
        }
    }
}

// MARK: - 年度贡献墙

enum ContributionWallRange: Equatable {
    case last12Months
    case year(Int)

    var analyticsValue: String {
        switch self {
        case .last12Months:
            return "last_12_months"
        case .year(let year):
            return String(year)
        }
    }
}

struct ContributionWallDay: Equatable {
    let date: Date
    /// 第几周（从 0 开始）
    let column: Int
    /// 周一为 0，周日为 6
    let row: Int
    let value: Int
}

struct ContributionWallMonthLabel: Equatable {
    let column: Int
    /// 1~12
    let month: Int
}

struct ContributionWallBestDay: Equatable {
    let date: Date
    let value: Int
}

struct ContributionWallModel: Equatable {
    let range: ContributionWallRange
    let columnCount: Int
    let days: [ContributionWallDay]
    let monthLabels: [ContributionWallMonthLabel]
    let maxValue: Int
    /// 视图内所有大于 0 的值的第 25 / 50 / 75 百分位，用于 GitHub 式分档
    let quartiles: (q1: Int, q2: Int, q3: Int)
    let total: Int
    let activeDays: Int
    /// 视图不包含今天时为 nil
    let currentStreak: Int?
    let longestStreak: Int
    let bestDay: ContributionWallBestDay?

    /// GitHub 式四分位分档：0 → 0（底色），其余落在 0.25 / 0.5 / 0.75 / 1.0 四档。
    func intensity(for value: Int) -> Double {
        guard value > 0 else { return 0 }
        if value <= quartiles.q1 { return 0.25 }
        if value <= quartiles.q2 { return 0.5 }
        if value <= quartiles.q3 { return 0.75 }
        return 1.0
    }

    static func == (lhs: ContributionWallModel, rhs: ContributionWallModel) -> Bool {
        lhs.range == rhs.range
            && lhs.columnCount == rhs.columnCount
            && lhs.days == rhs.days
            && lhs.monthLabels == rhs.monthLabels
            && lhs.maxValue == rhs.maxValue
            && lhs.quartiles == rhs.quartiles
            && lhs.total == rhs.total
            && lhs.activeDays == rhs.activeDays
            && lhs.currentStreak == rhs.currentStreak
            && lhs.longestStreak == rhs.longestStreak
            && lhs.bestDay == rhs.bestDay
    }
}

enum ContributionWallBuilder {
    /// 「过去 12 个月」+ 从今年到历史最早年份的各自然年（倒序）。
    static func availableRanges(earliestDate: Date?, today: Date, calendar: Calendar = .current) -> [ContributionWallRange] {
        let currentYear = calendar.component(.year, from: today)
        let earliestYear = earliestDate.map { min(calendar.component(.year, from: $0), currentYear) } ?? currentYear
        let years = stride(from: currentYear, through: earliestYear, by: -1).map { ContributionWallRange.year($0) }
        return [.last12Months] + years
    }

    static func build(range: ContributionWallRange,
                      today: Date,
                      calendar: Calendar = .current,
                      value: (Date) -> Int) -> ContributionWallModel {
        let todayStart = calendar.startOfDay(for: today)
        let gridStart: Date
        let firstVisible: Date
        let lastVisible: Date
        let columnCount: Int

        switch range {
        case .last12Months:
            gridStart = addDays(-52 * 7, to: mondayOnOrBefore(todayStart, calendar: calendar), calendar: calendar)
            firstVisible = gridStart
            lastVisible = todayStart
            columnCount = 53
        case .year(let year):
            let jan1 = calendar.date(from: DateComponents(year: year, month: 1, day: 1)) ?? todayStart
            let dec31 = calendar.date(from: DateComponents(year: year, month: 12, day: 31)) ?? todayStart
            gridStart = mondayOnOrBefore(jan1, calendar: calendar)
            firstVisible = jan1
            lastVisible = min(dec31, todayStart)
            columnCount = daysBetween(gridStart, mondayOnOrBefore(dec31, calendar: calendar), calendar: calendar) / 7 + 1
        }

        var days: [ContributionWallDay] = []
        var date = firstVisible
        while date <= lastVisible {
            let index = daysBetween(gridStart, date, calendar: calendar)
            days.append(ContributionWallDay(date: date,
                                            column: index / 7,
                                            row: index % 7,
                                            value: max(0, value(date))))
            date = addDays(1, to: date, calendar: calendar)
        }

        var monthLabels: [ContributionWallMonthLabel] = []
        var lastLabeledColumn = -1
        var lastMonth = 0
        for day in days where day.column != lastLabeledColumn {
            // 每列只看最上面一天：该月第一次出现的列打标签
            lastLabeledColumn = day.column
            let month = calendar.component(.month, from: day.date)
            if month != lastMonth {
                monthLabels.append(ContributionWallMonthLabel(column: day.column, month: month))
                lastMonth = month
            }
        }

        var total = 0
        var activeDays = 0
        var longestStreak = 0
        var runningStreak = 0
        var bestDay: ContributionWallBestDay?
        for day in days {
            total += day.value
            if day.value > 0 {
                activeDays += 1
                runningStreak += 1
                longestStreak = max(longestStreak, runningStreak)
            } else {
                runningStreak = 0
            }
            if day.value > (bestDay?.value ?? 0) {
                bestDay = ContributionWallBestDay(date: day.date, value: day.value)
            }
        }

        let sortedPositive = days.map(\.value).filter { $0 > 0 }.sorted()
        let quartiles = (q1: percentile(sortedPositive, 0.25),
                         q2: percentile(sortedPositive, 0.50),
                         q3: percentile(sortedPositive, 0.75))

        var currentStreak: Int?
        if todayStart >= firstVisible && todayStart <= lastVisible {
            currentStreak = streakEnding(at: todayStart, calendar: calendar, value: value)
        }

        return ContributionWallModel(range: range,
                                     columnCount: columnCount,
                                     days: days,
                                     monthLabels: monthLabels,
                                     maxValue: bestDay?.value ?? 0,
                                     quartiles: quartiles,
                                     total: total,
                                     activeDays: activeDays,
                                     currentStreak: currentStreak,
                                     longestStreak: longestStreak,
                                     bestDay: bestDay)
    }

    /// 从今天往回数连续有数据的天数；今天还是 0 时从昨天开始数（不受视图范围限制）。
    static func streakEnding(at today: Date, calendar: Calendar = .current, value: (Date) -> Int) -> Int {
        var date = calendar.startOfDay(for: today)
        if value(date) <= 0 {
            date = addDays(-1, to: date, calendar: calendar)
        }
        var streak = 0
        // 上限约 30 年，防止异常数据导致死循环
        while streak < 11_000 && value(date) > 0 {
            streak += 1
            date = addDays(-1, to: date, calendar: calendar)
        }
        return streak
    }

    /// 升序数组的百分位：取下标 (n-1)*p 向下取整的元素；空数组返回 0。
    static func percentile(_ sortedValues: [Int], _ p: Double) -> Int {
        guard !sortedValues.isEmpty else { return 0 }
        let index = Int(Double(sortedValues.count - 1) * p)
        return sortedValues[max(0, min(sortedValues.count - 1, index))]
    }

    static func mondayOnOrBefore(_ date: Date, calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: date)
        // weekday：1 = 周日 … 7 = 周六；换算成周一为 0
        let offset = (calendar.component(.weekday, from: start) + 5) % 7
        return addDays(-offset, to: start, calendar: calendar)
    }

    private static func addDays(_ days: Int, to date: Date, calendar: Calendar) -> Date {
        let shifted = calendar.date(byAdding: .day, value: days, to: date) ?? date.addingTimeInterval(TimeInterval(days) * 86_400)
        return calendar.startOfDay(for: shifted)
    }

    private static func daysBetween(_ from: Date, _ to: Date, calendar: Calendar) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: from), to: calendar.startOfDay(for: to)).day ?? 0
    }
}

// MARK: - 活跃时段

enum HourlyActivityMetric {
    case keyPresses
    case clicks
}

/// 某一天按本地钟点汇总的 24 格计数（下标 = 小时）。
struct HourlyDayCounts: Equatable {
    var keys: [Int]
    var clicks: [Int]

    init(keys: [Int] = Array(repeating: 0, count: 24), clicks: [Int] = Array(repeating: 0, count: 24)) {
        self.keys = HourlyDayCounts.normalized(keys)
        self.clicks = HourlyDayCounts.normalized(clicks)
    }

    /// 按键与点击两项合计 > 0 才算「有小时数据」的一天（与当前指标无关）。
    var hasData: Bool {
        saturatingNonnegativeSum(keys + clicks) > 0
    }

    func values(for metric: HourlyActivityMetric) -> [Int] {
        metric == .keyPresses ? keys : clicks
    }

    /// 长度不是 24 时视为全 0；负数按 0 处理。
    static func normalized(_ values: [Int]) -> [Int] {
        guard values.count == 24 else { return Array(repeating: 0, count: 24) }
        return values.map { max(0, $0) }
    }
}

enum Chronotype: String, CaseIterable {
    case nightOwl
    case earlyBird
    case afternoonPerson
    case eveningPerson
}

struct HourlyActivitySummary: Equatable {
    /// 参与统计的天数（有小时数据的天，即使当前指标全 0 也计入）。
    let dayCount: Int
    /// 当前指标的逐小时之和。
    let hourlyTotals: [Int]
    /// 逐小时日均 = 逐小时之和 / dayCount。
    let hourlyAverages: [Double]
    let total: Int
    /// 逐小时之和最大的小时（并列取更早的）；全 0 时为 nil。
    let peakHour: Int?
    /// 22:00–05:00 的占比；总量为 0 时为 nil。
    let nightRatio: Double?
    /// 作息类型；总量 < `HourlyActivityAnalyzer.minimumTotal` 时为 nil。
    let chronotype: Chronotype?

    var hasData: Bool { dayCount > 0 }
}

/// 根据逐小时数据推断作息类型。纯函数，Windows 端使用同一套规则。
enum HourlyActivityAnalyzer {
    static let minimumTotal = 200
    static let nightHours: [Int] = [22, 23, 0, 1, 2, 3, 4]
    static let morningHours = 5...10
    static let afternoonHours = 11...17
    static let eveningHours = 18...21

    static func analyze(days: [HourlyDayCounts], metric: HourlyActivityMetric) -> HourlyActivitySummary {
        let included = days.filter { $0.hasData }
        var totals = Array(repeating: 0, count: 24)
        for day in included {
            let values = day.values(for: metric)
            for hour in 0..<24 {
                totals[hour] = saturatingNonnegativeSum([totals[hour], values[hour]])
            }
        }

        let total = saturatingNonnegativeSum(totals)
        let averages = included.isEmpty
            ? Array(repeating: 0.0, count: 24)
            : totals.map { Double($0) / Double(included.count) }

        var peakHour: Int?
        if total > 0, let maxValue = totals.max() {
            peakHour = totals.firstIndex(of: maxValue)
        }

        let nightTotal = saturatingNonnegativeSum(nightHours.map { totals[$0] })
        let nightRatio: Double? = total > 0 ? Double(nightTotal) / Double(total) : nil

        return HourlyActivitySummary(dayCount: included.count,
                                     hourlyTotals: totals,
                                     hourlyAverages: averages,
                                     total: total,
                                     peakHour: peakHour,
                                     nightRatio: nightRatio,
                                     chronotype: chronotype(totals: totals, total: total, nightTotal: nightTotal))
    }

    private static func chronotype(totals: [Int], total: Int, nightTotal: Int) -> Chronotype? {
        guard total >= minimumTotal else { return nil }
        // 整数比较，避免恰好 20% 时的浮点误差
        if nightTotal * 5 >= total {
            return .nightOwl
        }
        let morning = saturatingNonnegativeSum(morningHours.map { totals[$0] })
        let afternoon = saturatingNonnegativeSum(afternoonHours.map { totals[$0] })
        let evening = saturatingNonnegativeSum(eveningHours.map { totals[$0] })
        // 并列取更早的时段
        if morning >= afternoon && morning >= evening {
            return .earlyBird
        }
        return afternoon >= evening ? .afternoonPerson : .eveningPerson
    }
}

extension HourlyStats {
    /// 按记录时区把 [start, end] 内每天拆成 24 格；早于开始记录的日子不返回。
    /// DST 重复的钟点合并到同一格。
    func dailyHourCounts(from start: Date, through end: Date, now: Date = Date()) -> [HourlyDayCounts] {
        let recordingCalendar = calendar
        let last = min(end, now)
        var cursor = recordingCalendar.startOfDay(for: max(start, startedAt))
        var result: [HourlyDayCounts] = []
        // 上限约 30 年，防止异常数据导致死循环
        while cursor <= last && result.count < 11_000 {
            var day = HourlyDayCounts()
            for point in points(on: cursor, recent24Hours: false, now: now) {
                guard let counts = point.counts else { continue }
                let hour = recordingCalendar.component(.hour, from: point.date)
                guard (0..<24).contains(hour) else { continue }
                day.keys[hour] = saturatingNonnegativeSum([day.keys[hour], counts.keys])
                day.clicks[hour] = saturatingNonnegativeSum([day.clicks[hour], counts.clicks])
            }
            result.append(day)
            guard let next = recordingCalendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = recordingCalendar.startOfDay(for: next)
        }
        return result
    }
}

// MARK: - 成就

enum AchievementCategory: String, CaseIterable {
    case totalKeys
    case dailyKeys
    case totalClicks
    case streak
    case activeDays
    case peakKPS
    case mouseDistance
}

struct AchievementDefinition: Equatable {
    let id: String
    let category: AchievementCategory
    /// 目标值；鼠标距离单位为公里，其余为次数 / 天数 / 键每秒。
    let target: Double
}

enum AchievementCatalog {
    static let marathonKilometers = 42.195

    static let all: [AchievementDefinition] = [
        AchievementDefinition(id: "keys_100k", category: .totalKeys, target: 100_000),
        AchievementDefinition(id: "keys_1m", category: .totalKeys, target: 1_000_000),
        AchievementDefinition(id: "keys_10m", category: .totalKeys, target: 10_000_000),
        AchievementDefinition(id: "day_10k", category: .dailyKeys, target: 10_000),
        AchievementDefinition(id: "day_30k", category: .dailyKeys, target: 30_000),
        AchievementDefinition(id: "day_50k", category: .dailyKeys, target: 50_000),
        AchievementDefinition(id: "clicks_100k", category: .totalClicks, target: 100_000),
        AchievementDefinition(id: "clicks_1m", category: .totalClicks, target: 1_000_000),
        AchievementDefinition(id: "streak_7", category: .streak, target: 7),
        AchievementDefinition(id: "streak_30", category: .streak, target: 30),
        AchievementDefinition(id: "streak_100", category: .streak, target: 100),
        AchievementDefinition(id: "active_100", category: .activeDays, target: 100),
        AchievementDefinition(id: "active_365", category: .activeDays, target: 365),
        AchievementDefinition(id: "kps_10", category: .peakKPS, target: 10),
        AchievementDefinition(id: "kps_15", category: .peakKPS, target: 15),
        AchievementDefinition(id: "marathon", category: .mouseDistance, target: marathonKilometers),
    ]
}

/// 成就评估所需的单日数据。
struct AchievementDayInput: Equatable {
    let date: Date
    let keyPresses: Int
    let clicks: Int
    /// 像素距离，换算公里时乘以「米/像素」校准值。
    let mouseDistance: Double
    let peakKPS: Double

    var isActive: Bool { keyPresses > 0 || clicks > 0 }
}

struct AchievementProgress: Equatable {
    let definition: AchievementDefinition
    /// 当前进度：累计类为总和，单日/峰值类为历史最大值，连续为最长连续天数。
    let current: Double
    /// 首次达成的日期；未达成为 nil。
    let unlockedOn: Date?

    var isUnlocked: Bool { unlockedOn != nil }

    var fraction: Double {
        guard definition.target > 0 else { return 0 }
        return min(1, max(0, current / definition.target))
    }
}

/// 按时间顺序扫描每日数据，计算每个成就的进度和首次达成日期。纯函数，Windows 端规则一致。
enum AchievementEvaluator {
    static func evaluate(days: [AchievementDayInput],
                         metersPerPixel: Double,
                         definitions: [AchievementDefinition] = AchievementCatalog.all,
                         calendar: Calendar = .current) -> [AchievementProgress] {
        let sorted = days.sorted { $0.date < $1.date }
        var totalKeys = 0.0
        var totalClicks = 0.0
        var totalKilometers = 0.0
        var activeDays = 0.0
        var maxDailyKeys = 0.0
        var maxKPS = 0.0
        var currentStreak = 0
        var longestStreak = 0
        var lastActiveDay: Date?
        var unlocked: [String: Date] = [:]
        let safeMetersPerPixel = metersPerPixel.isFinite && metersPerPixel > 0 ? metersPerPixel : 0

        func value(for category: AchievementCategory) -> Double {
            switch category {
            case .totalKeys: return totalKeys
            case .dailyKeys: return maxDailyKeys
            case .totalClicks: return totalClicks
            case .streak: return Double(longestStreak)
            case .activeDays: return activeDays
            case .peakKPS: return maxKPS
            case .mouseDistance: return totalKilometers
            }
        }

        for day in sorted {
            let dayStart = calendar.startOfDay(for: day.date)
            totalKeys += Double(max(0, day.keyPresses))
            totalClicks += Double(max(0, day.clicks))
            maxDailyKeys = max(maxDailyKeys, Double(max(0, day.keyPresses)))
            if day.peakKPS.isFinite {
                maxKPS = max(maxKPS, day.peakKPS)
            }
            if day.mouseDistance.isFinite && day.mouseDistance > 0 {
                totalKilometers += day.mouseDistance * safeMetersPerPixel / 1000
            }

            if day.isActive {
                if let last = lastActiveDay {
                    let gap = daysBetween(last, dayStart, calendar: calendar)
                    if gap == 1 {
                        currentStreak += 1
                    } else if gap > 1 {
                        // 中间断了一天以上，重新计数
                        currentStreak = 1
                    }
                    // gap == 0：同一天重复的数据，不重复计数
                    if gap != 0 {
                        activeDays += 1
                    }
                } else {
                    currentStreak = 1
                    activeDays += 1
                }
                lastActiveDay = dayStart
                longestStreak = max(longestStreak, currentStreak)
            }

            for definition in definitions where unlocked[definition.id] == nil {
                // 公里数是浮点累加，留一点容差，避免恰好达标时因舍入误差漏判
                if value(for: definition.category) >= definition.target - 1e-9 {
                    unlocked[definition.id] = dayStart
                }
            }
        }

        return definitions.map { definition in
            AchievementProgress(definition: definition,
                                current: value(for: definition.category),
                                unlockedOn: unlocked[definition.id])
        }
    }

    /// 当前连续活跃天数：从今天往回数，今天还没活跃时从昨天开始数。
    static func currentStreak(days: [AchievementDayInput], today: Date, calendar: Calendar = .current) -> Int {
        let activeDays = Set(days.filter { $0.isActive }.map { calendar.startOfDay(for: $0.date) })
        return ContributionWallBuilder.streakEnding(at: today, calendar: calendar) { date in
            activeDays.contains(calendar.startOfDay(for: date)) ? 1 : 0
        }
    }

    private static func daysBetween(_ from: Date, _ to: Date, calendar: Calendar) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: from), to: calendar.startOfDay(for: to)).day ?? 0
    }
}
