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
