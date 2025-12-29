import Foundation
import Cocoa
import CoreGraphics

/// 输入事件监听器
class InputMonitor {
    static let shared = InputMonitor()
    
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isMonitoring = false
    
    private init() {}
    
    // MARK: - 权限检查
    
    /// 检查是否有辅助功能权限
    func checkAccessibilityPermission() -> Bool {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(options)
    }
    
    /// 仅检查权限状态（不弹出提示）
    func hasAccessibilityPermission() -> Bool {
        return AXIsProcessTrusted()
    }
    
    // MARK: - 开始/停止监听
    
    func startMonitoring() {
        guard !isMonitoring else { return }
        
        // 检查权限
        guard checkAccessibilityPermission() else {
            print("需要辅助功能权限才能监听输入事件")
            return
        }
        
        // 创建事件掩码 - 监听键盘、鼠标点击、鼠标移动和滚动事件
        let eventMask: CGEventMask = (
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue)
        )
        
        // 创建事件回调
        let callback: CGEventTapCallBack = { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
            InputMonitor.shared.handleEvent(type: type, event: event)
            return Unmanaged.passRetained(event)
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
        
        print("输入监听已停止")
    }
    
    // MARK: - 事件处理
    
    private func handleEvent(type: CGEventType, event: CGEvent) {
        let statsManager = StatsManager.shared
        
        switch type {
        case .keyDown:
            let keyName = keyName(for: event)
            statsManager.incrementKeyPresses(keyName: keyName)
            
        case .leftMouseDown:
            statsManager.incrementLeftClicks()
            
        case .rightMouseDown:
            statsManager.incrementRightClicks()
            
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged:
            handleMouseMove(event: event)
            
        case .scrollWheel:
            handleScroll(event: event)
            
        default:
            break
        }
    }

    private func keyName(for event: CGEvent) -> String {
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let baseName = baseKeyName(for: keyCode, event: event)
        let modifiers = modifierNames(for: event.flags)
        if modifiers.isEmpty {
            return baseName
        }
        return modifiers.joined(separator: "+") + "+" + baseName
    }

    private func modifierNames(for flags: CGEventFlags) -> [String] {
        var names: [String] = []
        if flags.contains(.maskCommand) { names.append("Cmd") }
        if flags.contains(.maskShift) { names.append("Shift") }
        if flags.contains(.maskAlternate) { names.append("Option") }
        if flags.contains(.maskControl) { names.append("Ctrl") }
        if flags.contains(.maskSecondaryFn) { names.append("Fn") }
        return names
    }

    private func baseKeyName(for keyCode: Int, event: CGEvent) -> String {
        if let mapped = Self.keyCodeMap[keyCode] {
            return mapped
        }
        if let nsEvent = NSEvent(cgEvent: event),
           let chars = nsEvent.charactersIgnoringModifiers,
           !chars.isEmpty {
            if chars == " " { return "Space" }
            if chars == "\t" { return "Tab" }
            if chars == "\r" { return "Return" }
            let cleaned = chars.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                if cleaned.count == 1 {
                    return cleaned.uppercased()
                }
                return cleaned
            }
        }
        return "Key\(keyCode)"
    }

    private static let keyCodeMap: [Int: String] = [
        36: "Return",
        48: "Tab",
        49: "Space",
        51: "Delete",
        53: "Esc",
        71: "Clear",
        76: "Enter",
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
        126: "Up"
    ]
    
    private func handleMouseMove(event: CGEvent) {
        let currentPosition = event.location
        let statsManager = StatsManager.shared
        
        if let lastPosition = statsManager.lastMousePosition {
            // 计算移动距离
            let dx = currentPosition.x - lastPosition.x
            let dy = currentPosition.y - lastPosition.y
            let distance = sqrt(dx * dx + dy * dy)
            
            // 过滤掉异常的大距离（可能是鼠标跳跃）
            if distance < 500 {
                statsManager.addMouseDistance(distance)
            }
        }
        
        statsManager.lastMousePosition = currentPosition
    }
    
    private func handleScroll(event: CGEvent) {
        // 获取滚动距离
        let deltaY = event.getDoubleValueField(.scrollWheelEventDeltaAxis1)
        let deltaX = event.getDoubleValueField(.scrollWheelEventDeltaAxis2)
        
        // 计算总滚动距离
        let totalDelta = sqrt(deltaX * deltaX + deltaY * deltaY)
        
        StatsManager.shared.addScrollDistance(totalDelta * 10) // 放大系数使数据更直观
    }
}
