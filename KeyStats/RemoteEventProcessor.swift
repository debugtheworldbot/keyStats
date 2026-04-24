import Foundation
import Cocoa
import CoreGraphics
import Carbon

/// 把 helper 送来的 payload 翻译回 StatsManager 能吃的调用。
final class RemoteEventProcessor: NSObject, KeyStatsEventSinkProtocol {
    static let shared = RemoteEventProcessor()

    private let decoder = InputEventDecoder.shared
    private var modifierTracker = ModifierStandaloneTracker()
    private let modifierLock = NSLock()

    private override init() { super.init() }

    func receiveEvent(_ payload: [String: Any]) {
        #if DEBUG
        struct Counter { static var n: Int = 0; static let lock = NSLock() }
        Counter.lock.lock(); Counter.n += 1; let n = Counter.n; Counter.lock.unlock()
        if n <= 3 || n % 50 == 0 {
            let typeRaw = (payload[HelperPayloadFields.type] as? NSNumber)?.uint32Value ?? 0
            NSLog("[RemoteEventProcessor] #\(n) raw type=\(typeRaw) keys=\(payload.keys.sorted())")
        }
        #endif
        guard let typeRaw = (payload[HelperPayloadFields.type] as? NSNumber)?.uint32Value,
              let type = CGEventType(rawValue: typeRaw) else { return }

        let pid = (payload[HelperPayloadFields.sourcePID] as? NSNumber)?.int32Value ?? 0
        let stats = StatsManager.shared

        switch type {
        case .keyDown:
            let isAutoRepeat = (payload[HelperPayloadFields.isAutoRepeat] as? NSNumber)?.boolValue ?? false
            if isAutoRepeat { return }
            if stats.handleMouseDistanceCalibrationKeyPress() { return }
            guard let keyCode = (payload[HelperPayloadFields.keyCode] as? NSNumber)?.intValue,
                  let keyboardType = (payload[HelperPayloadFields.keyboardType] as? NSNumber)?.uint32Value,
                  let flagsRaw = (payload[HelperPayloadFields.flags] as? NSNumber)?.uint64Value
            else { return }

            modifierLock.lock()
            modifierTracker.consumePendingModifiers(forKeyDownWith: flagsRaw, keyCode: keyCode)
            modifierLock.unlock()

            let name = decoder.keyName(keyCode: keyCode, keyboardType: keyboardType, flagsRaw: flagsRaw)
            stats.incrementKeyPresses(keyName: name, appIdentity: appIdentity(forPID: pid))

        case .flagsChanged:
            guard let keyCode = (payload[HelperPayloadFields.keyCode] as? NSNumber)?.intValue,
                  let flagsRaw = (payload[HelperPayloadFields.flags] as? NSNumber)?.uint64Value
            else { return }

            if keyCode == 57 {  // CapsLock
                stats.incrementKeyPresses(keyName: "CapsLock", appIdentity: appIdentity(forPID: pid))
                return
            }

            modifierLock.lock()
            let modifierName = modifierTracker.handleFlagsChanged(keyCode: keyCode, rawFlags: flagsRaw)
            modifierLock.unlock()
            if let modifierName {
                stats.incrementKeyPresses(keyName: modifierName, appIdentity: appIdentity(forPID: pid))
            }

        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            let role = payload[HelperPayloadFields.buttonRole] as? String
            let ident = appIdentity(forPID: pid)
            switch role {
            case ButtonRole.primary: stats.incrementLeftClicks(appIdentity: ident)
            case ButtonRole.secondary: stats.incrementRightClicks(appIdentity: ident)
            case ButtonRole.back: stats.incrementSideBackClicks(appIdentity: ident)
            case ButtonRole.forward: stats.incrementSideForwardClicks(appIdentity: ident)
            default: break
            }

        case .scrollWheel:
            let dx = (payload[HelperPayloadFields.scrollDX] as? NSNumber)?.doubleValue ?? 0
            let dy = (payload[HelperPayloadFields.scrollDY] as? NSNumber)?.doubleValue ?? 0
            let total = sqrt(dx * dx + dy * dy)
            stats.addScrollDistance(total * 10, appIdentity: appIdentity(forPID: pid))

        case .mouseMoved, .leftMouseDragged, .rightMouseDragged:
            guard let x = (payload[HelperPayloadFields.locationX] as? NSNumber)?.doubleValue,
                  let y = (payload[HelperPayloadFields.locationY] as? NSNumber)?.doubleValue
            else { return }
            let current = CGPoint(x: x, y: y)
            if let last = stats.lastMousePosition {
                let dx = current.x - last.x
                let dy = current.y - last.y
                let d = sqrt(dx * dx + dy * dy)
                if d < 500 {
                    if stats.isMouseDistanceCalibrating {
                        stats.recordMouseDistanceCalibration(d)
                    } else {
                        stats.addMouseDistance(d)
                    }
                }
            }
            stats.lastMousePosition = current

        default:
            break
        }
    }

    private func appIdentity(forPID pid: pid_t) -> AppIdentity? {
        guard StatsManager.shared.appStatsEnabled else { return nil }
        return AppActivityTracker.shared.appIdentity(forPID: pid)
    }
}

/// 键码 → 可读键名（+修饰键前缀）。Helper payload 只带原始字段，
/// 由主 app 端还原键名后喂给 StatsManager。
final class InputEventDecoder {
    static let shared = InputEventDecoder()

    private let layoutLock = NSLock()
    private var cachedLayoutData: CFData?
    private var inputSourceObserver: NSObjectProtocol?

    private init() {
        startInputSourceMonitoring()
        refreshKeyboardLayoutCache()
    }

    deinit {
        if let observer = inputSourceObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
    }

    func keyName(keyCode: Int, keyboardType: UInt32, flagsRaw: UInt64) -> String {
        let base = baseKeyName(for: keyCode, keyboardType: keyboardType)
        let modifiers = keyboardEventModifierNames(rawFlags: flagsRaw, keyCode: keyCode)
        if modifiers.isEmpty { return base }
        return modifiers.joined(separator: "+") + "+" + base
    }

    private func baseKeyName(for keyCode: Int, keyboardType: UInt32) -> String {
        if let mapped = Self.keyCodeMap[keyCode] {
            return mapped
        }
        if let asciiName = asciiKeyName(for: keyCode, keyboardType: keyboardType) {
            return asciiName
        }
        return "Key\(keyCode)"
    }

    private static let keyCodeMap: [Int: String] = [
        36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Esc",
        63: "Fn", 64: "F17", 71: "Clear", 76: "Enter", 79: "F18",
        80: "F19", 96: "F5", 97: "F6", 98: "F7", 99: "F3",
        100: "F8", 101: "F9", 103: "F11", 105: "F13", 106: "F16",
        107: "F14", 109: "F10", 111: "F12", 113: "F15", 114: "Help",
        115: "Home", 116: "PageUp", 117: "ForwardDelete", 118: "F4",
        119: "End", 120: "F2", 121: "PageDown", 122: "F1", 123: "Left",
        124: "Right", 125: "Down", 126: "Up", 179: "Fn"
    ]

    private func startInputSourceMonitoring() {
        let name = NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String)
        inputSourceObserver = DistributedNotificationCenter.default().addObserver(
            forName: name,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.refreshKeyboardLayoutCache()
        }
    }

    private func refreshKeyboardLayoutCache() {
        let currentSource = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
        let currentDataPtr = currentSource.flatMap { TISGetInputSourceProperty($0, kTISPropertyUnicodeKeyLayoutData) }
        var layoutData = currentDataPtr.map { Unmanaged<CFData>.fromOpaque($0).takeUnretainedValue() }
        if layoutData == nil {
            if let asciiSource = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue() {
                let asciiDataPtr = TISGetInputSourceProperty(asciiSource, kTISPropertyUnicodeKeyLayoutData)
                layoutData = asciiDataPtr.map { Unmanaged<CFData>.fromOpaque($0).takeUnretainedValue() }
            }
        }
        layoutLock.lock()
        cachedLayoutData = layoutData
        layoutLock.unlock()
    }

    private func asciiKeyName(for keyCode: Int, keyboardType: UInt32) -> String? {
        layoutLock.lock()
        let layoutData = cachedLayoutData
        layoutLock.unlock()
        guard let layoutData = layoutData else { return nil }
        guard let layoutPtr = CFDataGetBytePtr(layoutData) else { return nil }
        let keyboardLayout = unsafeBitCast(layoutPtr, to: UnsafePointer<UCKeyboardLayout>.self)

        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var actualLength: Int = 0
        let modifiers: UInt32 = 0
        let status = UCKeyTranslate(
            keyboardLayout,
            UInt16(keyCode),
            UInt16(kUCKeyActionDown),
            modifiers,
            keyboardType,
            UInt32(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            chars.count,
            &actualLength,
            &chars
        )

        guard status == noErr, actualLength > 0 else { return nil }
        let raw = String(utf16CodeUnits: chars, count: actualLength)
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned.count == 1 else { return nil }
        if cleaned == " " { return "Space" }
        if cleaned == "\t" { return "Tab" }
        if cleaned == "\r" { return "Return" }
        return cleaned.uppercased()
    }
}
