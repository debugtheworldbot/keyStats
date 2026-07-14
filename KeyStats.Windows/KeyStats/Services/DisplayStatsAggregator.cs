using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using KeyStats.Models;

namespace KeyStats.Services;

public sealed class DisplayStatsAggregator
{
    private readonly RemoteShardCache _remoteCache;
    private readonly Func<string> _localDeviceId;

    public DisplayStatsAggregator(RemoteShardCache remoteCache, Func<string> localDeviceId)
    {
        _remoteCache = remoteCache;
        _localDeviceId = localDeviceId;
    }

    public DailyStats Aggregate(DateTime date, DailyStats localStats)
    {
        var day = date.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
        var result = Clone(localStats, date.Date);
        var localDeviceId = _localDeviceId();

        foreach (var record in _remoteCache.GetAll().Where(record =>
                     string.Equals(record.Plaintext.LocalDay, day, StringComparison.Ordinal) &&
                     !string.Equals(record.DeviceId, localDeviceId, StringComparison.Ordinal)))
        {
            var remote = record.Plaintext;
            result.KeyPresses = SafeAdd(result.KeyPresses, remote.KeyPresses);
            result.LeftClicks = SafeAdd(result.LeftClicks, remote.Clicks.Left);
            result.RightClicks = SafeAdd(result.RightClicks, remote.Clicks.Right);
            result.MiddleClicks = SafeAdd(result.MiddleClicks, remote.Clicks.Middle);
            result.SideBackClicks = SafeAdd(result.SideBackClicks, remote.Clicks.SideBack);
            result.SideForwardClicks = SafeAdd(result.SideForwardClicks, remote.Clicks.SideForward);

            foreach (var keyCount in remote.KeyPressCounts)
            {
                var key = (keyCount.Key ?? string.Empty).Trim();
                if (string.IsNullOrWhiteSpace(key) || keyCount.Value <= 0) continue;
                result.KeyPressCounts[key] = SafeAdd(
                    result.KeyPressCounts.TryGetValue(key, out var existing) ? existing : 0,
                    keyCount.Value);
            }
        }

        return result;
    }

    public IReadOnlyCollection<DateTime> GetRemoteDays()
    {
        return _remoteCache.GetAvailableDays()
            .Select(day => DateTime.TryParseExact(
                day,
                "yyyy-MM-dd",
                CultureInfo.InvariantCulture,
                DateTimeStyles.None,
                out var parsed)
                ? (DateTime?)parsed.Date
                : null)
            .Where(value => value.HasValue)
            .Select(value => value!.Value)
            .ToList();
    }

    private static DailyStats Clone(DailyStats source, DateTime date)
    {
        return new DailyStats(date)
        {
            KeyPresses = Math.Max(0, source.KeyPresses),
            KeyPressCounts = new Dictionary<string, int>(source.KeyPressCounts, StringComparer.Ordinal),
            LeftClicks = Math.Max(0, source.LeftClicks),
            RightClicks = Math.Max(0, source.RightClicks),
            MiddleClicks = Math.Max(0, source.MiddleClicks),
            SideBackClicks = Math.Max(0, source.SideBackClicks),
            SideForwardClicks = Math.Max(0, source.SideForwardClicks),
            MouseDistance = Math.Max(0, source.MouseDistance),
            ScrollDistance = Math.Max(0, source.ScrollDistance),
            PeakKPS = Math.Max(0, source.PeakKPS),
            PeakCPS = Math.Max(0, source.PeakCPS),
            AppStats = source.AppStats.ToDictionary(pair => pair.Key, pair => new AppStats(pair.Value))
        };
    }

    private static int SafeAdd(int left, long right)
    {
        if (right <= 0) return Math.Max(0, left);
        var total = (long)Math.Max(0, left) + right;
        return total >= int.MaxValue ? int.MaxValue : (int)total;
    }
}
