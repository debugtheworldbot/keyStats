import Foundation
import Cocoa
import CoreGraphics
import Carbon

/// 输入事件监听器
class InputMonitor {
    static let shared = InputMonitor()
    
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isMonitoring = false
    private let mouseSampleInterval: TimeInterval = 1.0 / 30.0
    private var lastMouseSampleTime: TimeInterval = 0
    private let swapLeftRightButtonKey = "com.apple.mouse.swapLeftRightButton"
    private let layoutLock = NSLock()
    private var cachedLayoutData: CFData?
    private var inputSourceObserver: NSObjectProtocol?
    private var modifierStandaloneTracker = ModifierStandaloneTracker()
    
    private init() {
        startInputSourceMonitoring()
        refreshKeyboardLayoutCache()
    }

    deinit {
        if let observer = inputSourceObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
    }
    
    // MARK: - 权限检查
    
    /// 仅检查辅助功能权限状态（不弹出提示）
    func hasAccessibilityPermission() -> Bool {
        return AXIsProcessTrusted()
    }
    
    // MARK: - 开始/停止监听
    
    func startMonitoring() {
        guard !isMonitoring else { return }
        
        // 检查权限
        guard hasAccessibilityPermission() else {
            print("需要辅助功能权限才能监听输入事件")
            return
        }
        
        // 创建事件掩码 - 监听键盘、鼠标点击、鼠标移动和滚动事件
        let keyboardMask: CGEventMask = (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)
        let mouseMask: CGEventMask = (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue)
        let eventMask = keyboardMask | mouseMask
        
        // 创建事件回调
        let callback: CGEventTapCallBack = { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
            InputMonitor.shared.handleEvent(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }
        
        // 创建事件监听器
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: nil
        ) else {
            print("无法创建事件监听器")
            return
        }
        
        eventTap = tap
        
        // 创建 RunLoop 源
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        
        // 添加到主 RunLoop
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        
        // 启用事件监听器
        CGEvent.tapEnable(tap: tap, enable: true)
        
        isMonitoring = true
        print("输入监听已启动")
    }
    
    func stopMonitoring() {
        guard isMonitoring else { return }
        
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        
        eventTap = nil
        runLoopSource = nil
        isMonitoring = false
        modifierStandaloneTracker.reset()
        
        print("输入监听已停止")
    }
    
    // MARK: - 事件处理
    
    private func getAppIdentity(for event: CGEvent) -> AppIdentity? {
        return StatsManager.shared.appStatsEnabled ? AppActivityTracker.shared.appIdentity(for: event) : nil
    }

    private func handleEvent(type: CGEventType, event: CGEvent) {
        // Optimization: Fast path for mouse moves to avoid allocations
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged:
            handleMouseMove(event: event)
            return
        default:
            break
        }

        let statsManager = StatsManager.shared
        
        switch type {
        case .keyDown:
            // 忽略自动重复的按键（按住不放产生的重复事件）
            let isAutoRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if !isAutoRepeat {
                if statsManager.handleMouseDistanceCalibrationKeyPress() {
                    return
                }
                let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
                modifierStandaloneTracker.consumePendingModifiers(forKeyDownWith: event.flags.rawValue, keyCode: keyCode)
                let keyName = keyName(for: event)
                statsManager.incrementKeyPresses(keyName: keyName, appIdentity: getAppIdentity(for: event))
            }
            
        case .leftMouseDown:
            if shouldSwapMouseButtons(for: event) {
                statsManager.incrementRightClicks(appIdentity: getAppIdentity(for: event))
            } else {
                statsManager.incrementLeftClicks(appIdentity: getAppIdentity(for: event))
            }
            
        case .rightMouseDown:
            if shouldSwapMouseButtons(for: event) {
                statsManager.incrementLeftClicks(appIdentity: getAppIdentity(for: event))
            } else {
                statsManager.incrementRightClicks(appIdentity: getAppIdentity(for: event))
            }

        case .otherMouseDown:
            let buttonNumber = event.getIntegerValueField(.mouseEventButtonNumber)
            // Common mapping on macOS: 3 = Back, 4 = Forward.
            // Unknown side buttons are grouped into Back to avoid dropping counts.
            if buttonNumber == 4 {
                statsManager.incrementSideForwardClicks(appIdentity: getAppIdentity(for: event))
            } else {
                statsManager.incrementSideBackClicks(appIdentity: getAppIdentity(for: event))
            }
            
        case .scrollWheel:
            handleScroll(event: event, appIdentity: getAppIdentity(for: event))

        case .flagsChanged:
            let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            if keyCode == 57 { // CapsLock
                statsManager.incrementKeyPresses(keyName: "CapsLock", appIdentity: getAppIdentity(for: event))
            } else if let modifierKeyName = modifierStandaloneTracker.handleFlagsChanged(
                keyCode: keyCode,
                rawFlags: event.flags.rawValue
            ) {
                statsManager.incrementKeyPresses(keyName: modifierKeyName, appIdentity: getAppIdentity(for: event))
            }

        default:
            break
        }
    }

    private func keyName(for event: CGEvent) -> String {
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let baseName = baseKeyName(for: keyCode, event: event)
        let modifiers = keyboardEventModifierNames(rawFlags: event.flags.rawValue, keyCode: keyCode)
        if modifiers.isEmpty {
            return baseName
        }
        return modifiers.joined(separator: "+") + "+" + baseName
    }

    private func isPrimaryButtonRight() -> Bool {
        let key = swapLeftRightButtonKey as CFString
        if let value = CFPreferencesCopyValue(key, kCFPreferencesAnyApplication, kCFPreferencesAnyUser, kCFPreferencesCurrentHost) as? NSNumber {
            return value.boolValue
        }
        if let value = CFPreferencesCopyValue(key, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? NSNumber {
            return value.boolValue
        }
        if let value = UserDefaults.standard.object(forKey: swapLeftRightButtonKey) as? NSNumber {
            return value.boolValue
        }
        return false
    }

    private func shouldSwapMouseButtons(for event: CGEvent) -> Bool {
        guard isPrimaryButtonRight() else { return false }
        // "Primary mouse button" applies to mice; trackpad primary click remains left.
        guard let nsEvent = NSEvent(cgEvent: event) else { return false }
        switch nsEvent.subtype {
        case .mouseEvent:
            return true
        case .tabletPoint, .tabletProximity, .touch:
            return false
        default:
            return true
        }
    }

    private func baseKeyName(for keyCode: Int, event: CGEvent) -> String {
        if let mapped = Self.keyCodeMap[keyCode] {
            return mapped
        }
        if let asciiName = asciiKeyName(for: keyCode, event: event) {
            return asciiName
        }
        return "Key\(keyCode)"
    }

    private static let keyCodeMap: [Int: String] = [
        36: "Return",
        48: "Tab",
        49: "Space",
        51: "Delete",
        53: "Esc",
        63: "Fn",
        64: "F17",
        71: "Clear",
        76: "Enter",
        79: "F18",
        80: "F19",
        96: "F5",
        97: "F6",
        98: "F7",
        99: "F3",
        100: "F8",
        101: "F9",
        103: "F11",
        105: "F13",
        106: "F16",
        107: "F14",
        109: "F10",
        111: "F12",
        113: "F15",
        114: "Help",
        115: "Home",
        116: "PageUp",
        117: "ForwardDelete",
        118: "F4",
        119: "End",
        120: "F2",
        121: "PageDown",
        122: "F1",
        123: "Left",
        124: "Right",
        125: "Down",
        126: "Up",
        179: "Fn"
    ]

    // MARK: - Keyboard Layout

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

    private func asciiKeyName(for keyCode: Int, event: CGEvent) -> String? {
        layoutLock.lock()
        let layoutData = cachedLayoutData
        layoutLock.unlock()
        guard let layoutData = layoutData else { return nil }
        guard let layoutPtr = CFDataGetBytePtr(layoutData) else { return nil }
        let keyboardLayout = unsafeBitCast(layoutPtr, to: UnsafePointer<UCKeyboardLayout>.self)

        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var actualLength: Int = 0
        let keyboardType = UInt32(event.getIntegerValueField(.keyboardEventKeyboardType))
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
        guard !cleaned.isEmpty else { return nil }
        guard cleaned.count == 1 else { return nil }
        if cleaned == " " { return "Space" }
        if cleaned == "\t" { return "Tab" }
        if cleaned == "\r" { return "Return" }
        return cleaned.uppercased()
    }
    
    private func handleMouseMove(event: CGEvent) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastMouseSampleTime >= mouseSampleInterval else { return }
        let currentPosition = event.location
        let statsManager = StatsManager.shared
        
        if let lastPosition = statsManager.lastMousePosition {
            // 计算移动距离
            let dx = currentPosition.x - lastPosition.x
            let dy = currentPosition.y - lastPosition.y
            let distance = sqrt(dx * dx + dy * dy)
            
            // 过滤掉异常的大距离（可能是鼠标跳跃）
            if distance < 500 {
                if statsManager.isMouseDistanceCalibrating {
                    statsManager.recordMouseDistanceCalibration(distance)
                } else {
                    statsManager.addMouseDistance(distance)
                }
            }
        }
        
        statsManager.lastMousePosition = currentPosition
        lastMouseSampleTime = now
    }
    
    private func handleScroll(event: CGEvent, appIdentity: AppIdentity?) {
        // 获取滚动距离
        let deltaY = event.getDoubleValueField(.scrollWheelEventDeltaAxis1)
        let deltaX = event.getDoubleValueField(.scrollWheelEventDeltaAxis2)
        
        // 计算总滚动距离
        let totalDelta = sqrt(deltaX * deltaX + deltaY * deltaY)
        
        StatsManager.shared.addScrollDistance(totalDelta * 10, appIdentity: appIdentity) // 放大系数使数据更直观
    }
}
