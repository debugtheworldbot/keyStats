import Foundation
import CoreGraphics
import AppKit

enum PayloadBuilder {
    static func build(from event: CGEvent, type: CGEventType) -> [String: Any]? {
        var p: [String: Any] = [
            HelperPayloadFields.type: NSNumber(value: type.rawValue),
            HelperPayloadFields.monotonicTime: NSNumber(value: ProcessInfo.processInfo.systemUptime)
        ]

        // Capture the receiving app before XPC delivery; the foreground app may change
        // before the main process handles this payload. The source PID identifies the
        // event producer (often an input helper), not the app receiving the input.
        if let app = NSWorkspace.shared.frontmostApplication,
           app.activationPolicy == .regular,
           let bundleID = app.bundleIdentifier {
            p[HelperPayloadFields.foregroundBundleID] = bundleID
            p[HelperPayloadFields.foregroundName] = app.localizedName ?? ""
        }

        switch type {
        case .keyDown, .flagsChanged:
            p[HelperPayloadFields.keyCode] = NSNumber(value: event.getIntegerValueField(.keyboardEventKeycode))
            p[HelperPayloadFields.keyboardType] = NSNumber(value: event.getIntegerValueField(.keyboardEventKeyboardType))
            p[HelperPayloadFields.flags] = NSNumber(value: event.flags.rawValue)
            p[HelperPayloadFields.isAutoRepeat] = NSNumber(value: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)

        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            if let role = ButtonRoleClassifier.role(for: type, event: event) {
                p[HelperPayloadFields.buttonRole] = role as NSString
            }
            p[HelperPayloadFields.buttonNumber] = NSNumber(value: event.getIntegerValueField(.mouseEventButtonNumber))

        case .mouseMoved, .leftMouseDragged, .rightMouseDragged:
            let loc = event.location
            p[HelperPayloadFields.locationX] = NSNumber(value: Double(loc.x))
            p[HelperPayloadFields.locationY] = NSNumber(value: Double(loc.y))

        case .scrollWheel:
            p[HelperPayloadFields.scrollDX] = NSNumber(value: event.getDoubleValueField(.scrollWheelEventDeltaAxis2))
            p[HelperPayloadFields.scrollDY] = NSNumber(value: event.getDoubleValueField(.scrollWheelEventDeltaAxis1))

        default:
            return nil
        }
        return p
    }
}
