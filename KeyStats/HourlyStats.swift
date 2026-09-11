import Foundation

/// Aggregate counters only. The recording time zone stays fixed so travel
/// cannot move previously recorded counts into a different hour or date.
struct HourlyStats: Codable, Equatable {
    struct Counts: Codable, Equatable {
        var keys = 0
        var clicks = 0
    }

    struct Point {
        let date: Date
        let counts: Counts?
    }

    let startedAt: Date
    let timeZoneIdentifier: String
    private var buckets: [String: Counts] = [:]
    private(set) var recordedThrough: Date?

    init(startedAt: Date = Date(), timeZone: TimeZone = .current) {
        self.startedAt = startedAt
        timeZoneIdentifier = timeZone.identifier
    }

    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
        return calendar
    }

    mutating func record(keys: Int = 0, clicks: Int = 0, at date: Date = Date()) {
        guard date >= startedAt,
              let hour = Self.hourInterval(containing: date, calendar: calendar) else { return }
        let key = bucketKey(hour.start)
        var counts = buckets[key] ?? Counts()
        counts.keys = saturatingNonnegativeSum([counts.keys, keys])
        counts.clicks = saturatingNonnegativeSum([counts.clicks, clicks])
        buckets[key] = counts
    }

    /// Includes the current, incomplete hour and the 23 preceding hourly buckets.
    func points(on date: Date, recent24Hours: Bool, now: Date = Date()) -> [Point] {
        let availableThrough = min(now, recordedThrough ?? now)
        let start: Date
        let end: Date
        if recent24Hours {
            guard let hour = Self.hourInterval(containing: now, calendar: calendar) else { return [] }
            var first = hour
            for _ in 0..<23 {
                guard let previous = Self.hourInterval(containing: first.start.addingTimeInterval(-0.001), calendar: calendar) else { return [] }
                first = previous
            }
            start = first.start
            end = hour.end
        } else {
            guard let day = calendar.dateInterval(of: .day, for: date) else { return [] }
            start = day.start
            end = day.end
        }
        var result: [Point] = []
        var hour = start
        while hour < end {
            guard let interval = Self.hourInterval(containing: hour, calendar: calendar), interval.end > hour else { break }
            let available = hour <= availableThrough && interval.end > startedAt
            result.append(Point(date: hour, counts: available ? (buckets[bucketKey(hour)] ?? Counts()) : nil))
            hour = interval.end
        }
        return result
    }


    private enum CodingKeys: String, CodingKey {
        case startedAt, timeZoneIdentifier, buckets, recordedThrough
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        startedAt = try values.decode(Date.self, forKey: .startedAt)
        timeZoneIdentifier = try values.decode(String.self, forKey: .timeZoneIdentifier)
        buckets = try values.decode([String: Counts].self, forKey: .buckets)
        recordedThrough = try values.decodeIfPresent(Date.self, forKey: .recordedThrough)
        // Older Foundation hour intervals can start before a half-hour clock
        // transition. Move those legacy keys to the actual transition boundary.
        for (key, counts) in buckets {
            guard counts.keys >= 0, counts.clicks >= 0 else { throw SyncValidationError.invalidSnapshot }
            guard let timestamp = Int64(key) else { continue }
            let date = Date(timeIntervalSince1970: Double(timestamp))
            guard Self.hourInterval(containing: date, calendar: calendar)?.start != date,
                  let transition = calendar.timeZone.nextDaylightSavingTimeTransition(after: date),
                  transition < date.addingTimeInterval(3600),
                  calendar.dateInterval(of: .hour, for: date.addingTimeInterval(3599))?.start == date else { continue }
            let replacement = bucketKey(transition)
            let old = buckets[replacement] ?? Counts()
            buckets[replacement] = Counts(keys: saturatingNonnegativeSum([old.keys, counts.keys]),
                                          clicks: saturatingNonnegativeSum([old.clicks, counts.clicks]))
            buckets.removeValue(forKey: key)
        }
        try validate()
    }

    func validate(day: String? = nil) throws {
        guard TimeZone(identifier: timeZoneIdentifier) != nil,
              startedAt.timeIntervalSince1970.isFinite,
              recordedThrough.map({ $0.timeIntervalSince1970.isFinite && $0 >= startedAt }) ?? true,
              day == nil || buckets.count <= 26 else { throw SyncValidationError.invalidSnapshot }
        for (key, counts) in buckets {
            guard let timestamp = Int64(key), String(timestamp) == key,
                  counts.keys >= 0, counts.clicks >= 0 else { throw SyncValidationError.invalidSnapshot }
            let date = Date(timeIntervalSince1970: Double(timestamp))
            guard let hour = Self.hourInterval(containing: date, calendar: calendar), hour.start == date,
                  hour.end > startedAt, recordedThrough.map({ date <= $0 }) ?? true,
                  day.map({ dayKey(date) == $0 }) ?? true else { throw SyncValidationError.invalidSnapshot }
        }
    }

    /// Optional per-day extension to the existing encrypted sync record.
    /// A stable end-of-day cutoff avoids re-uploading unchanged archives.
    func syncShards(now: Date = Date()) -> [String: HourlyStats] {
        let grouped = Dictionary(grouping: buckets.keys) { key in
            dayKey(Date(timeIntervalSince1970: Double(Int64(key) ?? 0)))
        }
        var result: [String: HourlyStats] = [:]
        // Retain known zero days as well as days with events. Local points use
        // this same continuous recording period, so archives must preserve it.
        var days: [String: DateInterval] = [:]
        var cursor = startedAt
        while cursor <= now, let interval = calendar.dateInterval(of: .day, for: cursor), interval.end > cursor {
            days[dayKey(cursor)] = interval
            cursor = interval.end
        }
        for (day, interval) in days {
            var shard = self
            shard.buckets = Dictionary(uniqueKeysWithValues: (grouped[day] ?? []).compactMap { key in
                buckets[key].map { (key, $0) }
            })
            shard.recordedThrough = max(startedAt, min(now, interval.end.addingTimeInterval(-0.001)))
            result[day] = shard
        }
        return result
    }

    /// Merge imports using the same additive policy as daily statistics.
    /// Different hour boundaries cannot be reconstructed from aggregate counts.
    func mergingImport(_ other: HourlyStats) throws -> HourlyStats {
        guard timeZoneIdentifier == other.timeZoneIdentifier else { throw HourlyStatsImportError.differentTimeZones }
        var merged = HourlyStats(startedAt: min(startedAt, other.startedAt), timeZone: calendar.timeZone)
        merged.buckets = buckets
        for (key, value) in other.buckets {
            let old = merged.buckets[key] ?? Counts()
            merged.buckets[key] = Counts(keys: saturatingNonnegativeSum([old.keys, value.keys]),
                                        clicks: saturatingNonnegativeSum([old.clicks, value.clicks]))
        }
        return merged
    }

    func forLocalRecording() -> HourlyStats {
        var copy = self
        copy.recordedThrough = nil
        return copy
    }

    /// Call only after selecting the latest revision of each device/day shard.
    static func combineShards(_ shards: [HourlyStats]) -> HourlyStats? {
        guard let first = shards.first,
              shards.allSatisfy({ $0.timeZoneIdentifier == first.timeZoneIdentifier }) else { return nil }
        var result = HourlyStats(startedAt: shards.map(\.startedAt).min() ?? first.startedAt, timeZone: first.calendar.timeZone)
        for shard in shards {
            for (key, counts) in shard.buckets {
                result.buckets[key] = counts
            }
        }
        result.recordedThrough = shards.compactMap(\.recordedThrough).max()
        return result
    }

    /// Like daily sync, compare each device's local date/hour, not a rebinned
    /// absolute timeline (an aggregate cannot be split across time-zone offsets).
    func countsAligned(to target: [Point], calendar displayCalendar: Calendar, now: Date) -> [Counts?] {
        var result = Array<Counts?>(repeating: nil, count: target.count)
        let dayGroups = Dictionary(grouping: target.indices) { index in
            let parts = displayCalendar.dateComponents([.year, .month, .day], from: target[index].date)
            return parts
        }
        for (day, indices) in dayGroups {
            var noon = day
            noon.hour = 12
            guard let sourceDate = calendar.date(from: noon) else { continue }
            let source = points(on: sourceDate, recent24Hours: false, now: now)
            guard let firstIndex = indices.first,
                  let targetDay = displayCalendar.dateInterval(of: .day, for: target[firstIndex].date) else { continue }
            var fullDay: [Date] = []
            var cursor = targetDay.start
            while cursor < targetDay.end {
                guard let interval = Self.hourInterval(containing: cursor, calendar: displayCalendar), interval.end > cursor else { break }
                fullDay.append(cursor)
                cursor = interval.end
            }
            let targetHours = Dictionary(grouping: fullDay) { displayCalendar.component(.hour, from: $0) }
            let visibleIndices = Dictionary(uniqueKeysWithValues: indices.map { (target[$0].date, $0) })
            let sourceHours = Dictionary(grouping: source) { calendar.component(.hour, from: $0.date) }
            for (hour, sourcePoints) in sourceHours {
                // A remote clock hour may not exist on this device's spring
                // transition day. Preserve its counts in the next valid slot
                // (or the last slot when the jump ends the local day).
                let destinationHour = targetHours[hour] != nil ? hour
                    : (targetHours.keys.filter { $0 > hour }.min() ?? targetHours.keys.max())
                guard let destinationHour, let slots = targetHours[destinationHour] else { continue }
                for (occurrence, point) in sourcePoints.enumerated() {
                    guard let counts = point.counts else { continue }
                    // Preserve repeated hours when present on both devices; otherwise
                    // combine the repeated source hour into the available target hour.
                    guard let index = visibleIndices[slots[min(occurrence, slots.count - 1)]] else { continue }
                    let previous = result[index] ?? Counts()
                    result[index] = Counts(keys: saturatingNonnegativeSum([previous.keys, counts.keys]),
                                           clicks: saturatingNonnegativeSum([previous.clicks, counts.clicks]))
                }
            }
        }
        return result
    }

    /// Clear only the requested local calendar day; rollover never calls this.
    mutating func reset(on date: Date, calendar resetCalendar: Calendar? = nil) {
        guard let day = (resetCalendar ?? calendar).dateInterval(of: .day, for: date) else { return }
        buckets = buckets.filter { key, _ in
            guard let timestamp = Int64(key) else { return false }
            let start = Date(timeIntervalSince1970: Double(timestamp))
            return start < day.start || start >= day.end
        }
    }

    /// Wall-clock hours split at offset transitions, including 30-minute DST
    /// changes. Foundation's hour interval can overlap its predecessor there.
    private static func hourInterval(containing date: Date, calendar: Calendar) -> DateInterval? {
        let zone = calendar.timeZone
        let offset = Double(zone.secondsFromGMT(for: date))
        let timestamp = date.timeIntervalSince1970
        guard timestamp.isFinite else { return nil }
        let nominalStart = Date(timeIntervalSince1970: floor((timestamp + offset) / 3600) * 3600 - offset)
        var start = nominalStart
        var end = nominalStart.addingTimeInterval(3600)
        if let transition = zone.nextDaylightSavingTimeTransition(after: nominalStart.addingTimeInterval(-0.001)), transition <= date {
            start = max(start, transition)
        }
        if let transition = zone.nextDaylightSavingTimeTransition(after: date), transition < end {
            end = transition
        }
        guard start <= date, date < end else { return nil }
        return DateInterval(start: start, end: end)
    }

    private func dayKey(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private func bucketKey(_ date: Date) -> String {
        String(Int64(date.timeIntervalSince1970))
    }
}

enum HourlyStatsImportError: LocalizedError {
    case differentTimeZones

    var errorDescription: String? {
        NSLocalizedString("hourly.import.differentTimeZones", comment: "")
    }
}
