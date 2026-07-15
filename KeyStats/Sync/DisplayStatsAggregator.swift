import Foundation

enum DisplayStatsAggregator {
    static func coreSnapshot(
        from stats: DailyStats,
        deviceId: String,
        revision: Int64
    ) throws -> CoreDaySnapshotV1 {
        var counts: [String: Int64] = [:]
        for (rawKey, rawCount) in stats.keyPressCounts {
            let key = SyncKeyCanonicalizer.canonicalize(rawKey, platform: "mac")
            guard !key.isEmpty else { continue }
            let count = Int64(max(0, rawCount))
            counts[key] = SyncMath.saturatingAdd(counts[key] ?? 0, count)
        }
        return try CoreDaySnapshotV1(
            deviceId: deviceId,
            localDay: SyncDay.string(from: stats.date),
            revision: revision,
            keyPresses: Int64(max(0, stats.keyPresses)),
            keyPressCounts: counts,
            clicks: CoreClickSnapshotV1(
                left: Int64(max(0, stats.leftClicks)),
                right: Int64(max(0, stats.rightClicks)),
                middle: Int64(max(0, stats.middleClicks)),
                sideBack: Int64(max(0, stats.sideBackClicks)),
                sideForward: Int64(max(0, stats.sideForwardClicks))
            )
        ).validated()
    }

    static func aggregate(
        local: [String: DailyStats],
        remote: [CoreDaySnapshotV1],
        currentDeviceId: String
    ) -> [String: DailyStats] {
        var result = local
        for shard in remote where shard.deviceId != currentDeviceId {
            guard let date = SyncDay.date(from: shard.localDay) else { continue }
            var day = result[shard.localDay] ?? DailyStats(date: date)
            day.keyPresses = add(day.keyPresses, shard.keyPresses)
            day.leftClicks = add(day.leftClicks, shard.clicks.left)
            day.rightClicks = add(day.rightClicks, shard.clicks.right)
            day.middleClicks = add(day.middleClicks, shard.clicks.middle)
            day.sideBackClicks = add(day.sideBackClicks, shard.clicks.sideBack)
            day.sideForwardClicks = add(day.sideForwardClicks, shard.clicks.sideForward)
            for (key, count) in shard.keyPressCounts {
                day.keyPressCounts[key] = add(day.keyPressCounts[key] ?? 0, count)
            }
            result[shard.localDay] = day
        }
        return result
    }

    static func currentDay(
        local: DailyStats,
        remote: [CoreDaySnapshotV1],
        currentDeviceId: String
    ) -> DailyStats {
        let day = SyncDay.string(from: local.date)
        let remoteForDay = deduplicatedLatest(remote.filter { $0.localDay == day })
        return aggregate(
            local: [day: local],
            remote: remoteForDay,
            currentDeviceId: currentDeviceId
        )[day] ?? local
    }

    static func deduplicatedLatest(_ snapshots: [CoreDaySnapshotV1]) -> [CoreDaySnapshotV1] {
        var latest: [String: CoreDaySnapshotV1] = [:]
        for snapshot in snapshots {
            let key = "\(snapshot.deviceId)|\(snapshot.localDay)"
            guard let existing = latest[key] else {
                latest[key] = snapshot
                continue
            }
            if snapshot.revision > existing.revision {
                latest[key] = snapshot
            }
        }
        return Array(latest.values)
    }

    private static func add(_ local: Int, _ remote: Int64) -> Int {
        guard remote > 0 else { return max(0, local) }
        if remote >= Int64(Int.max) { return Int.max }
        return SyncMath.saturatingAdd(max(0, local), Int(remote))
    }
}
