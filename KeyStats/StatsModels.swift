import Foundation

let baseMetersPerPixel: Double = 0.000264583

func baseKeyComponent(_ keyName: String) -> String {
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
    var sideBackClicks: Int
    var sideForwardClicks: Int
    var mouseDistance: Double
    var scrollDistance: Double
    var appStats: [String: AppStats]
    /// 今日峰值 KPS（trailing 1-second sliding-window count 的当日最大值）
    var peakKPS: Int
    /// 今日峰值 CPS（trailing 1-second sliding-window count 的当日最大值）
    var peakCPS: Int

    init() {
        self.date = Calendar.current.startOfDay(for: Date())
        self.keyPresses = 0
        self.keyPressCounts = [:]
        self.leftClicks = 0
        self.rightClicks = 0
        self.sideBackClicks = 0
        self.sideForwardClicks = 0
        self.mouseDistance = 0
        self.scrollDistance = 0
        self.appStats = [:]
        self.peakKPS = 0
        self.peakCPS = 0
    }

    init(date: Date) {
        self.date = Calendar.current.startOfDay(for: date)
        self.keyPresses = 0
        self.keyPressCounts = [:]
        self.leftClicks = 0
        self.rightClicks = 0
        self.sideBackClicks = 0
        self.sideForwardClicks = 0
        self.mouseDistance = 0
        self.scrollDistance = 0
        self.appStats = [:]
        self.peakKPS = 0
        self.peakCPS = 0
    }

    /// Decode peakKPS/peakCPS from either Int or Double (legacy format)
    private static func decodeIntOrDouble(container: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) -> Int {
        if let intVal = try? container.decodeIfPresent(Int.self, forKey: key) {
            return intVal
        }
        if let doubleVal = try? container.decodeIfPresent(Double.self, forKey: key) {
            return Int(doubleVal)
        }
        return 0
    }

    enum CodingKeys: String, CodingKey {
        case date
        case keyPresses
        case keyPressCounts
        case leftClicks
        case rightClicks
        case sideBackClicks
        case sideForwardClicks
        case otherClicks
        case mouseDistance
        case scrollDistance
        case appStats
        case peakKPS
        case peakCPS
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = try container.decodeIfPresent(Date.self, forKey: .date) ?? Calendar.current.startOfDay(for: Date())
        keyPresses = try container.decodeIfPresent(Int.self, forKey: .keyPresses) ?? 0
        keyPressCounts = try container.decodeIfPresent([String: Int].self, forKey: .keyPressCounts) ?? [:]
        leftClicks = try container.decodeIfPresent(Int.self, forKey: .leftClicks) ?? 0
        rightClicks = try container.decodeIfPresent(Int.self, forKey: .rightClicks) ?? 0
        sideBackClicks = try container.decodeIfPresent(Int.self, forKey: .sideBackClicks) ?? 0
        sideForwardClicks = try container.decodeIfPresent(Int.self, forKey: .sideForwardClicks) ?? 0
        if !container.contains(.sideBackClicks) && !container.contains(.sideForwardClicks) {
            sideBackClicks = try container.decodeIfPresent(Int.self, forKey: .otherClicks) ?? 0
        }
        mouseDistance = try container.decodeIfPresent(Double.self, forKey: .mouseDistance) ?? 0
        scrollDistance = try container.decodeIfPresent(Double.self, forKey: .scrollDistance) ?? 0
        appStats = try container.decodeIfPresent([String: AppStats].self, forKey: .appStats) ?? [:]
        peakKPS = Self.decodeIntOrDouble(container: container, key: .peakKPS)
        peakCPS = Self.decodeIntOrDouble(container: container, key: .peakCPS)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(date, forKey: .date)
        try container.encode(keyPresses, forKey: .keyPresses)
        try container.encode(keyPressCounts, forKey: .keyPressCounts)
        try container.encode(leftClicks, forKey: .leftClicks)
        try container.encode(rightClicks, forKey: .rightClicks)
        try container.encode(sideBackClicks, forKey: .sideBackClicks)
        try container.encode(sideForwardClicks, forKey: .sideForwardClicks)
        try container.encode(mouseDistance, forKey: .mouseDistance)
        try container.encode(scrollDistance, forKey: .scrollDistance)
        try container.encode(appStats, forKey: .appStats)
        try container.encode(peakKPS, forKey: .peakKPS)
        try container.encode(peakCPS, forKey: .peakCPS)
    }

    var totalClicks: Int {
        leftClicks + rightClicks + sideBackClicks + sideForwardClicks
    }

    var hasAnyActivity: Bool {
        keyPresses > 0 ||
            leftClicks > 0 ||
            rightClicks > 0 ||
            sideBackClicks > 0 ||
            sideForwardClicks > 0 ||
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
}

/// 有史以来统计数据结构
struct AllTimeStats {
    var totalKeyPresses: Int
    var totalLeftClicks: Int
    var totalRightClicks: Int
    var totalSideBackClicks: Int
    var totalSideForwardClicks: Int
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
        totalLeftClicks + totalRightClicks + totalSideBackClicks + totalSideForwardClicks
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

    static func initial() -> AllTimeStats {
        AllTimeStats(
            totalKeyPresses: 0,
            totalLeftClicks: 0,
            totalRightClicks: 0,
            totalSideBackClicks: 0,
            totalSideForwardClicks: 0,
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
