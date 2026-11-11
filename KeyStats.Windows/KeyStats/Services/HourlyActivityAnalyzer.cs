using System;
using System.Collections.Generic;
using System.Linq;
using KeyStats.Models;

namespace KeyStats.Services;

public enum Chronotype
{
    NotEnoughData,
    NightOwl,
    EarlyBird,
    AfternoonPerson,
    EveningPerson
}

public sealed class HourlyActivityResult
{
    /// <summary>每小时日均值（只统计有小时数据的天）。</summary>
    public double[] HourlyAverages { get; set; } = new double[DailyStats.HoursPerDay];
    public int DayCount { get; set; }
    public long Total { get; set; }
    public int PeakHour { get; set; } = -1;
    public double NightRatio { get; set; }
    public Chronotype Chronotype { get; set; } = Chronotype.NotEnoughData;
}

/// <summary>
/// 分时段活跃度：日均曲线、最活跃时段、作息类型。规则与 macOS 端保持一致。
/// </summary>
public static class HourlyActivityAnalyzer
{
    public const int MinimumTotal = 200;

    private static readonly int[] NightHours = { 22, 23, 0, 1, 2, 3, 4 };

    /// <summary>这一天是否有小时数据：按键和点击的小时计数合计大于 0（上线前的旧数据都是 0）。</summary>
    public static bool HasHourlyData(DailyStats stats)
    {
        return DailyStats.NormalizeHourly(stats.HourlyKeyPresses).Any(v => v > 0)
            || DailyStats.NormalizeHourly(stats.HourlyClicks).Any(v => v > 0);
    }

    /// <param name="days">范围内「有小时数据」的每一天在当前指标下的 24 小时计数，由调用方先用 HasHourlyData 筛选。</param>
    public static HourlyActivityResult Analyze(IEnumerable<int[]?> days)
    {
        var sums = new long[DailyStats.HoursPerDay];
        var dayCount = 0;
        foreach (var day in days)
        {
            var hours = DailyStats.NormalizeHourly(day);
            dayCount++;
            for (var hour = 0; hour < DailyStats.HoursPerDay; hour++)
            {
                sums[hour] += hours[hour];
            }
        }

        var result = new HourlyActivityResult
        {
            DayCount = dayCount,
            Total = sums.Sum()
        };
        if (dayCount == 0)
        {
            return result;
        }

        for (var hour = 0; hour < DailyStats.HoursPerDay; hour++)
        {
            result.HourlyAverages[hour] = (double)sums[hour] / dayCount;
        }

        var peak = sums.Max();
        result.PeakHour = peak > 0 ? Array.IndexOf(sums, peak) : -1;
        if (result.Total <= 0)
        {
            return result;
        }

        var night = NightHours.Sum(hour => sums[hour]);
        result.NightRatio = (double)night / result.Total;
        if (result.Total < MinimumTotal)
        {
            return result;
        }

        if (result.NightRatio >= 0.20)
        {
            result.Chronotype = Chronotype.NightOwl;
            return result;
        }

        var morning = SumRange(sums, 5, 10);
        var afternoon = SumRange(sums, 11, 17);
        var evening = SumRange(sums, 18, 21);
        // 并列时取更早的时段
        result.Chronotype = morning >= afternoon && morning >= evening
            ? Chronotype.EarlyBird
            : afternoon >= evening
                ? Chronotype.AfternoonPerson
                : Chronotype.EveningPerson;
        return result;
    }

    private static long SumRange(long[] sums, int from, int to)
    {
        long total = 0;
        for (var hour = from; hour <= to; hour++)
        {
            total += sums[hour];
        }
        return total;
    }
}
