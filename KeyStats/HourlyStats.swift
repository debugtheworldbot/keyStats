import Foundation

/// Local aggregate counters only. The recording time zone stays fixed so travel
/// cannot move previously recorded counts into a different hour or date.
struct HourlyStats: Codable {
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
            let available = hour <= now && hour.addingTimeInterval(3600) > startedAt
            result.append(Point(date: hour, counts: available ? (buckets[bucketKey(hour)] ?? Counts()) : nil))
            hour = hour.addingTimeInterval(3600)
        }
        return result
    }

    private func bucketKey(_ date: Date) -> String {
        String(Int64(date.timeIntervalSince1970))
    }
}
