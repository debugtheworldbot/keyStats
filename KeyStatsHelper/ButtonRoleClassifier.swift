import Foundation
import Cocoa
import CoreGraphics

enum ButtonRoleClassifier {
    private static let swapLeftRightButtonKey = "com.apple.mouse.swapLeftRightButton"

    static func role(for type: CGEventType, event: CGEvent) -> String? {
        switch type {
        case .leftMouseDown:
            return shouldSwap(for: event) ? ButtonRole.secondary : ButtonRole.primary
        case .rightMouseDown:
            return shouldSwap(for: event) ? ButtonRole.primary : ButtonRole.secondary
        case .otherMouseDown:
            let button = event.getIntegerValueField(.mouseEventButtonNumber)
            return button == 4 ? ButtonRole.forward : ButtonRole.back
        default:
            return nil
        }
    }

    private static func shouldSwap(for event: CGEvent) -> Bool {
        guard isPrimaryButtonRight() else { return false }
        guard let ns = NSEvent(cgEvent: event) else { return false }
        switch ns.subtype {
        case .mouseEvent: return true
        case .tabletPoint, .tabletProximity, .touch: return false
        default: return true
        }
    }

    private static func isPrimaryButtonRight() -> Bool {
        let key = swapLeftRightButtonKey as CFString
        if let v = CFPreferencesCopyValue(key, kCFPreferencesAnyApplication, kCFPreferencesAnyUser, kCFPreferencesCurrentHost) as? NSNumber {
            return v.boolValue
        }
        if let v = CFPreferencesCopyValue(key, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? NSNumber {
            return v.boolValue
        }
        if let v = UserDefaults.standard.object(forKey: swapLeftRightButtonKey) as? NSNumber {
            return v.boolValue
        }
        return false
    }
}
