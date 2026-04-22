import Foundation
import CoreGraphics

/// MVP：只打印事件，确认 XPC 通路打通。
/// Phase 4 再替换为喂 StatsManager。
final class RemoteEventProcessor: NSObject, KeyStatsEventSinkProtocol {
    static let shared = RemoteEventProcessor()

    private var counter = 0
    private let lock = NSLock()

    private override init() { super.init() }

    func receiveEvent(_ payload: [String: Any]) {
        lock.lock()
        counter += 1
        let n = counter
        lock.unlock()

        let typeRaw = (payload[HelperPayloadFields.type] as? NSNumber)?.uint32Value ?? 0
        let typeName = typeName(typeRaw)

        // 每 30 个打一次，避免 flood
        if n % 30 == 1 {
            NSLog("[RemoteEventProcessor] #\(n) type=\(typeName)(\(typeRaw)) keys=\(payload.keys.sorted())")
        }
    }

    private func typeName(_ raw: UInt32) -> String {
        switch CGEventType(rawValue: raw) {
        case .keyDown: return "keyDown"
        case .flagsChanged: return "flagsChanged"
        case .leftMouseDown: return "leftMouseDown"
        case .rightMouseDown: return "rightMouseDown"
        case .otherMouseDown: return "otherMouseDown"
        case .mouseMoved: return "mouseMoved"
        case .leftMouseDragged: return "leftMouseDragged"
        case .rightMouseDragged: return "rightMouseDragged"
        case .scrollWheel: return "scrollWheel"
        default: return "other"
        }
    }
}
