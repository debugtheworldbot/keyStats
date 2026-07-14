import XCTest
import CoreGraphics
import IOKit.hidsystem
@testable import KeyStatsCore

final class StatsModelsTests: XCTestCase {
    func testMenuBarCompactNumberUsesAtMostThreeLeadingDigits() {
        XCTAssertEqual(formatMenuBarCompactNumber(999), "999")
        XCTAssertEqual(formatMenuBarCompactNumber(1_000), "1.00k")
        XCTAssertEqual(formatMenuBarCompactNumber(3_249), "3.24k")
        XCTAssertEqual(formatMenuBarCompactNumber(9_999), "9.99k")
        XCTAssertEqual(formatMenuBarCompactNumber(10_300), "10.3k")
        XCTAssertEqual(formatMenuBarCompactNumber(10_399), "10.3k")
        XCTAssertEqual(formatMenuBarCompactNumber(99_999), "99.9k")
        XCTAssertEqual(formatMenuBarCompactNumber(100_000), "100k")
        XCTAssertEqual(formatMenuBarCompactNumber(999_999), "999k")
        XCTAssertEqual(formatMenuBarCompactNumber(1_234_567), "1.23M")
        XCTAssertEqual(formatMenuBarCompactNumber(10_349_999), "10.3M")
    }

    func testDailyStatsInitNormalizesDateToStartOfDay() {
        let date = Date(timeIntervalSince1970: 1_710_099_123)

        let stats = DailyStats(date: date)

        XCTAssertEqual(stats.date, Calendar.current.startOfDay(for: date))
    }

    func testDailyStatsCorrectionRateCountsDeleteVariants() {
        var stats = DailyStats(date: Date())
        stats.keyPresses = 20
        stats.keyPressCounts = [
            "Delete": 2,
            "Shift + Delete": 3,
            "Command+ForwardDelete": 1,
            "Space": 9
        ]

        XCTAssertEqual(stats.correctionRate, 0.3, accuracy: 0.0001)
    }

    func testDailyStatsInputRatioHandlesZeroClicks() {
        var stats = DailyStats(date: Date())
        stats.keyPresses = 8

        XCTAssertEqual(stats.inputRatio, .infinity)
    }

    func testDailyStatsHasAnyActivityDetectsNestedAppStats() {
        var stats = DailyStats(date: Date())
        stats.appStats["com.test.app"] = AppStats(bundleId: "com.test.app", displayName: "Test")

        XCTAssertTrue(stats.hasAnyActivity)
    }

    func testDailyStatsCodableBackfillsLegacyOtherClicks() throws {
        let json = """
        {
          "date": 1710028800,
          "keyPresses": 4,
          "otherClicks": 7,
          "mouseDistance": 15.5,
          "scrollDistance": 9
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(DailyStats.self, from: json)

        XCTAssertEqual(decoded.sideBackClicks, 7)
        XCTAssertEqual(decoded.sideForwardClicks, 0)
        XCTAssertEqual(decoded.totalClicks, 7)
        XCTAssertEqual(decoded.mouseDistance, 15.5, accuracy: 0.0001)
    }

    func testAllTimeStatsInitialStartsEmpty() {
        let stats = AllTimeStats.initial()

        XCTAssertEqual(stats.totalKeyPresses, 0)
        XCTAssertEqual(stats.totalClicks, 0)
        XCTAssertEqual(stats.correctionRate, 0)
        XCTAssertEqual(stats.inputRatio, 0)
        XCTAssertNil(stats.firstDate)
        XCTAssertNil(stats.lastDate)
    }

    func testAllTimeStatsCorrectionRateAndInputRatioUseAggregates() {
        let stats = AllTimeStats(
            totalKeyPresses: 12,
            totalLeftClicks: 2,
            totalRightClicks: 1,
            totalMiddleClicks: 0,
            totalSideBackClicks: 1,
            totalSideForwardClicks: 0,
            totalMouseDistance: 0,
            totalScrollDistance: 0,
            keyPressCounts: [
                "Option + Delete": 2,
                "ForwardDelete": 1,
                "A": 9
            ],
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

        XCTAssertEqual(stats.totalClicks, 4)
        XCTAssertEqual(stats.correctionRate, 0.25, accuracy: 0.0001)
        XCTAssertEqual(stats.inputRatio, 3.0, accuracy: 0.0001)
    }

    func testKeyboardHeatmapAggregationSeparatesLeftAndRightModifierKeys() {
        let aggregated = keyboardHeatmapCounts(from: [
            "LeftShift+A": 3,
            "RightShift+A": 2,
            "LeftOption+B": 4,
            "RightOption+B": 1,
            "LeftCmd+C": 5,
            "RightCmd+C": 2,
            "Shift": 7
        ])

        XCTAssertEqual(aggregated["LeftShift"], 3)
        XCTAssertEqual(aggregated["RightShift"], 2)
        XCTAssertEqual(aggregated["LeftOption"], 4)
        XCTAssertEqual(aggregated["RightOption"], 1)
        XCTAssertEqual(aggregated["LeftCmd"], 5)
        XCTAssertEqual(aggregated["RightCmd"], 2)
        XCTAssertEqual(aggregated["Shift"], 7)
        XCTAssertEqual(aggregated["A"], 5)
        XCTAssertEqual(aggregated["B"], 5)
        XCTAssertEqual(aggregated["C"], 7)
    }

    func testKeyboardEventModifierNamesUsesSideSpecificFlagsForShiftOptionAndCommand() {
        let rawFlags = CGEventFlags.maskShift.rawValue |
            CGEventFlags.maskAlternate.rawValue |
            CGEventFlags.maskCommand.rawValue |
            UInt64(NX_DEVICERSHIFTKEYMASK) |
            UInt64(NX_DEVICELALTKEYMASK) |
            UInt64(NX_DEVICERCMDKEYMASK)

        let names = keyboardEventModifierNames(rawFlags: rawFlags, keyCode: 0)

        XCTAssertEqual(names, ["RightCmd", "RightShift", "LeftOption"])
    }

    func testStandaloneModifierHelpersRecognizeLeftAndRightModifierKeys() {
        XCTAssertEqual(standaloneModifierHeatmapKeyName(for: 56), "LeftShift")
        XCTAssertEqual(standaloneModifierHeatmapKeyName(for: 60), "RightShift")
        XCTAssertEqual(standaloneModifierHeatmapKeyName(for: 58), "LeftOption")
        XCTAssertEqual(standaloneModifierHeatmapKeyName(for: 61), "RightOption")
        XCTAssertEqual(standaloneModifierHeatmapKeyName(for: 55), "LeftCmd")
        XCTAssertEqual(standaloneModifierHeatmapKeyName(for: 54), "RightCmd")
        XCTAssertTrue(isStandaloneModifierPress(rawFlags: UInt64(NX_DEVICERSHIFTKEYMASK), keyCode: 60))
        XCTAssertTrue(isStandaloneModifierPress(rawFlags: UInt64(NX_DEVICELSHIFTKEYMASK), keyCode: 60))
    }

    func testModifierStandaloneTrackerCommitsSingleModifierPressOnRelease() {
        var tracker = ModifierStandaloneTracker()

        XCTAssertNil(tracker.handleFlagsChanged(keyCode: 56, rawFlags: UInt64(NX_DEVICELSHIFTKEYMASK)))

        let committed = tracker.handleFlagsChanged(keyCode: 56, rawFlags: 0)

        XCTAssertEqual(committed, "LeftShift")
    }

    func testModifierStandaloneTrackerSuppressesStandaloneCountWhenModifierIsUsedInCombo() {
        var tracker = ModifierStandaloneTracker()

        XCTAssertNil(tracker.handleFlagsChanged(keyCode: 55, rawFlags: UInt64(NX_DEVICELCMDKEYMASK)))
        tracker.consumePendingModifiers(
            forKeyDownWith: UInt64(NX_DEVICELCMDKEYMASK) | CGEventFlags.maskCommand.rawValue,
            keyCode: 8
        )

        let committed = tracker.handleFlagsChanged(keyCode: 55, rawFlags: 0)

        XCTAssertNil(committed)
    }

    func testModifierStandaloneTrackerSuppressesStandaloneCountWhenComboOnlyHasGenericModifierFlag() {
        var tracker = ModifierStandaloneTracker()

        XCTAssertNil(tracker.handleFlagsChanged(keyCode: 54, rawFlags: UInt64(NX_DEVICERCMDKEYMASK)))
        tracker.consumePendingModifiers(forKeyDownWith: CGEventFlags.maskCommand.rawValue, keyCode: 8)

        let committed = tracker.handleFlagsChanged(keyCode: 54, rawFlags: 0)

        XCTAssertNil(committed)
    }

    func testModifierStandaloneTrackerSuppressesAllPendingModifiersConsumedByCombo() {
        var tracker = ModifierStandaloneTracker()

        XCTAssertNil(tracker.handleFlagsChanged(keyCode: 55, rawFlags: UInt64(NX_DEVICELCMDKEYMASK)))
        XCTAssertNil(tracker.handleFlagsChanged(keyCode: 60, rawFlags: UInt64(NX_DEVICELCMDKEYMASK | NX_DEVICERSHIFTKEYMASK)))
        tracker.consumePendingModifiers(
            forKeyDownWith: UInt64(NX_DEVICELCMDKEYMASK) |
                UInt64(NX_DEVICERSHIFTKEYMASK) |
                CGEventFlags.maskCommand.rawValue |
                CGEventFlags.maskShift.rawValue,
            keyCode: 7
        )

        XCTAssertNil(tracker.handleFlagsChanged(keyCode: 60, rawFlags: UInt64(NX_DEVICELCMDKEYMASK)))
        XCTAssertNil(tracker.handleFlagsChanged(keyCode: 55, rawFlags: 0))
    }

    func testKeyBreakdownDisplayCountsAggregatesLeftAndRightModifierKeysForListDisplay() {
        let counts = keyBreakdownDisplayCounts(from: [
            "LeftCmd+C": 5,
            "RightCmd+C": 2,
            "LeftShift": 1,
            "RightShift": 3,
            "LeftOption+Delete": 4,
            "RightOption+Delete": 1,
            "A": 9
        ])

        XCTAssertEqual(counts["Cmd+C"], 7)
        XCTAssertEqual(counts["Shift"], 4)
        XCTAssertEqual(counts["Option+Delete"], 5)
        XCTAssertEqual(counts["A"], 9)
        XCTAssertNil(counts["LeftCmd+C"])
        XCTAssertNil(counts["RightShift"])
    }

    func testModifierStandaloneTrackerUsesSideSpecificRawFlagsWhenKeyCodeLooksGeneric() {
        var tracker = ModifierStandaloneTracker()

        XCTAssertNil(tracker.handleFlagsChanged(keyCode: 56, rawFlags: UInt64(NX_DEVICERSHIFTKEYMASK)))

        let committed = tracker.handleFlagsChanged(keyCode: 56, rawFlags: 0)

        XCTAssertEqual(committed, "RightShift")
    }

    func testModifierStandaloneTrackerReleasesPendingModifierByFamilyWhenReleaseKeyCodeDiffers() {
        var tracker = ModifierStandaloneTracker()

        XCTAssertNil(tracker.handleFlagsChanged(keyCode: 60, rawFlags: UInt64(NX_DEVICERSHIFTKEYMASK)))

        let committed = tracker.handleFlagsChanged(keyCode: 56, rawFlags: 0)

        XCTAssertEqual(committed, "RightShift")
    }
}
