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

extension HourlyStatsTests {
    func testManualHourlyResetPreservesYesterdayAndPublishesZeroSnapshot() throws {
        let yesterday = date("2026-09-09T10:00:00Z")
        let today = date("2026-09-10T10:00:00Z")
        var hourly = HourlyStats(startedAt: yesterday, timeZone: TimeZone(secondsFromGMT: 0)!)
        hourly.record(keys: 8, clicks: 2, at: yesterday)
        hourly.record(keys: 5, clicks: 3, at: today)
        let before = snapshot(hourly.syncShards(now: today)["2026-09-10"])
        hourly.reset(on: today)
        let restored = try SyncJSON.decoder.decode(HourlyStats.self, from: SyncJSON.encoder.encode(hourly))
        XCTAssertEqual(restored.points(on: yesterday, recent24Hours: false, now: today)[10].counts,
                       HourlyStats.Counts(keys: 8, clicks: 2))
        XCTAssertEqual(restored.points(on: today, recent24Hours: false, now: today)[10].counts,
                       HourlyStats.Counts())
        let after = snapshot(restored.syncShards(now: today)["2026-09-10"], revision: 2)
        XCTAssertNotEqual(try SyncCrypto.contentHash(before), try SyncCrypto.contentHash(after))
        let record = try SyncCrypto.encrypt(snapshot: after, vaultId: "vault", seed: Data(0..<16))
        let remote = try SyncCrypto.decrypt(record: record, vaultId: "vault", seed: Data(0..<16))
        XCTAssertEqual(remote.hourlyStats?.points(on: today, recent24Hours: false, now: today)[10].counts,
                       HourlyStats.Counts())
        hourly.record(keys: 1, at: today)
        XCTAssertEqual(hourly.points(on: today, recent24Hours: false, now: today)[10].counts?.keys, 1)
    }

    func testHalfHourSpringTransitionUsesSameBucketsForRecordingAndBothViews() throws {
        let zone = TimeZone(identifier: "Australia/Lord_Howe")!
        let start = date("2026-10-03T00:00:00Z")
        let partialHour = date("2026-10-03T15:45:00Z") // 02:45 after the jump
        let regularHour = date("2026-10-03T16:15:00Z") // 03:15
        var hourly = HourlyStats(startedAt: start, timeZone: zone)
        hourly.record(keys: 7, at: partialHour)
        hourly.record(keys: 9, at: regularHour)
        let daily = hourly.points(on: regularHour, recent24Hours: false, now: regularHour)
        XCTAssertEqual(daily.reduce(0) { $0 + ($1.counts?.keys ?? 0) }, 16)
        XCTAssertEqual(daily.first { $0.date == date("2026-10-03T15:30:00Z") }?.counts?.keys, 7)
        XCTAssertEqual(daily.first { $0.date == date("2026-10-03T16:00:00Z") }?.counts?.keys, 9)
        let recent = hourly.points(on: regularHour, recent24Hours: true, now: regularHour)
        XCTAssertEqual(recent.count, 24)
        XCTAssertEqual(recent.reduce(0) { $0 + ($1.counts?.keys ?? 0) }, 16)
        let restored = try SyncJSON.decoder.decode(HourlyStats.self, from: SyncJSON.encoder.encode(hourly))
        XCTAssertEqual(restored, hourly)
        for (day, shard) in hourly.syncShards(now: regularHour) { try shard.validate(day: day) }
    }

    func testHalfHourFallTransitionPreservesBothRepeatedHours() throws {
        var hourly = HourlyStats(startedAt: date("2026-04-03T00:00:00Z"),
                                 timeZone: TimeZone(identifier: "Australia/Lord_Howe")!)
        hourly.record(keys: 3, at: date("2026-04-04T14:45:00Z")) // first 01:45
        hourly.record(keys: 7, at: date("2026-04-04T15:15:00Z")) // second 01:45
        let now = date("2026-04-04T16:00:00Z")
        let points = hourly.points(on: now, recent24Hours: false, now: now)
        XCTAssertEqual(points.first { $0.date == date("2026-04-04T14:00:00Z") }?.counts?.keys, 3)
        XCTAssertEqual(points.first { $0.date == date("2026-04-04T15:00:00Z") }?.counts?.keys, 7)
        XCTAssertEqual(points.reduce(0) { $0 + ($1.counts?.keys ?? 0) }, 10)
        let restored = try SyncJSON.decoder.decode(HourlyStats.self, from: SyncJSON.encoder.encode(hourly))
        XCTAssertEqual(restored, hourly)
    }

    func testLegacyHalfHourTransitionBucketMigratesWithoutLosingCounts() throws {
        var hourly = HourlyStats(startedAt: date("2026-10-03T00:00:00Z"),
                                 timeZone: TimeZone(identifier: "Australia/Lord_Howe")!)
        let event = date("2026-10-03T15:45:00Z")
        hourly.record(keys: 7, at: event)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: SyncJSON.encoder.encode(hourly)) as? [String: Any])
        let legacyStart = try XCTUnwrap(hourly.calendar.dateInterval(of: .hour, for: event)?.start)
        json["buckets"] = [String(Int64(legacyStart.timeIntervalSince1970)): ["keys": 7, "clicks": 0]]
        let restored = try SyncJSON.decoder.decode(HourlyStats.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(restored, hourly)
        json["buckets"] = [String(Int64(legacyStart.timeIntervalSince1970)): ["keys": -1, "clicks": 0]]
        XCTAssertThrowsError(try SyncJSON.decoder.decode(HourlyStats.self, from: JSONSerialization.data(withJSONObject: json)))
    }

    func testRemoteSkippedClockHourIsIncludedInNextValidHour() throws {
        let start = date("2026-03-01T00:00:00Z")
        let local = HourlyStats(startedAt: start, timeZone: TimeZone(identifier: "America/New_York")!)
        var remote = HourlyStats(startedAt: start, timeZone: TimeZone(secondsFromGMT: 0)!)
        remote.record(keys: 7, clicks: 2, at: date("2026-03-08T02:30:00Z"))
        remote.record(keys: 5, clicks: 1, at: date("2026-03-08T03:30:00Z"))
        let now = date("2026-03-09T12:00:00Z")
        let shards = remote.syncShards(now: now).map { snapshot($0.value, day: $0.key) }
        let series = DisplayStatsAggregator.hourlySeries(local: local, remote: shards, currentDeviceId: "local",
            date: date("2026-03-08T12:00:00Z"), recent24Hours: false, now: now)
        XCTAssertEqual(series.total.reduce(0) { $0 + ($1.counts?.keys ?? 0) }, 12)
        let three = series.total.first { local.calendar.component(.hour, from: $0.date) == 3 }
        XCTAssertEqual(three?.counts, HourlyStats.Counts(keys: 12, clicks: 3))
    }

    func testZeroActivityDayRemainsAnArchiveAfterRolloverAndCacheReload() throws {
        let start = date("2026-09-09T00:00:00Z")
        let hourly = HourlyStats(startedAt: start, timeZone: TimeZone(secondsFromGMT: 0)!)
        let first = snapshot(hourly.syncShards(now: date("2026-09-09T12:00:00Z"))["2026-09-09"], day: "2026-09-09")
        let next = try XCTUnwrap(hourly.syncShards(now: date("2026-09-10T12:00:00Z"))["2026-09-09"])
        let later = try XCTUnwrap(hourly.syncShards(now: date("2026-09-11T12:00:00Z"))["2026-09-09"])
        XCTAssertEqual(next, later)
        XCTAssertEqual(next.recordedThrough, date("2026-09-10T00:00:00Z").addingTimeInterval(-0.001))
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("zero-day-cache-\(UUID().uuidString).json")
        let cache = RemoteShardCache(fileURL: path)
        _ = try cache.apply(recordId: "record", snapshot: first, currentDeviceId: "local")
        _ = try cache.apply(recordId: "record", snapshot: snapshot(next, day: "2026-09-09", revision: 2), currentDeviceId: "local")
        let restored = RemoteShardCache(fileURL: path)
        let local = HourlyStats(startedAt: date("2026-09-10T00:00:00Z"), timeZone: TimeZone(secondsFromGMT: 0)!)
        let series = DisplayStatsAggregator.hourlySeries(local: local, remote: restored.snapshots(), currentDeviceId: "local",
            date: start, recent24Hours: false, now: date("2026-09-11T12:00:00Z"))
        XCTAssertTrue(series.local.allSatisfy { $0.counts == nil })
        XCTAssertTrue(series.total.allSatisfy { $0.counts == HourlyStats.Counts() })
        XCTAssertNil(hourly.syncShards(now: date("2026-09-10T12:00:00Z"))["2026-09-08"])
    }
}

extension HourlyStatsTests {
    func testResetUsesTheDailyStatisticsCalendarAfterTravel() {
        var hourly = HourlyStats(startedAt: date("2026-09-09T00:00:00Z"),
                                 timeZone: TimeZone(identifier: "Asia/Shanghai")!)
        let events = ["2026-09-09T23:00:00Z", "2026-09-10T10:00:00Z", "2026-09-10T20:00:00Z", "2026-09-11T01:00:00Z"].map(date)
        for event in events { hourly.record(keys: 1, at: event) }
        var dailyCalendar = Calendar(identifier: .gregorian)
        dailyCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
        hourly.reset(on: date("2026-09-10T23:00:00Z"), calendar: dailyCalendar)
        let now = date("2026-09-12T00:00:00Z")
        for (index, event) in events.enumerated() {
            let point = hourly.points(on: event, recent24Hours: false, now: now).first { $0.date == event }
            XCTAssertEqual(point?.counts?.keys, index == 0 || index == 3 ? 1 : 0)
        }
    }
}
