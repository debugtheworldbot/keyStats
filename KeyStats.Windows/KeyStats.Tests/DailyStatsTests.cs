using System;
using System.Text.Json;
using KeyStats.Models;
using Xunit;

namespace KeyStats.Tests;

public class DailyStatsTests
{
    [Fact]
    public void Initialization_ShouldSetDefaultValues()
    {
        var stats = new DailyStats();
        Assert.Equal(0, stats.KeyPresses);
        Assert.Equal(0, stats.TotalClicks);
        Assert.Equal(0, stats.MouseDistance);
        Assert.Equal(DateTime.Today, stats.Date.Date);
    }

    [Fact]
    public void TotalClicks_ShouldSumAllClicks()
    {
        var stats = new DailyStats
        {
            LeftClicks = 10,
            RightClicks = 5,
            SideBackClicks = 2,
            SideForwardClicks = 1
        };
        Assert.Equal(18, stats.TotalClicks);
    }

    [Fact]
    public void Serialization_ShouldPreserveValues()
    {
        var original = new DailyStats
        {
            KeyPresses = 42,
            LeftClicks = 10,
            MouseDistance = 123.45
        };
        original.KeyPressCounts["Enter"] = 5;

        var json = JsonSerializer.Serialize(original);
        var deserialized = JsonSerializer.Deserialize<DailyStats>(json);

        Assert.NotNull(deserialized);
        Assert.Equal(42, deserialized.KeyPresses);
        Assert.Equal(10, deserialized.LeftClicks);
        Assert.Equal(123.45, deserialized.MouseDistance);
        Assert.True(deserialized.KeyPressCounts.ContainsKey("Enter"));
        Assert.Equal(5, deserialized.KeyPressCounts["Enter"]);
    }
}
