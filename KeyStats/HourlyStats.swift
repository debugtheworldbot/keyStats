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
              let hour = calendar.dateInterval(of: .hour, for: date) else { return }
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
            guard let hour = calendar.dateInterval(of: .hour, for: now) else { return [] }
            start = hour.start.addingTimeInterval(-23 * 3600)
            end = hour.end
        } else {
            guard let day = calendar.dateInterval(of: .day, for: date) else { return [] }
            start = day.start
            end = day.end
        }
        var result: [Point] = []
        var hour = start
        while hour < end {
            let available = hour <= availableThrough && hour.addingTimeInterval(3600) > startedAt
            result.append(Point(date: hour, counts: available ? (buckets[bucketKey(hour)] ?? Counts()) : nil))
            hour = hour.addingTimeInterval(3600)
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
            guard let hour = calendar.dateInterval(of: .hour, for: date), hour.start == date,
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
        let currentDay = dayKey(now)
        for day in Set(grouped.keys).union([currentDay]) {
            var shard = self
            shard.buckets = Dictionary(uniqueKeysWithValues: (grouped[day] ?? []).compactMap { key in
                buckets[key].map { (key, $0) }
            })
            let sample = shard.buckets.keys.first.flatMap(Int64.init).map { Date(timeIntervalSince1970: Double($0)) } ?? now
            let end = calendar.dateInterval(of: .day, for: sample)?.end ?? now
            shard.recordedThrough = max(startedAt, min(now, end.addingTimeInterval(-0.001)))
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
            let fullDay = stride(from: targetDay.start.timeIntervalSince1970,
                                 to: targetDay.end.timeIntervalSince1970, by: 3600).map { Date(timeIntervalSince1970: $0) }
            let targetHours = Dictionary(grouping: fullDay) { displayCalendar.component(.hour, from: $0) }
            let visibleIndices = Dictionary(uniqueKeysWithValues: indices.map { (target[$0].date, $0) })
            let sourceHours = Dictionary(grouping: source) { calendar.component(.hour, from: $0.date) }
            for (hour, sourcePoints) in sourceHours {
                guard let slots = targetHours[hour] else { continue }
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
