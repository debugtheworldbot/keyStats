import XCTest
@testable import KeyStatsCore

final class ActivityInsightsTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    /// 只在指定小时有按键的一天。
    private func day(keys: [Int: Int], clicks: [Int: Int] = [:]) -> HourlyDayCounts {
        var keyValues = Array(repeating: 0, count: 24)
        var clickValues = Array(repeating: 0, count: 24)
        for (hour, value) in keys { keyValues[hour] = value }
        for (hour, value) in clicks { clickValues[hour] = value }
        return HourlyDayCounts(keys: keyValues, clicks: clickValues)
    }

    private func input(_ date: Date, keys: Int = 0, clicks: Int = 0, distance: Double = 0, kps: Double = 0) -> AchievementDayInput {
        AchievementDayInput(date: date, keyPresses: keys, clicks: clicks, mouseDistance: distance, peakKPS: kps)
    }

    private func progress(_ id: String, in results: [AchievementProgress]) -> AchievementProgress {
        results.first { $0.definition.id == id }!
    }

    // MARK: - Hourly activity

    func testEmptyDaysHaveNoSummary() {
        let summary = HourlyActivityAnalyzer.analyze(days: [HourlyDayCounts(), HourlyDayCounts()], metric: .keyPresses)
        XCTAssertFalse(summary.hasData)
        XCTAssertEqual(summary.dayCount, 0)
        XCTAssertNil(summary.peakHour)
        XCTAssertNil(summary.nightRatio)
        XCTAssertNil(summary.chronotype)
    }

    func testInvalidLengthIsTreatedAsZero() {
        let counts = HourlyDayCounts(keys: [1, 2, 3], clicks: [])
        XCTAssertEqual(counts.keys, Array(repeating: 0, count: 24))
        XCTAssertFalse(counts.hasData)
    }

    func testDayWithOnlyClicksCountsTowardKeyAverage() {
        // 第二天只有点击，按键指标下仍计入天数
        let summary = HourlyActivityAnalyzer.analyze(days: [day(keys: [9: 100]), day(keys: [:], clicks: [9: 5])],
                                                     metric: .keyPresses)
        XCTAssertEqual(summary.dayCount, 2)
        XCTAssertEqual(summary.hourlyAverages[9], 50, accuracy: 0.0001)
        XCTAssertEqual(summary.peakHour, 9)
    }

    func testPeakHourTiePicksEarlierHour() {
        let summary = HourlyActivityAnalyzer.analyze(days: [day(keys: [8: 50, 15: 50])], metric: .keyPresses)
        XCTAssertEqual(summary.peakHour, 8)
    }

    func testNightRatioShownBelowMinimumButNoChronotype() {
        let summary = HourlyActivityAnalyzer.analyze(days: [day(keys: [23: 50, 14: 50])], metric: .keyPresses)
        XCTAssertEqual(summary.nightRatio ?? -1, 0.5, accuracy: 0.0001)
        XCTAssertNil(summary.chronotype)
    }

    func testNightOwlAtExactlyTwentyPercent() {
        let summary = HourlyActivityAnalyzer.analyze(days: [day(keys: [2: 40, 14: 160])], metric: .keyPresses)
        XCTAssertEqual(summary.chronotype, .nightOwl)
    }

    func testJustBelowTwentyPercentNightFallsBackToLargestBucket() {
        let summary = HourlyActivityAnalyzer.analyze(days: [day(keys: [2: 39, 14: 161])], metric: .keyPresses)
        XCTAssertEqual(summary.chronotype, .afternoonPerson)
    }

    func testEarlyBirdAndEveningPerson() {
        XCTAssertEqual(HourlyActivityAnalyzer.analyze(days: [day(keys: [7: 150, 13: 50])], metric: .keyPresses).chronotype,
                       .earlyBird)
        XCTAssertEqual(HourlyActivityAnalyzer.analyze(days: [day(keys: [19: 150, 13: 50])], metric: .keyPresses).chronotype,
                       .eveningPerson)
    }

    func testChronotypeTieChoosesEarlierBucket() {
        XCTAssertEqual(HourlyActivityAnalyzer.analyze(days: [day(keys: [8: 100, 14: 100])], metric: .keyPresses).chronotype,
                       .earlyBird)
        XCTAssertEqual(HourlyActivityAnalyzer.analyze(days: [day(keys: [14: 100, 20: 100])], metric: .keyPresses).chronotype,
                       .afternoonPerson)
    }

    func testClicksMetricUsesClickCounts() {
        let summary = HourlyActivityAnalyzer.analyze(days: [day(keys: [8: 500], clicks: [20: 300])], metric: .clicks)
        XCTAssertEqual(summary.total, 300)
        XCTAssertEqual(summary.chronotype, .eveningPerson)
    }

    func testHourlyStatsDailyHourCounts() {
        var stats = HourlyStats(startedAt: date(2026, 10, 20), timeZone: TimeZone(secondsFromGMT: 0)!)
        stats.record(keys: 3, at: date(2026, 10, 20, hour: 9))
        stats.record(clicks: 2, at: date(2026, 10, 21, hour: 23))
        let days = stats.dailyHourCounts(from: .distantPast, through: date(2026, 10, 22, hour: 12), now: date(2026, 10, 22, hour: 12))
        XCTAssertEqual(days.count, 3)
        XCTAssertEqual(days[0].keys[9], 3)
        XCTAssertEqual(days[1].clicks[23], 2)
        XCTAssertFalse(days[2].hasData)
    }

    // MARK: - Achievements

    func testCumulativeKeysRecordFirstUnlockDate() {
        let results = AchievementEvaluator.evaluate(days: [
            input(date(2026, 1, 1), keys: 60_000),
            input(date(2026, 1, 2), keys: 30_000),
            input(date(2026, 1, 3), keys: 20_000),
        ], metersPerPixel: 0.001, calendar: calendar)
        let keys100k = progress("keys_100k", in: results)
        XCTAssertEqual(keys100k.unlockedOn, date(2026, 1, 3))
        XCTAssertEqual(keys100k.current, 110_000, accuracy: 0.001)
        XCTAssertFalse(progress("keys_1m", in: results).isUnlocked)
        XCTAssertEqual(progress("keys_1m", in: results).fraction, 0.11, accuracy: 0.0001)
    }

    func testDailyKeysUsesSingleDayValue() {
        let results = AchievementEvaluator.evaluate(days: [
            input(date(2026, 1, 1), keys: 9_999),
            input(date(2026, 1, 2), keys: 9_999),
        ], metersPerPixel: 0, calendar: calendar)
        XCTAssertFalse(progress("day_10k", in: results).isUnlocked)
    }

    func testStreakBreaksOnGapAndKeepsLongest() {
        var days: [AchievementDayInput] = []
        for offset in 0..<7 {
            days.append(input(date(2026, 3, 1 + offset), keys: 10))
        }
        // 3 月 8 日空缺，之后只连续 3 天
        for offset in 0..<3 {
            days.append(input(date(2026, 3, 9 + offset), clicks: 1))
        }
        let results = AchievementEvaluator.evaluate(days: days, metersPerPixel: 0, calendar: calendar)
        XCTAssertEqual(progress("streak_7", in: results).unlockedOn, date(2026, 3, 7))
        XCTAssertEqual(progress("streak_30", in: results).current, 7, accuracy: 0.001)
        XCTAssertEqual(progress("active_100", in: results).current, 10, accuracy: 0.001)
    }

    func testInactiveDayEntryBreaksStreak() {
        let results = AchievementEvaluator.evaluate(days: [
            input(date(2026, 3, 1), keys: 1),
            input(date(2026, 3, 2)),
            input(date(2026, 3, 3), keys: 1),
        ], metersPerPixel: 0, calendar: calendar)
        XCTAssertEqual(progress("streak_7", in: results).current, 1, accuracy: 0.001)
    }

    func testMarathonUsesMetersPerPixel() {
        // 42,195 米 = 42,195,000 像素 × 0.001 米/像素
        let results = AchievementEvaluator.evaluate(days: [
            input(date(2026, 5, 1), keys: 1, distance: 20_000_000),
            input(date(2026, 5, 2), keys: 1, distance: 22_195_000),
        ], metersPerPixel: 0.001, calendar: calendar)
        let marathon = progress("marathon", in: results)
        XCTAssertEqual(marathon.unlockedOn, date(2026, 5, 2))
        XCTAssertEqual(marathon.current, 42.195, accuracy: 0.0001)
    }

    func testPeakKPSThresholds() {
        let results = AchievementEvaluator.evaluate(days: [
            input(date(2026, 6, 1), keys: 1, kps: 9),
            input(date(2026, 6, 2), keys: 1, kps: 12),
        ], metersPerPixel: 0, calendar: calendar)
        XCTAssertEqual(progress("kps_10", in: results).unlockedOn, date(2026, 6, 2))
        XCTAssertFalse(progress("kps_15", in: results).isUnlocked)
        XCTAssertEqual(progress("kps_15", in: results).current, 12, accuracy: 0.001)
    }

    func testCurrentStreakStartsFromYesterdayWhenTodayInactive() {
        let days = [
            input(date(2026, 7, 1), keys: 1),
            input(date(2026, 7, 2), keys: 1),
            input(date(2026, 7, 3)),
        ]
        XCTAssertEqual(AchievementEvaluator.currentStreak(days: days, today: date(2026, 7, 3, hour: 9), calendar: calendar), 2)
    }

    func testCatalogHasSixteenUniqueAchievements() {
        XCTAssertEqual(AchievementCatalog.all.count, 16)
        XCTAssertEqual(Set(AchievementCatalog.all.map(\.id)).count, 16)
    }
}
