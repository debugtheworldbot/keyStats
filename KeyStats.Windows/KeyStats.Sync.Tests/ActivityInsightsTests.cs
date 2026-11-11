using System;
using System.Collections.Generic;
using System.Linq;
using KeyStats.Models;
using KeyStats.Services;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KeyStats.Sync.Tests;

[TestClass]
public sealed class ActivityInsightsTests
{
    private static int[] Hours(params (int Hour, int Count)[] values)
    {
        var hours = new int[24];
        foreach (var (hour, count) in values) hours[hour] = count;
        return hours;
    }

    [TestMethod]
    public void Hourly_NoDays_ReturnsEmptyResult()
    {
        var result = HourlyActivityAnalyzer.Analyze(Array.Empty<int[]>());

        Assert.AreEqual(0, result.DayCount);
        Assert.AreEqual(-1, result.PeakHour);
        Assert.AreEqual(Chronotype.NotEnoughData, result.Chronotype);
    }

    [TestMethod]
    public void Hourly_AveragesAcrossDaysAndFindsEarliestPeak()
    {
        var result = HourlyActivityAnalyzer.Analyze(new[]
        {
            Hours((9, 100), (14, 300)),
            Hours((9, 300), (14, 100)),
            new int[24]
        });

        Assert.AreEqual(3, result.DayCount);
        Assert.AreEqual(400.0 / 3, result.HourlyAverages[9], 1e-9);
        Assert.AreEqual(9, result.PeakHour);
    }

    [TestMethod]
    public void Hourly_BelowMinimum_NoChronotypeButNightRatio()
    {
        var result = HourlyActivityAnalyzer.Analyze(new[] { Hours((23, 50), (10, 50)) });

        Assert.AreEqual(Chronotype.NotEnoughData, result.Chronotype);
        Assert.AreEqual(0.5, result.NightRatio, 1e-9);
    }

    [TestMethod]
    [DataRow(23, 100, 14, 400, Chronotype.NightOwl)]
    [DataRow(8, 300, 14, 200, Chronotype.EarlyBird)]
    [DataRow(8, 100, 15, 300, Chronotype.AfternoonPerson)]
    [DataRow(20, 300, 15, 100, Chronotype.EveningPerson)]
    [DataRow(8, 200, 15, 200, Chronotype.EarlyBird)]
    public void Hourly_Chronotype(int hourA, int countA, int hourB, int countB, Chronotype expected)
    {
        var result = HourlyActivityAnalyzer.Analyze(new[] { Hours((hourA, countA), (hourB, countB)) });

        Assert.AreEqual(expected, result.Chronotype);
    }

    [TestMethod]
    public void Hourly_HasHourlyData_UsesKeysAndClicks()
    {
        Assert.IsFalse(HourlyActivityAnalyzer.HasHourlyData(new DailyStats(DateTime.Today)));
        var clicksOnly = new DailyStats(DateTime.Today) { HourlyClicks = Hours((3, 1)) };
        Assert.IsTrue(HourlyActivityAnalyzer.HasHourlyData(clicksOnly));
        var legacy = new DailyStats(DateTime.Today) { HourlyKeyPresses = null!, HourlyClicks = new int[5] };
        Assert.IsFalse(HourlyActivityAnalyzer.HasHourlyData(legacy));
    }

    [TestMethod]
    public void DailyStats_SumHourly_HandlesLegacyArrays()
    {
        var sum = DailyStats.SumHourly(null, new[] { 1, 2, -3 });

        Assert.AreEqual(24, sum.Length);
        CollectionAssert.AreEqual(new[] { 1, 2, 0 }, sum.Take(3).ToArray());
    }

    private static DailyStats Day(DateTime date, int keys, int clicks = 0, double kps = 0, double mouse = 0)
    {
        return new DailyStats(date) { KeyPresses = keys, LeftClicks = clicks, PeakKPS = kps, MouseDistance = mouse };
    }

    private static AchievementProgress Get(IReadOnlyList<AchievementProgress> list, string id)
    {
        return list.Single(p => p.Definition.Id == id);
    }

    [TestMethod]
    public void Achievements_RecordFirstReachedDate()
    {
        var start = new DateTime(2026, 1, 1);
        var days = Enumerable.Range(0, 12).Select(i => Day(start.AddDays(i), 10_000)).ToList();

        var result = AchievementEvaluator.Evaluate(days, AppSettings.DefaultMouseMetersPerPixel);

        Assert.AreEqual(start, Get(result, "day_10k").ReachedOn);
        Assert.AreEqual(start.AddDays(9), Get(result, "keys_100k").ReachedOn);
        Assert.AreEqual(start.AddDays(6), Get(result, "streak_7").ReachedOn);
        Assert.IsFalse(Get(result, "keys_1m").IsUnlocked);
        Assert.AreEqual(120_000, Get(result, "keys_100k").Current);
    }

    [TestMethod]
    public void Achievements_StreakBreaksOnGapAndInactiveDay()
    {
        var start = new DateTime(2026, 3, 1);
        var days = new List<DailyStats>();
        days.AddRange(Enumerable.Range(0, 5).Select(i => Day(start.AddDays(i), 10)));
        days.Add(Day(start.AddDays(5), 0));          // 不活跃
        days.AddRange(Enumerable.Range(6, 4).Select(i => Day(start.AddDays(i), 10)));
        days.AddRange(Enumerable.Range(12, 6).Select(i => Day(start.AddDays(i), 10))); // 中间缺两天

        var result = AchievementEvaluator.Evaluate(days, AppSettings.DefaultMouseMetersPerPixel);

        Assert.AreEqual(6, Get(result, "streak_7").Current);
        Assert.IsFalse(Get(result, "streak_7").IsUnlocked);
        Assert.AreEqual(15, Get(result, "active_100").Current);
    }

    [TestMethod]
    public void Achievements_MarathonUsesCalibrationAndKpsUsesDailyPeak()
    {
        var date = new DateTime(2026, 5, 1);
        // 0.5 米每像素：42,000 + 42,390 像素 = 42,195 米，恰好达到马拉松距离
        var result = AchievementEvaluator.Evaluate(new[]
        {
            Day(date, 1, mouse: 42_000, kps: 9.9),
            Day(date.AddDays(1), 1, mouse: 42_390, kps: 10)
        }, 0.5);

        Assert.AreEqual(date.AddDays(1), Get(result, "marathon").ReachedOn);
        Assert.AreEqual(date.AddDays(1), Get(result, "kps_10").ReachedOn);
        Assert.IsFalse(Get(result, "kps_15").IsUnlocked);
    }

    [TestMethod]
    public void Achievements_CurrentStreakStartsFromYesterdayWhenTodayInactive()
    {
        var today = new DateTime(2026, 10, 23);
        var byDate = new Dictionary<DateTime, DailyStats>
        {
            [today.AddDays(-1)] = Day(today.AddDays(-1), 5),
            [today.AddDays(-2)] = Day(today.AddDays(-2), 0, clicks: 3),
            [today.AddDays(-4)] = Day(today.AddDays(-4), 5)
        };

        Assert.AreEqual(2, AchievementEvaluator.CurrentStreak(byDate, today));
        byDate[today] = Day(today, 1);
        Assert.AreEqual(3, AchievementEvaluator.CurrentStreak(byDate, today));
    }
}
