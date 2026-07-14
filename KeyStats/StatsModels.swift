import Foundation
import CoreGraphics
import IOKit.hidsystem

let baseMetersPerPixel: Double = 0.000264583

/// Formats menu bar counters with up to three significant digits.
func formatMenuBarCompactNumber(_ number: Int) -> String {
    guard number >= 1_000 else { return "\(number)" }

    let units = ["k", "M", "B", "T", "P", "E"]
    var divisor = 1_000.0
    var unitIndex = 0

    while unitIndex < units.count - 1 && Double(number) / divisor >= 1_000 {
        divisor *= 1_000
        unitIndex += 1
    }

    let value = Double(number) / divisor
    let integerDigits = max(1, Int(log10(value)) + 1)
    let decimalPlaces = max(0, 3 - integerDigits)
    let scale = pow(10.0, Double(decimalPlaces))
    let truncatedValue = floor(value * scale) / scale

    return String(format: "%.\(decimalPlaces)f%@", truncatedValue, units[unitIndex])
}

private func saturatingNonnegativeSum(_ values: [Int]) -> Int {
    values.reduce(0) { total, value in
        let nonnegative = max(0, value)
        let (sum, overflow) = total.addingReportingOverflow(nonnegative)
        return overflow ? Int.max : sum
    }
}

private let leftControlRawMask = UInt64(NX_DEVICELCTLKEYMASK)
private let rightControlRawMask = UInt64(NX_DEVICERCTLKEYMASK)
private let leftShiftRawMask = UInt64(NX_DEVICELSHIFTKEYMASK)
private let rightShiftRawMask = UInt64(NX_DEVICERSHIFTKEYMASK)
private let leftCommandRawMask = UInt64(NX_DEVICELCMDKEYMASK)
private let rightCommandRawMask = UInt64(NX_DEVICERCMDKEYMASK)
private let leftOptionRawMask = UInt64(NX_DEVICELALTKEYMASK)
private let rightOptionRawMask = UInt64(NX_DEVICERALTKEYMASK)

func baseKeyComponent(_ keyName: String) -> String {
    let trimmed = keyName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }
    if let last = trimmed.split(separator: "+").last {
        return String(last).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return trimmed
}

private func canonicalBreakdownKeyPart(_ rawKeyPart: String) -> String {
    let trimmed = rawKeyPart.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }

    switch trimmed.uppercased() {
    case "FN", "FUNCTION", "KEY63", "KEY179", "GLOBE", "🌐":
        return "Fn"
    default:
        return trimmed
    }
}

private func canonicalBreakdownKeyName(_ keyName: String) -> String {
    let trimmed = keyName.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed == "+" {
        return "+"
    }

    var raw = trimmed
    var trailingPlus = false
    if raw.hasSuffix("++") {
        raw = String(raw.dropLast())
        trailingPlus = true
    }

    var rawComponents = raw
        .split(separator: "+")
        .map { canonicalBreakdownKeyPart(String($0)) }
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

func standaloneModifierHeatmapKeyName(for keyCode: Int) -> String? {
    switch keyCode {
    case 55:
        return "LeftCmd"
    case 54:
        return "RightCmd"
    case 56:
        return "LeftShift"
    case 60:
        return "RightShift"
    case 58:
        return "LeftOption"
    case 61:
        return "RightOption"
    default:
        return nil
    }
}

private enum StandaloneModifierFamily {
    case shift
    case option
    case command
}

private func standaloneModifierFamily(for keyCode: Int) -> StandaloneModifierFamily? {
    switch keyCode {
    case 55, 54:
        return .command
    case 56, 60:
        return .shift
    case 58, 61:
        return .option
    default:
        return nil
    }
}

private func standaloneModifierFamily(for keyName: String) -> StandaloneModifierFamily? {
    switch keyName {
    case "Cmd":
        return .command
    case "LeftCmd", "RightCmd":
        return .command
    case "Shift":
        return .shift
    case "LeftShift", "RightShift":
        return .shift
    case "Option":
        return .option
    case "LeftOption", "RightOption":
        return .option
    default:
        return nil
    }
}

private func standaloneModifierKeyName(from rawFlags: UInt64, family: StandaloneModifierFamily) -> String? {
    switch family {
    case .shift:
        if rawFlags & rightShiftRawMask != 0 { return "RightShift" }
        if rawFlags & leftShiftRawMask != 0 { return "LeftShift" }
    case .option:
        if rawFlags & rightOptionRawMask != 0 { return "RightOption" }
        if rawFlags & leftOptionRawMask != 0 { return "LeftOption" }
    case .command:
        if rawFlags & rightCommandRawMask != 0 { return "RightCmd" }
        if rawFlags & leftCommandRawMask != 0 { return "LeftCmd" }
    }

    return nil
}

func standaloneModifierHeatmapKeyName(for keyCode: Int, rawFlags: UInt64) -> String? {
    guard let family = standaloneModifierFamily(for: keyCode) else {
        return standaloneModifierHeatmapKeyName(for: keyCode)
    }

    return standaloneModifierKeyName(from: rawFlags, family: family) ?? standaloneModifierHeatmapKeyName(for: keyCode)
}

func isStandaloneModifierPress(rawFlags: UInt64, keyCode: Int) -> Bool {
    guard let family = standaloneModifierFamily(for: keyCode) else { return false }
    return standaloneModifierKeyName(from: rawFlags, family: family) != nil
}

func isStandaloneHeatmapModifierKey(_ keyName: String) -> Bool {
    switch keyName {
    case "LeftShift", "RightShift", "LeftOption", "RightOption", "LeftCmd", "RightCmd":
        return true
    default:
        return false
    }
}

func keyboardEventModifierNames(rawFlags: UInt64, keyCode: Int) -> [String] {
    let flags = CGEventFlags(rawValue: rawFlags)
    var names: [String] = []

    if rawFlags & leftCommandRawMask != 0 {
        names.append("LeftCmd")
    }
    if rawFlags & rightCommandRawMask != 0 {
        names.append("RightCmd")
    }
    if !names.contains("LeftCmd") && !names.contains("RightCmd") && flags.contains(.maskCommand) {
        names.append("Cmd")
    }

    if rawFlags & leftShiftRawMask != 0 {
        names.append("LeftShift")
    }
    if rawFlags & rightShiftRawMask != 0 {
        names.append("RightShift")
    }
    if !names.contains("LeftShift") && !names.contains("RightShift") && flags.contains(.maskShift) {
        names.append("Shift")
    }

    if rawFlags & leftOptionRawMask != 0 {
        names.append("LeftOption")
    }
    if rawFlags & rightOptionRawMask != 0 {
        names.append("RightOption")
    }
    if !names.contains("LeftOption") && !names.contains("RightOption") && flags.contains(.maskAlternate) {
        names.append("Option")
    }

    if rawFlags & leftControlRawMask != 0 || rawFlags & rightControlRawMask != 0 || flags.contains(.maskControl) {
        names.append("Ctrl")
    }

    let isNavigationKey = (123...126).contains(keyCode) || [115, 116, 119, 121, 117].contains(keyCode)
    let isFnKey = [63, 179].contains(keyCode)
    if flags.contains(.maskSecondaryFn) && !isNavigationKey && !isFnKey {
        names.append("Fn")
    }

    return names
}

struct ModifierStandaloneTracker {
    private var pendingModifierKeys: Set<String> = []

    mutating func handleFlagsChanged(keyCode: Int, rawFlags: UInt64) -> String? {
        guard let modifierFamily = standaloneModifierFamily(for: keyCode) else { return nil }
        let modifierKey = standaloneModifierHeatmapKeyName(for: keyCode, rawFlags: rawFlags)

        if isStandaloneModifierPress(rawFlags: rawFlags, keyCode: keyCode) {
            if let modifierKey {
                pendingModifierKeys.insert(modifierKey)
            }
            return nil
        }

        if let modifierKey, pendingModifierKeys.remove(modifierKey) != nil {
            return modifierKey
        }

        guard let familyMatch = pendingModifierKeys.first(where: { standaloneModifierFamily(for: $0) == modifierFamily }) else {
            return nil
        }

        pendingModifierKeys.remove(familyMatch)
        return familyMatch
    }

    mutating func consumePendingModifiers(forKeyDownWith rawFlags: UInt64, keyCode: Int) {
        for modifierKey in keyboardEventModifierNames(rawFlags: rawFlags, keyCode: keyCode) {
            if isStandaloneHeatmapModifierKey(modifierKey) {
                pendingModifierKeys.remove(modifierKey)
                continue
            }

            guard let family = standaloneModifierFamily(for: modifierKey) else { continue }
            pendingModifierKeys = pendingModifierKeys.filter { standaloneModifierFamily(for: $0) != family }
        }
    }

    mutating func reset() {
        pendingModifierKeys.removeAll()
    }
}

func keyboardHeatmapCounts(from keyPressCounts: [String: Int]) -> [String: Int] {
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
            guard let normalizedKey = normalizedKeyboardHeatmapDisplayKey(sourceKey) else { continue }
            aggregated[normalizedKey, default: 0] += count
        }
    }

    return aggregated
}

func keyBreakdownDisplayCounts(from keyPressCounts: [String: Int]) -> [String: Int] {
    var aggregated: [String: Int] = [:]

    for (rawKey, rawCount) in keyPressCounts {
        let count = max(0, rawCount)
        let normalizedKey = normalizedKeyBreakdownDisplayKey(rawKey)
        guard !normalizedKey.isEmpty, count > 0 else { continue }
        aggregated[normalizedKey, default: 0] += count
    }

    return aggregated
}

func normalizedKeyBreakdownDisplayKey(_ rawKey: String) -> String {
    let canonicalKey = canonicalBreakdownKeyName(rawKey)
    guard !canonicalKey.isEmpty else { return "" }
    if canonicalKey == "+" {
        return canonicalKey
    }

    var workingKey = canonicalKey
    var trailingPlus = false
    if workingKey.hasSuffix("++") {
        workingKey = String(workingKey.dropLast())
        trailingPlus = true
    }

    var parts = workingKey
        .split(separator: "+")
        .map { normalizedKeyBreakdownDisplayPart(String($0)) }
        .filter { !$0.isEmpty }

    if trailingPlus {
        parts.append("+")
    }

    guard !parts.isEmpty else { return "" }

    var collapsedParts: [String] = []
    var seenParts: Set<String> = []
    for part in parts {
        if seenParts.insert(part).inserted {
            collapsedParts.append(part)
        }
    }

    return collapsedParts.joined(separator: "+")
}

func normalizedKeyBreakdownDisplayPart(_ rawPart: String) -> String {
    switch rawPart {
    case "LeftCmd", "RightCmd":
        return "Cmd"
    case "LeftOption", "RightOption":
        return "Option"
    case "LeftShift", "RightShift":
        return "Shift"
    default:
        return rawPart
    }
}

func normalizedKeyboardHeatmapDisplayKey(_ rawKey: String) -> String? {
    let trimmed = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let collapsed = trimmed
        .replacingOccurrences(of: " ", with: "")
        .replacingOccurrences(of: "-", with: "")
        .uppercased()

    if collapsed.count == 1 {
        return collapsed
    }

    if collapsed.hasPrefix("F"), Int(collapsed.dropFirst()) != nil {
        return collapsed
    }

    switch collapsed {
    case "LEFTCMD", "LEFTCOMMAND":
        return "LeftCmd"
    case "RIGHTCMD", "RIGHTCOMMAND":
        return "RightCmd"
    case "CMD", "COMMAND", "⌘":
        return "Cmd"
    case "LEFTOPTION", "LEFTOPT", "LEFTALT":
        return "LeftOption"
    case "RIGHTOPTION", "RIGHTOPT", "RIGHTALT":
        return "RightOption"
    case "OPTION", "OPT", "ALT", "⌥":
        return "Option"
    case "LEFTSHIFT":
        return "LeftShift"
    case "RIGHTSHIFT":
        return "RightShift"
    case "SHIFT", "⇧":
        return "Shift"
    case "CTRL", "CONTROL", "⌃":
        return "Ctrl"
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
    case "CAPSLOCK", "CAPS":
        return "CapsLock"
    default:
        return trimmed
    }
}

/// 统计数据结构
struct DailyStats: Codable {
    var date: Date
    var keyPresses: Int
    var keyPressCounts: [String: Int]
    var leftClicks: Int
    var rightClicks: Int
    var middleClicks: Int
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
        self.middleClicks = 0
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
        self.middleClicks = 0
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
        case middleClicks
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
        middleClicks = try container.decodeIfPresent(Int.self, forKey: .middleClicks) ?? 0
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
        try container.encode(middleClicks, forKey: .middleClicks)
        try container.encode(sideBackClicks, forKey: .sideBackClicks)
        try container.encode(sideForwardClicks, forKey: .sideForwardClicks)
        try container.encode(mouseDistance, forKey: .mouseDistance)
        try container.encode(scrollDistance, forKey: .scrollDistance)
        try container.encode(appStats, forKey: .appStats)
        try container.encode(peakKPS, forKey: .peakKPS)
        try container.encode(peakCPS, forKey: .peakCPS)
    }

    var totalClicks: Int {
        saturatingNonnegativeSum([leftClicks, rightClicks, middleClicks, sideBackClicks, sideForwardClicks])
    }

    var hasAnyActivity: Bool {
        keyPresses > 0 ||
            leftClicks > 0 ||
            rightClicks > 0 ||
            middleClicks > 0 ||
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
            return saturatingNonnegativeSum([partial, entry.value])
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
    var totalMiddleClicks: Int
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
        saturatingNonnegativeSum([
            totalLeftClicks,
            totalRightClicks,
            totalMiddleClicks,
            totalSideBackClicks,
            totalSideForwardClicks
        ])
    }

    var totalNonLeftClicks: Int {
        saturatingNonnegativeSum([
            totalRightClicks,
            totalMiddleClicks,
            totalSideBackClicks,
            totalSideForwardClicks
        ])
    }

    /// 纠错率 (Delete + ForwardDelete / Total Keys)
    var correctionRate: Double {
        guard totalKeyPresses > 0 else { return 0 }
        let deleteLikeCount = keyPressCounts.reduce(0) { partial, entry in
            let base = baseKeyComponent(entry.key)
            guard base == "Delete" || base == "ForwardDelete" else { return partial }
            return saturatingNonnegativeSum([partial, entry.value])
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
            totalMiddleClicks: 0,
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
