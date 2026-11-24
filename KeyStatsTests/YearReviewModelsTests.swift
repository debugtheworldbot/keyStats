import XCTest
@testable import KeyStatsCore

final class YearReviewModelsTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func analyze(_ counts: [String: Int], keys: Int = 1000, clicks: Int = 300) -> KeyboardPersonaResult {
        KeyboardPersonaAnalyzer.analyze(keyCounts: counts, totalKeyPresses: keys, totalClicks: clicks)
    }

    // MARK: - Keyboard persona

    func testNotEnoughDataBelowMinimumKeyPresses() {
        let result = analyze(["Cmd+C": 100], keys: 199)
        XCTAssertNil(result.primary)
        XCTAssertEqual(result.secondary, [])
        XCTAssertFalse(result.hasEnoughData)
    }

    func testShortcutMasterAtExactThresholdWithNormalizedModifiers() {
        let result = analyze(["LeftCmd+C": 60, "Cmd+V": 60])
        XCTAssertEqual(result.shortcutCount, 120)
        XCTAssertEqual(result.copyCount, 60)
        XCTAssertEqual(result.pasteCount, 60)
        XCTAssertEqual(result.primary, .shortcutMaster)
        XCTAssertEqual(result.secondary, [])
    }

    func testShortcutJustBelowThresholdFallsBackToBalanced() {
        let result = analyze(["Cmd+S": 119])
        XCTAssertEqual(result.primary, .balancedPlayer)
    }

    func testShiftOnlyCombosAreNotShortcuts() {
        let result = analyze(["Shift+A": 500])
        XCTAssertEqual(result.shortcutCount, 0)
    }

    func testCopyPasteEngineerNeedsThirtyPastesAndTwiceTheCopies() {
        XCTAssertEqual(analyze(["Cmd+V": 30, "Cmd+C": 15]).primary, .copyPasteEngineer)
        XCTAssertEqual(analyze(["Cmd+V": 29, "Cmd+C": 10]).primary, .balancedPlayer)
        XCTAssertEqual(analyze(["Cmd+V": 40, "Cmd+C": 21]).primary, .balancedPlayer)
    }

    func testCopyRequiresExactlyCommandModifier() {
        let result = analyze(["Cmd+Shift+C": 10, "Ctrl+C": 10, "RightCmd+C": 5])
        XCTAssertEqual(result.copyCount, 5)
    }

    func testPerfectionistCountsDeleteAndForwardDeleteWithModifiers() {
        let result = analyze(["Delete": 60, "Shift+ForwardDelete": 40])
        XCTAssertEqual(result.regretCount, 100)
        XCTAssertEqual(result.primary, .perfectionist)
    }

    func testArrowKeyWalkerAtThreshold() {
        let result = analyze(["Up": 40, "Shift+Down": 40])
        XCTAssertEqual(result.arrowCount, 80)
        XCTAssertEqual(result.primary, .arrowKeyWalker)
    }

    func testMousePersonAndKeyboardPuristThresholds() {
        XCTAssertEqual(analyze([:], keys: 1000, clicks: 1000).primary, .mousePerson)
        XCTAssertEqual(analyze([:], keys: 1000, clicks: 150).primary, .keyboardPurist)
        XCTAssertEqual(analyze([:], keys: 1000, clicks: 151).primary, .balancedPlayer)
    }

    func testPriorityOrderAndSecondaryTags() {
        let result = analyze(["Cmd+K": 150, "Delete": 120], keys: 1000, clicks: 100)
        XCTAssertEqual(result.primary, .shortcutMaster)
        XCTAssertEqual(result.secondary, [.perfectionist, .keyboardPurist])
    }

    func testTopKeysExcludeSpaceAndMergeLeftRightModifiers() {
        let result = analyze(["Space": 900, "LeftCmd+C": 5, "Cmd+C": 5, "E": 8, "A": 8, "Z": 1])
        XCTAssertEqual(result.topKeys, [
            KeyboardPersonaKeyCount(name: "Cmd+C", count: 10),
            KeyboardPersonaKeyCount(name: "A", count: 8),
            KeyboardPersonaKeyCount(name: "E", count: 8),
        ])
    }

    func testParseKeyNameHandlesLiteralPlus() {
        let parsed = KeyboardPersonaAnalyzer.parseKeyName("Cmd++")
        XCTAssertEqual(parsed.modifiers, ["Cmd"])
        XCTAssertEqual(parsed.base, "+")
        XCTAssertEqual(KeyboardPersonaAnalyzer.parseKeyName("+").base, "+")
    }

    // MARK: - Contribution wall

    func testLastTwelveMonthsGridStartsOnMondayAndEndsToday() {
        let today = date(2026, 10, 22) // 周四
        let model = ContributionWallBuilder.build(range: .last12Months, today: today, calendar: calendar) { _ in 0 }
        XCTAssertEqual(model.columnCount, 53)
        XCTAssertEqual(model.days.first?.date, date(2025, 10, 20))
        XCTAssertEqual(model.days.first?.row, 0)
        XCTAssertEqual(model.days.count, 368)
        XCTAssertEqual(model.days.last?.column, 52)
        XCTAssertEqual(model.days.last?.row, 3)
        XCTAssertEqual(model.monthLabels.prefix(2), [
            ContributionWallMonthLabel(column: 0, month: 10),
            ContributionWallMonthLabel(column: 2, month: 11),
        ])
        XCTAssertEqual(model.currentStreak, 0)
        XCTAssertNil(model.bestDay)
    }

    func testPastYearViewHasNoCurrentStreak() {
        let today = date(2026, 10, 22)
        let model = ContributionWallBuilder.build(range: .year(2025), today: today, calendar: calendar) { _ in 1 }
        XCTAssertEqual(model.columnCount, 53)
        XCTAssertEqual(model.days.count, 365)
        XCTAssertEqual(model.days.first?.date, date(2025, 1, 1))
        XCTAssertEqual(model.days.first?.column, 0)
        XCTAssertEqual(model.days.first?.row, 2) // 周三
        XCTAssertNil(model.currentStreak)
        XCTAssertEqual(model.longestStreak, 365)
        XCTAssertEqual(model.activeDays, 365)
    }

    func testCurrentYearStopsAtToday() {
        let today = date(2026, 10, 22)
        let model = ContributionWallBuilder.build(range: .year(2026), today: today, calendar: calendar) { _ in 0 }
        XCTAssertEqual(model.days.last?.date, today)
        XCTAssertEqual(model.days.count, 295)
    }

    func testCurrentStreakStartsFromYesterdayWhenTodayIsEmpty() {
        let today = date(2026, 10, 22)
        let active: Set<Date> = [date(2026, 10, 19), date(2026, 10, 20), date(2026, 10, 21)]
        let model = ContributionWallBuilder.build(range: .last12Months, today: today, calendar: calendar) {
            active.contains($0) ? 5 : 0
        }
        XCTAssertEqual(model.currentStreak, 3)
        XCTAssertEqual(model.longestStreak, 3)

        let withToday = active.union([today])
        let streak = ContributionWallBuilder.streakEnding(at: today, calendar: calendar) { withToday.contains($0) ? 1 : 0 }
        XCTAssertEqual(streak, 4)
    }

    func testQuartileBucketsAndSummary() {
        let today = date(2026, 10, 22)
        // 最近 8 天依次为 1...8
        let model = ContributionWallBuilder.build(range: .last12Months, today: today, calendar: calendar) { day in
            let offset = self.calendar.dateComponents([.day], from: day, to: today).day ?? 99
            return offset < 8 ? 8 - offset : 0
        }
        XCTAssertEqual(model.quartiles.q1, 2)
        XCTAssertEqual(model.quartiles.q2, 4)
        XCTAssertEqual(model.quartiles.q3, 6)
        XCTAssertEqual(model.intensity(for: 0), 0)
        XCTAssertEqual(model.intensity(for: 2), 0.25)
        XCTAssertEqual(model.intensity(for: 3), 0.5)
        XCTAssertEqual(model.intensity(for: 6), 0.75)
        XCTAssertEqual(model.intensity(for: 7), 1.0)
        XCTAssertEqual(model.total, 36)
        XCTAssertEqual(model.activeDays, 8)
        XCTAssertEqual(model.bestDay, ContributionWallBestDay(date: today, value: 8))
        XCTAssertEqual(model.currentStreak, 8)
    }

    func testAvailableRangesListYearsNewestFirst() {
        let ranges = ContributionWallBuilder.availableRanges(earliestDate: date(2024, 5, 1),
                                                            today: date(2026, 10, 22),
                                                            calendar: calendar)
        XCTAssertEqual(ranges, [.last12Months, .year(2026), .year(2025), .year(2024)])
        XCTAssertEqual(ContributionWallBuilder.availableRanges(earliestDate: nil, today: date(2026, 10, 22), calendar: calendar),
                       [.last12Months, .year(2026)])
    }
}
