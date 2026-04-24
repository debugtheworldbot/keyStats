import Foundation
import Cocoa
import CoreGraphics
import ApplicationServices

protocol EventPayloadSink: AnyObject {
    func forward(payload: [String: Any])
}

final class EventTapController {
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private weak var sink: EventPayloadSink?

    private let mouseSampleInterval: TimeInterval = 1.0 / 30.0
    private var lastMouseSampleTime: TimeInterval = 0
    private let lock = NSLock()

    private static let eventMask: CGEventMask = {
        let keyboard = (1 << CGEventType.keyDown.rawValue) |
                       (1 << CGEventType.flagsChanged.rawValue)
        let mouse = (1 << CGEventType.leftMouseDown.rawValue) |
                    (1 << CGEventType.rightMouseDown.rawValue) |
                    (1 << CGEventType.otherMouseDown.rawValue) |
                    (1 << CGEventType.mouseMoved.rawValue) |
                    (1 << CGEventType.leftMouseDragged.rawValue) |
                    (1 << CGEventType.rightMouseDragged.rawValue) |
                    (1 << CGEventType.scrollWheel.rawValue)
        return CGEventMask(keyboard | mouse)
    }()

    func isAccessibilityGranted() -> Bool {
        AXIsProcessTrusted()
    }

    /// 触发系统的"辅助功能"授权弹窗，同时把 helper 写进 TCC 的列表里。
    /// 单独 `AXIsProcessTrusted()` 不一定会让进程出现在系统设置里 ——
    /// 只有带 prompt 选项的 `AXIsProcessTrustedWithOptions` 才会强制注册。
    @discardableResult
    func promptAccessibilityTrust() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    @discardableResult
    func start(sink: EventPayloadSink) -> Int {
        lock.lock(); defer { lock.unlock() }
        if tap != nil { return HelperErrorCode.alreadyMonitoring }
        guard isAccessibilityGranted() else { return HelperErrorCode.accessibilityDenied }
        self.sink = sink

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let cb: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<EventTapController>.fromOpaque(refcon).takeUnretainedValue()
            me.handle(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }

        guard let t = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: Self.eventMask,
            callback: cb,
            userInfo: ctx
        ) else { return HelperErrorCode.tapCreateFailed }

        tap = t
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return HelperErrorCode.none
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        if let s = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        tap = nil
        runLoopSource = nil
        sink = nil
        lastMouseSampleTime = 0
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return
        }

        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged:
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastMouseSampleTime < mouseSampleInterval { return }
            lastMouseSampleTime = now
        default:
            break
        }

        guard let payload = PayloadBuilder.build(from: event, type: type) else { return }
        sink?.forward(payload: payload)
    }
}
