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

extension HourlyStatsTests {
    private func snapshot(_ hourly: HourlyStats?, day: String = "2026-09-10", device: String = "remote", revision: Int64 = 1) -> CoreDaySnapshotV1 {
        CoreDaySnapshotV1(deviceId: device, localDay: day, revision: revision,
                          keyPresses: 10, keyPressCounts: [:], clicks: .zero, hourlyStats: hourly)
    }

    func testBackupRoundTripAndLegacyBackupWithoutHourlyField() throws {
        let start = date("2026-09-10T10:00:00Z")
        var hourly = HourlyStats(startedAt: start, timeZone: TimeZone(secondsFromGMT: 0)!)
        hourly.record(keys: 5, clicks: 3, at: start)
        let payload = StatsExportPayload(version: 1, scope: "currentDevice", exportedAt: start,
                                         currentStats: DailyStats(date: start), history: [:], hourlyStats: hourly)
        let decoded = try SyncJSON.decoder.decode(StatsExportPayload.self, from: SyncJSON.encoder.encode(payload))
        XCTAssertEqual(decoded.hourlyStats, hourly)
        let legacy = StatsExportPayload(version: 1, scope: nil, exportedAt: start,
                                        currentStats: DailyStats(date: start), history: [:], hourlyStats: nil)
        let data = try SyncJSON.encoder.encode(legacy)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("hourlyStats"))
        XCTAssertNil(try SyncJSON.decoder.decode(StatsExportPayload.self, from: data).hourlyStats)
    }

    func testHourlyImportMergeAndTimeZoneMismatch() throws {
        let start = date("2026-09-10T10:00:00Z")
        var local = HourlyStats(startedAt: start, timeZone: TimeZone(secondsFromGMT: 0)!)
        var imported = local
        local.record(keys: 2, at: start)
        imported.record(keys: 3, clicks: 4, at: start)
        let result = try local.mergingImport(imported)
        let points = result.points(on: start, recent24Hours: false, now: start)
        XCTAssertEqual(points[10].counts, HourlyStats.Counts(keys: 5, clicks: 4))
        let differentZone = HourlyStats(startedAt: start, timeZone: TimeZone(identifier: "Asia/Shanghai")!)
        XCTAssertThrowsError(try local.mergingImport(differentZone))
        XCTAssertEqual(local.points(on: start, recent24Hours: false, now: start)[10].counts?.keys, 2)
    }

    func testHourlyEncryptedRoundTripAndHashTracksDistributionNotJustDailyTotal() throws {
        let start = date("2026-09-10T10:00:00Z")
        let now = date("2026-09-10T12:00:00Z")
        var a = HourlyStats(startedAt: start, timeZone: TimeZone(secondsFromGMT: 0)!)
        var b = a
        a.record(keys: 10, at: start)
        b.record(keys: 10, at: start.addingTimeInterval(3600))
        let first = snapshot(a.syncShards(now: now)["2026-09-10"])
        let second = snapshot(b.syncShards(now: now)["2026-09-10"])
        XCTAssertNotEqual(try SyncCrypto.contentHash(first), try SyncCrypto.contentHash(second))
        let record = try SyncCrypto.encrypt(snapshot: first, vaultId: "vault", seed: Data(0..<16))
        let restored = try SyncCrypto.decrypt(record: record, vaultId: "vault", seed: Data(0..<16))
        XCTAssertEqual(restored, first)
        XCTAssertThrowsError(try snapshot(first.hourlyStats, day: "2026-09-09").validated())
        XCTAssertNil(try SyncJSON.decoder.decode(CoreDaySnapshotV1.self,
                                                from: SyncJSON.encoder.encode(snapshot(nil))).hourlyStats)
    }

    func testHourlyArchivesHaveStableHashAndStaleRemoteHoursStayUnknown() throws {
        let start = date("2026-09-09T10:00:00Z")
        var hourly = HourlyStats(startedAt: start, timeZone: TimeZone(secondsFromGMT: 0)!)
        hourly.record(keys: 3, at: start)
        let a = hourly.syncShards(now: date("2026-09-10T12:00:00Z"))
        let b = hourly.syncShards(now: date("2026-09-11T12:00:00Z"))
        XCTAssertEqual(try SyncCrypto.contentHash(snapshot(a["2026-09-09"], day: "2026-09-09")),
                       try SyncCrypto.contentHash(snapshot(b["2026-09-09"], day: "2026-09-09")))
        let combined = try XCTUnwrap(HourlyStats.combineShards(Array(a.values)))
        let points = combined.points(on: date("2026-09-10T12:00:00Z"), recent24Hours: false,
                                     now: date("2026-09-11T12:00:00Z"))
        XCTAssertNotNil(points[12].counts)
        XCTAssertNil(points[13].counts)
    }

    func testSyncedHourlyCacheRestartAndDuplicateRevisionsDoNotAccumulate() throws {
        let start = date("2026-09-10T10:00:00Z")
        var local = HourlyStats(startedAt: start, timeZone: TimeZone(secondsFromGMT: 0)!)
        local.record(keys: 2, clicks: 1, at: start)
        var remote = HourlyStats(startedAt: start, timeZone: TimeZone(secondsFromGMT: 0)!)
        remote.record(keys: 3, clicks: 4, at: start)
        let old = snapshot(remote.syncShards(now: start)["2026-09-10"])
        remote.record(keys: 2, at: start)
        let latest = snapshot(remote.syncShards(now: start)["2026-09-10"], revision: 2)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("hourly-cache-\(UUID().uuidString).json")
        let cache = RemoteShardCache(fileURL: path)
        XCTAssertEqual(try cache.apply(recordId: "record", snapshot: old, currentDeviceId: "local"), .inserted)
        XCTAssertEqual(try cache.apply(recordId: "record", snapshot: latest, currentDeviceId: "local"), .replaced)
        XCTAssertEqual(try cache.apply(recordId: "record", snapshot: latest, currentDeviceId: "local"), .unchanged)
        let restored = RemoteShardCache(fileURL: path)
        let series = DisplayStatsAggregator.hourlySeries(local: local,
            remote: restored.snapshots() + [old, latest, snapshot(latest.hourlyStats, device: "local")],
            currentDeviceId: "local", date: start, recent24Hours: false, now: start)
        XCTAssertEqual(series.local[10].counts, HourlyStats.Counts(keys: 2, clicks: 1))
        XCTAssertEqual(series.total[10].counts, HourlyStats.Counts(keys: 7, clicks: 5))
        XCTAssertNil(series.total[11].counts)
    }

    func testHourlyTotalsAlignLocalClockHoursLikeDailyTrend() throws {
        let now = date("2026-09-10T12:00:00Z")
        var local = HourlyStats(startedAt: date("2026-09-10T00:00:00Z"), timeZone: TimeZone(secondsFromGMT: 0)!)
        local.record(keys: 2, at: date("2026-09-10T10:00:00Z"))
        var remote = HourlyStats(startedAt: date("2026-09-10T00:00:00Z"), timeZone: TimeZone(identifier: "Asia/Kolkata")!)
        // 10:00 in Kolkata: compare with the local 10:00 bucket, without splitting counts.
        remote.record(keys: 5, at: date("2026-09-10T04:30:00Z"))
        let series = DisplayStatsAggregator.hourlySeries(local: local,
            remote: [snapshot(remote.syncShards(now: now)["2026-09-10"])], currentDeviceId: "local",
            date: now, recent24Hours: false, now: now)
        XCTAssertEqual(series.total[10].counts?.keys, 7)
        XCTAssertEqual(series.total[4].counts?.keys, 0)
    }

    func testMalformedHourlyImportRejectsNegativeCountersAndInvalidZone() throws {
        var hourly = HourlyStats(startedAt: date("2026-09-10T00:00:00Z"), timeZone: TimeZone(secondsFromGMT: 0)!)
        hourly.record(keys: 1, at: date("2026-09-10T10:00:00Z"))
        let data = try SyncJSON.encoder.encode(hourly)
        let json = String(decoding: data, as: UTF8.self)
        let negative = json.replacingOccurrences(of: "\"keys\":1", with: "\"keys\":-1")
        XCTAssertThrowsError(try SyncJSON.decoder.decode(HourlyStats.self, from: Data(negative.utf8)))
        let invalidZone = json.replacingOccurrences(of: hourly.timeZoneIdentifier, with: "Not/A_TimeZone")
        XCTAssertThrowsError(try SyncJSON.decoder.decode(HourlyStats.self, from: Data(invalidZone.utf8)))
    }
}

extension HourlyStatsTests {
    func testRecentWindowDoesNotReincludeRepeatedHourOutsideItsStart() throws {
        let start = date("2026-10-31T00:00:00Z")
        let zone = TimeZone(identifier: "America/New_York")!
        let local = HourlyStats(startedAt: start, timeZone: zone)
        var remote = local
        remote.record(keys: 3, at: date("2026-11-01T05:30:00Z"))
        remote.record(keys: 7, at: date("2026-11-01T06:30:00Z"))
        // The first 01:00 is outside the rolling window, the second is inside.
        let now = date("2026-11-02T05:30:00Z")
        let shards = remote.syncShards(now: now).map { snapshot($0.value, day: $0.key) }
        let series = DisplayStatsAggregator.hourlySeries(local: local, remote: shards,
            currentDeviceId: "local", date: now, recent24Hours: true, now: now)
        XCTAssertEqual(series.total.first?.date, date("2026-11-01T06:00:00Z"))
        XCTAssertEqual(series.total.first?.counts?.keys, 7)
    }
}
