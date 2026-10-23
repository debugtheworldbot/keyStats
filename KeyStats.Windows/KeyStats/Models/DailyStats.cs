using System;
using System.Collections.Generic;
using System.Text.Json.Serialization;

namespace KeyStats.Models;

public class DailyStats
{
    private const double MetersPerPixel = AppSettings.DefaultMouseMetersPerPixel;

    [JsonPropertyName("date")]
    public DateTime Date { get; set; }

    [JsonPropertyName("keyPresses")]
    public int KeyPresses { get; set; }

    [JsonPropertyName("keyPressCounts")]
    public Dictionary<string, int> KeyPressCounts { get; set; } = new();

    [JsonPropertyName("leftClicks")]
    public int LeftClicks { get; set; }

    [JsonPropertyName("rightClicks")]
    public int RightClicks { get; set; }

    [JsonPropertyName("middleClicks")]
    public int MiddleClicks { get; set; }

    [JsonPropertyName("sideBackClicks")]
    public int SideBackClicks { get; set; }

    [JsonPropertyName("sideForwardClicks")]
    public int SideForwardClicks { get; set; }

    [JsonPropertyName("mouseDistance")]
    public double MouseDistance { get; set; }

    [JsonPropertyName("scrollDistance")]
    public double ScrollDistance { get; set; }

    [JsonPropertyName("peakKPS")]
    public double PeakKPS { get; set; }

    [JsonPropertyName("peakCPS")]
    public double PeakCPS { get; set; }

    [JsonPropertyName("appStats")]
    public Dictionary<string, AppStats> AppStats { get; set; } = new();

    // 按本地时间小时（0-23）的计数；旧数据没有这两个字段，读出来按全 0 处理
    [JsonPropertyName("hourlyKeyPresses")]
    public int[] HourlyKeyPresses { get; set; } = new int[HoursPerDay];

    [JsonPropertyName("hourlyClicks")]
    public int[] HourlyClicks { get; set; } = new int[HoursPerDay];

    public const int HoursPerDay = 24;

    /// <summary>返回长度固定为 24 的副本，null 或长度不对时补齐 / 截断，负数归零。</summary>
    public static int[] NormalizeHourly(int[]? source)
    {
        var result = new int[HoursPerDay];
        if (source == null)
        {
            return result;
        }

        for (var hour = 0; hour < HoursPerDay && hour < source.Length; hour++)
        {
            result[hour] = Math.Max(0, source[hour]);
        }
        return result;
    }

    public static int[] SumHourly(int[]? left, int[]? right)
    {
        var a = NormalizeHourly(left);
        var b = NormalizeHourly(right);
        var result = new int[HoursPerDay];
        for (var hour = 0; hour < HoursPerDay; hour++)
        {
            var total = (long)a[hour] + b[hour];
            result[hour] = total >= int.MaxValue ? int.MaxValue : (int)total;
        }
        return result;
    }

    public void RecordHourlyKeyPress(int hour)
    {
        HourlyKeyPresses = IncrementHour(HourlyKeyPresses, hour);
    }

    public void RecordHourlyClick(int hour)
    {
        HourlyClicks = IncrementHour(HourlyClicks, hour);
    }

    private static int[] IncrementHour(int[]? buckets, int hour)
    {
        var target = buckets != null && buckets.Length == HoursPerDay ? buckets : NormalizeHourly(buckets);
        if (hour >= 0 && hour < HoursPerDay && target[hour] < int.MaxValue)
        {
            target[hour]++;
        }
        return target;
    }

    [JsonIgnore]
    public int TotalClicks => LeftClicks + RightClicks + MiddleClicks + SideBackClicks + SideForwardClicks;

    public DailyStats()
    {
        Date = DateTime.Today;
    }

    public DailyStats(DateTime date)
    {
        Date = date.Date;
    }

    public string FormattedMouseDistance
    {
        get
        {
            var meters = MouseDistance * MetersPerPixel;
            if (meters >= 1000)
            {
                return $"{meters / 1000:F2} km";
            }
            else if (MouseDistance >= 1000)
            {
                return $"{meters:F1} m";
            }
            return $"{MouseDistance:F0} px";
        }
    }

    public string FormattedScrollDistance
    {
        get
        {
            if (ScrollDistance >= 10000)
            {
                return $"{ScrollDistance / 1000:F1} k";
            }
            return $"{ScrollDistance:F0} px";
        }
    }
}
