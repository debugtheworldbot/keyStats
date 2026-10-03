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

    func testStandaloneModifierHelpersRecognizeControlAndFnKeys() {
        XCTAssertEqual(standaloneModifierHeatmapKeyName(for: 59), "Ctrl")
        XCTAssertEqual(standaloneModifierHeatmapKeyName(for: 62), "Ctrl")
        XCTAssertEqual(standaloneModifierHeatmapKeyName(for: 63), "Fn")
        XCTAssertEqual(standaloneModifierHeatmapKeyName(for: 179), "Fn")
        XCTAssertTrue(isStandaloneModifierPress(rawFlags: UInt64(NX_DEVICELCTLKEYMASK), keyCode: 59))
        XCTAssertTrue(isStandaloneModifierPress(rawFlags: CGEventFlags.maskControl.rawValue, keyCode: 62))
        XCTAssertFalse(isStandaloneModifierPress(rawFlags: 0, keyCode: 59))
        XCTAssertTrue(isStandaloneModifierPress(rawFlags: CGEventFlags.maskSecondaryFn.rawValue, keyCode: 63))
        XCTAssertFalse(isStandaloneModifierPress(rawFlags: 0, keyCode: 63))
    }

    func testModifierStandaloneTrackerCommitsSingleControlPressOnRelease() {
        var tracker = ModifierStandaloneTracker()

        XCTAssertNil(tracker.handleFlagsChanged(keyCode: 59, rawFlags: leftControlDownFlags))
        XCTAssertEqual(tracker.handleFlagsChanged(keyCode: 59, rawFlags: 0), "Ctrl")

        XCTAssertNil(tracker.handleFlagsChanged(keyCode: 62, rawFlags: rightControlDownFlags))
        XCTAssertEqual(tracker.handleFlagsChanged(keyCode: 62, rawFlags: 0), "Ctrl")
    }

    func testModifierStandaloneTrackerSuppressesControlWhenUsedInCombo() {
        var tracker = ModifierStandaloneTracker()

        XCTAssertNil(tracker.handleFlagsChanged(keyCode: 59, rawFlags: leftControlDownFlags))
        tracker.consumePendingModifiers(forKeyDownWith: leftControlDownFlags, keyCode: 8)

        XCTAssertNil(tracker.handleFlagsChanged(keyCode: 59, rawFlags: 0))
    }

    func testModifierStandaloneTrackerSuppressesControlWhenComboOnlyHasGenericControlFlag() {
        var tracker = ModifierStandaloneTracker()

        XCTAssertNil(tracker.handleFlagsChanged(keyCode: 62, rawFlags: rightControlDownFlags))
        tracker.consumePendingModifiers(forKeyDownWith: CGEventFlags.maskControl.rawValue, keyCode: 8)

        XCTAssertNil(tracker.handleFlagsChanged(keyCode: 62, rawFlags: 0))
    }

    func testModifierStandaloneTrackerCommitsSingleFnPressOnRelease() {
        var tracker = ModifierStandaloneTracker()

        XCTAssertNil(tracker.handleFlagsChanged(keyCode: 63, rawFlags: CGEventFlags.maskSecondaryFn.rawValue))
        XCTAssertEqual(tracker.handleFlagsChanged(keyCode: 63, rawFlags: 0), "Fn")
    }

    func testModifierStandaloneTrackerSuppressesFnWhenUsedWithNavigationKey() {
        var tracker = ModifierStandaloneTracker()

        // Fn+Left 产生 Home(115)，keyboardEventModifierNames 不会带上 Fn
        XCTAssertNil(tracker.handleFlagsChanged(keyCode: 63, rawFlags: CGEventFlags.maskSecondaryFn.rawValue))
        tracker.consumePendingModifiers(forKeyDownWith: CGEventFlags.maskSecondaryFn.rawValue, keyCode: 115)

        XCTAssertNil(tracker.handleFlagsChanged(keyCode: 63, rawFlags: 0))
    }

    func testModifierStandaloneTrackerSuppressesFnWhenUsedWithLetterKey() {
        var tracker = ModifierStandaloneTracker()

        XCTAssertNil(tracker.handleFlagsChanged(keyCode: 63, rawFlags: CGEventFlags.maskSecondaryFn.rawValue))
        tracker.consumePendingModifiers(forKeyDownWith: CGEventFlags.maskSecondaryFn.rawValue, keyCode: 0)

        XCTAssertNil(tracker.handleFlagsChanged(keyCode: 63, rawFlags: 0))
    }

    func testControlAndFnPipelineCountsSinglePressOnceAndComboWithoutDuplicates() {
        let fn = CGEventFlags.maskSecondaryFn.rawValue

        // 单按 Ctrl
        XCTAssertEqual(simulateKeyPressCounts([
            .flags(59, leftControlDownFlags), .flags(59, 0)
        ]), ["Ctrl": 1])

        // Ctrl+C
        let ctrlC = simulateKeyPressCounts([
            .flags(59, leftControlDownFlags), .keyDown(8, "C", leftControlDownFlags), .flags(59, 0)
        ])
        XCTAssertEqual(ctrlC, ["Ctrl+C": 1])
        XCTAssertEqual(keyboardHeatmapCounts(from: ctrlC)["Ctrl"], 1)

        // 按住 Ctrl 连按 C、V：两次组合，Ctrl 不额外计单按
        let ctrlCV = simulateKeyPressCounts([
            .flags(62, rightControlDownFlags),
            .keyDown(8, "C", rightControlDownFlags),
            .keyDown(9, "V", rightControlDownFlags),
            .flags(62, 0)
        ])
        XCTAssertEqual(ctrlCV, ["Ctrl+C": 1, "Ctrl+V": 1])
        XCTAssertEqual(keyboardHeatmapCounts(from: ctrlCV)["Ctrl"], 2)

        // 单按 Fn
        XCTAssertEqual(simulateKeyPressCounts([.flags(63, fn), .flags(63, 0)]), ["Fn": 1])

        // Fn+Left -> Home：只计 Home
        XCTAssertEqual(simulateKeyPressCounts([
            .flags(63, fn), .keyDown(115, "Home", fn), .flags(63, 0)
        ]), ["Home": 1])

        // Ctrl+Fn 同时单按后松开：各计一次
        XCTAssertEqual(simulateKeyPressCounts([
            .flags(59, leftControlDownFlags),
            .flags(63, leftControlDownFlags | fn),
            .flags(63, leftControlDownFlags),
            .flags(59, 0)
        ]), ["Ctrl": 1, "Fn": 1])
    }

    func testModifierStandaloneTrackerReleasesPendingModifierByFamilyWhenReleaseKeyCodeDiffers() {
        var tracker = ModifierStandaloneTracker()

        XCTAssertNil(tracker.handleFlagsChanged(keyCode: 60, rawFlags: UInt64(NX_DEVICERSHIFTKEYMASK)))

        let committed = tracker.handleFlagsChanged(keyCode: 56, rawFlags: 0)

        XCTAssertEqual(committed, "RightShift")
    }

    private let leftControlDownFlags = UInt64(NX_DEVICELCTLKEYMASK) | CGEventFlags.maskControl.rawValue
    private let rightControlDownFlags = UInt64(NX_DEVICERCTLKEYMASK) | CGEventFlags.maskControl.rawValue

    private enum SimulatedKeyEvent {
        case flags(Int, UInt64)
        case keyDown(Int, String, UInt64)
    }

    /// 模拟 RemoteEventProcessor 对 keyDown / flagsChanged 的计数流程
    private func simulateKeyPressCounts(_ events: [SimulatedKeyEvent]) -> [String: Int] {
        var tracker = ModifierStandaloneTracker()
        var counts: [String: Int] = [:]

        for event in events {
            switch event {
            case let .flags(keyCode, rawFlags):
                if let name = tracker.handleFlagsChanged(keyCode: keyCode, rawFlags: rawFlags) {
                    counts[name, default: 0] += 1
                }
            case let .keyDown(keyCode, baseName, rawFlags):
                tracker.consumePendingModifiers(forKeyDownWith: rawFlags, keyCode: keyCode)
                let modifiers = keyboardEventModifierNames(rawFlags: rawFlags, keyCode: keyCode)
                let name = (modifiers + [baseName]).joined(separator: "+")
                counts[name, default: 0] += 1
            }
        }

        return counts
    }
}
