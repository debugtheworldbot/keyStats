using System;
using System.Collections.Generic;
using System.Linq;
using KeyStats.Models;

namespace KeyStats.Services;

public enum AchievementCategory
{
    TotalKeys,
    DailyKeys,
    TotalClicks,
    Streak,
    ActiveDays,
    PeakKps,
    MouseDistanceKm
}

public sealed class AchievementDefinition
{
    public AchievementDefinition(string id, AchievementCategory category, double target)
    {
        Id = id;
        Category = category;
        Target = target;
    }

    public string Id { get; }
    public AchievementCategory Category { get; }
    public double Target { get; }
}

public sealed class AchievementProgress
{
    public AchievementProgress(AchievementDefinition definition, double current, DateTime? reachedOn)
    {
        Definition = definition;
        Current = current;
        ReachedOn = reachedOn;
    }

    public AchievementDefinition Definition { get; }
    /// <summary>当前进度（累计类为累计值，单日 / 峰值 / 连续类为历史最高值）。</summary>
    public double Current { get; }
    /// <summary>首次达成的日期，未达成为 null。</summary>
    public DateTime? ReachedOn { get; }
    public bool IsUnlocked => ReachedOn.HasValue;
}

/// <summary>
/// 成就定义与判定。纯计算：按日期顺序扫描每日数据，得出每个成就的进度和首次达成日期。规则与 macOS 端保持一致。
/// </summary>
public static class AchievementEvaluator
{
    public static readonly IReadOnlyList<AchievementDefinition> Definitions = new[]
    {
        new AchievementDefinition("keys_100k", AchievementCategory.TotalKeys, 100_000),
        new AchievementDefinition("keys_1m", AchievementCategory.TotalKeys, 1_000_000),
        new AchievementDefinition("keys_10m", AchievementCategory.TotalKeys, 10_000_000),
        new AchievementDefinition("day_10k", AchievementCategory.DailyKeys, 10_000),
        new AchievementDefinition("day_30k", AchievementCategory.DailyKeys, 30_000),
        new AchievementDefinition("day_50k", AchievementCategory.DailyKeys, 50_000),
        new AchievementDefinition("clicks_100k", AchievementCategory.TotalClicks, 100_000),
        new AchievementDefinition("clicks_1m", AchievementCategory.TotalClicks, 1_000_000),
        new AchievementDefinition("streak_7", AchievementCategory.Streak, 7),
        new AchievementDefinition("streak_30", AchievementCategory.Streak, 30),
        new AchievementDefinition("streak_100", AchievementCategory.Streak, 100),
        new AchievementDefinition("active_100", AchievementCategory.ActiveDays, 100),
        new AchievementDefinition("active_365", AchievementCategory.ActiveDays, 365),
        new AchievementDefinition("kps_10", AchievementCategory.PeakKps, 10),
        new AchievementDefinition("kps_15", AchievementCategory.PeakKps, 15),
        new AchievementDefinition("marathon", AchievementCategory.MouseDistanceKm, 42.195),
    };

    public static bool IsActiveDay(DailyStats stats) => stats.KeyPresses > 0 || stats.TotalClicks > 0;

    public static IReadOnlyList<AchievementProgress> Evaluate(IEnumerable<DailyStats> days, double metersPerPixel)
    {
        long totalKeys = 0;
        long totalClicks = 0;
        double totalMeters = 0;
        var maxDailyKeys = 0;
        double maxKps = 0;
        var activeDays = 0;
        var currentStreak = 0;
        var longestStreak = 0;
        DateTime? previousActiveDate = null;
        var reached = new Dictionary<string, DateTime>(StringComparer.Ordinal);

        foreach (var day in days.OrderBy(d => d.Date))
        {
            var date = day.Date.Date;
            totalKeys += Math.Max(0, day.KeyPresses);
            totalClicks += Math.Max(0, day.TotalClicks);
            if (!double.IsNaN(day.MouseDistance) && !double.IsInfinity(day.MouseDistance) && day.MouseDistance > 0)
            {
                totalMeters += day.MouseDistance * metersPerPixel;
            }
            maxDailyKeys = Math.Max(maxDailyKeys, day.KeyPresses);
            maxKps = Math.Max(maxKps, day.PeakKPS);

            if (IsActiveDay(day))
            {
                activeDays++;
                currentStreak = previousActiveDate.HasValue && previousActiveDate.Value.AddDays(1) == date
                    ? currentStreak + 1
                    : 1;
                previousActiveDate = date;
                longestStreak = Math.Max(longestStreak, currentStreak);
            }

            foreach (var definition in Definitions)
            {
                if (!reached.ContainsKey(definition.Id)
                    && ValueFor(definition.Category, totalKeys, maxDailyKeys, totalClicks, longestStreak, activeDays, maxKps, totalMeters) >= definition.Target)
                {
                    reached[definition.Id] = date;
                }
            }
        }

        return Definitions
            .Select(definition => new AchievementProgress(
                definition,
                ValueFor(definition.Category, totalKeys, maxDailyKeys, totalClicks, longestStreak, activeDays, maxKps, totalMeters),
                reached.TryGetValue(definition.Id, out var reachedOn) ? reachedOn : (DateTime?)null))
            .ToList();
    }

    /// <summary>从今天往回数连续活跃天数；今天还没活跃时从昨天算起。</summary>
    public static int CurrentStreak(IReadOnlyDictionary<DateTime, DailyStats> byDate, DateTime today)
    {
        bool Active(DateTime date) => byDate.TryGetValue(date.Date, out var stats) && IsActiveDay(stats);

        var date = Active(today) ? today.Date : today.Date.AddDays(-1);
        var streak = 0;
        while (Active(date))
        {
            streak++;
            date = date.AddDays(-1);
        }
        return streak;
    }

    private static double ValueFor(
        AchievementCategory category,
        long totalKeys,
        int maxDailyKeys,
        long totalClicks,
        int longestStreak,
        int activeDays,
        double maxKps,
        double totalMeters)
    {
        return category switch
        {
            AchievementCategory.TotalKeys => totalKeys,
            AchievementCategory.DailyKeys => maxDailyKeys,
            AchievementCategory.TotalClicks => totalClicks,
            AchievementCategory.Streak => longestStreak,
            AchievementCategory.ActiveDays => activeDays,
            AchievementCategory.PeakKps => maxKps,
            AchievementCategory.MouseDistanceKm => totalMeters / 1000.0,
            _ => 0
        };
    }
}
