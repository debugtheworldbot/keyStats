import XCTest
@testable import KeyStatsCore

final class HourlyStatsTests: XCTestCase {
    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    func testUpgradeDoesNotBackfillUnknownHoursAndFutureHoursRemainEmpty() {
        let start = date("2026-09-10T10:30:00Z")
        let stats = HourlyStats(startedAt: start, timeZone: TimeZone(secondsFromGMT: 0)!)
        let points = stats.points(on: start, recent24Hours: false, now: date("2026-09-10T12:15:00Z"))
        XCTAssertEqual(points.count, 24)
        XCTAssertTrue(points.prefix(10).allSatisfy { $0.counts == nil })
        XCTAssertEqual(points[10].counts, HourlyStats.Counts())
        XCTAssertEqual(points[12].counts, HourlyStats.Counts())
        XCTAssertTrue(points.suffix(11).allSatisfy { $0.counts == nil })
        XCTAssertTrue(stats.points(on: date("2026-09-09T00:00:00Z"), recent24Hours: false, now: start).allSatisfy { $0.counts == nil })
    }

    func testHourAndMidnightBoundariesSurvivePersistenceAndFurtherRecording() throws {
        let start = date("2026-09-10T22:00:00Z")
        var stats = HourlyStats(startedAt: start, timeZone: TimeZone(secondsFromGMT: 0)!)
        stats.record(keys: 2, at: date("2026-09-10T22:59:59Z"))
        stats.record(clicks: 3, at: date("2026-09-10T23:00:00Z"))
        let midnight = date("2026-09-11T00:00:00Z")
        stats.record(keys: 4, at: midnight)
        var restored = try JSONDecoder().decode(HourlyStats.self, from: JSONEncoder().encode(stats))
        restored.record(clicks: 1, at: midnight)
        XCTAssertEqual(restored.startedAt, start)
        let yesterday = restored.points(on: start, recent24Hours: false, now: midnight)
        XCTAssertEqual(yesterday[22].counts?.keys, 2)
        XCTAssertEqual(yesterday[23].counts?.clicks, 3)
        let today = restored.points(on: midnight, recent24Hours: false, now: midnight)
        XCTAssertEqual(today[0].counts, HourlyStats.Counts(keys: 4, clicks: 1))
        XCTAssertNil(today[1].counts)
    }

    func testRecentWindowIncludesCurrentHourAndPreceding23Hours() {
        let start = date("2026-09-08T00:00:00Z")
        let stats = HourlyStats(startedAt: start, timeZone: TimeZone(secondsFromGMT: 0)!)
        let points = stats.points(on: start, recent24Hours: true, now: date("2026-09-10T12:45:00Z"))
        XCTAssertEqual(points.count, 24)
        XCTAssertEqual(points.first?.date, date("2026-09-09T13:00:00Z"))
        XCTAssertEqual(points.last?.date, date("2026-09-10T12:00:00Z"))
    }

    func testRepeatedDaylightSavingHourHasDistinctCounts() {
        var stats = HourlyStats(startedAt: date("2026-10-31T00:00:00Z"), timeZone: TimeZone(identifier: "America/New_York")!)
        stats.record(keys: 2, at: date("2026-11-01T05:30:00Z"))
        stats.record(keys: 3, at: date("2026-11-01T06:30:00Z"))
        let points = stats.points(on: date("2026-11-01T12:00:00Z"), recent24Hours: false, now: date("2026-11-02T12:00:00Z"))
        XCTAssertEqual(points.count, 25)
        XCTAssertEqual(points[1].counts?.keys, 2)
        XCTAssertEqual(points[2].counts?.keys, 3)
        XCTAssertEqual(stats.calendar.component(.hour, from: points[1].date), 1)
        XCTAssertEqual(stats.calendar.component(.hour, from: points[2].date), 1)
    }

    func testSpringDaylightSavingDayHas23Hours() {
        let stats = HourlyStats(startedAt: date("2026-03-01T00:00:00Z"), timeZone: TimeZone(identifier: "America/New_York")!)
        let points = stats.points(on: date("2026-03-08T12:00:00Z"), recent24Hours: false, now: date("2026-03-09T12:00:00Z"))
        XCTAssertEqual(points.count, 23)
        XCTAssertFalse(points.contains { stats.calendar.component(.hour, from: $0.date) == 2 })
    }

    func testHalfHourTimeZoneUsesLocalHourBoundaryAndRetainsZone() throws {
        let start = date("2026-09-10T00:00:00Z")
        var stats = HourlyStats(startedAt: start, timeZone: TimeZone(identifier: "Asia/Kolkata")!)
        stats.record(keys: 1, at: date("2026-09-10T00:29:59Z"))
        stats.record(clicks: 1, at: date("2026-09-10T00:30:00Z"))
        let restored = try JSONDecoder().decode(HourlyStats.self, from: JSONEncoder().encode(stats))
        let points = restored.points(on: start, recent24Hours: false, now: date("2026-09-10T01:00:00Z"))
        XCTAssertEqual(restored.calendar.timeZone.identifier, "Asia/Kolkata")
        XCTAssertEqual(points[5].counts?.keys, 1)
        XCTAssertEqual(points[6].counts?.clicks, 1)
    }

    func testCounterOverflowAndEventsBeforeRecordingStart() {
        let start = date("2026-09-10T00:00:00Z")
        var stats = HourlyStats(startedAt: start, timeZone: TimeZone(secondsFromGMT: 0)!)
        stats.record(keys: 100, at: start.addingTimeInterval(-1))
        stats.record(keys: Int.max, clicks: -1, at: start)
        stats.record(keys: 1, at: start)
        let points = stats.points(on: start, recent24Hours: false, now: start)
        XCTAssertEqual(points[0].counts?.keys, Int.max)
        XCTAssertEqual(points[0].counts?.clicks, 0)
    }
}
