import Foundation

/// Only suppresses copies retaining the original event timestamp and key state.
/// Newly generated events remain countable even when they arrive close together.
struct InputEventDeduplicator {
    private struct Signature: Hashable {
        let type: UInt32
        let detail: Int64
        let timestamp: UInt64
        let flags: UInt64
    }

    private var recentHardwareEvents: [Signature: TimeInterval] = [:]
    private let duplicateWindow: TimeInterval = 0.08
    private let maximumRecentEvents = 256

    mutating func shouldDrop(type: UInt32, detail: Int64, sourcePID: Int64,
                             eventTimestamp: UInt64, flags: UInt64, time: TimeInterval) -> Bool {
        recentHardwareEvents = recentHardwareEvents.filter {
            time >= $0.value && time - $0.value < duplicateWindow
        }
        // Missing timestamps cannot establish that two events are copies.
        guard eventTimestamp != 0 else { return false }
        let signature = Signature(type: type, detail: detail, timestamp: eventTimestamp, flags: flags)
        if sourcePID > 0 {
            return recentHardwareEvents[signature] != nil
        }
        if recentHardwareEvents.count >= maximumRecentEvents,
           let oldest = recentHardwareEvents.min(by: { $0.value < $1.value })?.key {
            recentHardwareEvents.removeValue(forKey: oldest)
        }
        recentHardwareEvents[signature] = time
        return false
    }
}
