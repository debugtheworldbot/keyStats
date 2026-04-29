using System;
using System.Text.Json.Serialization;

namespace KeyStats.Models;

public class AppSettings
{
    public const double DefaultMouseMetersPerPixel = 0.00005;

    [JsonPropertyName("notificationsEnabled")]
    public bool NotificationsEnabled { get; set; }

    [JsonPropertyName("keyPressNotifyThreshold")]
    public int KeyPressNotifyThreshold { get; set; } = 1000;

    [JsonPropertyName("clickNotifyThreshold")]
    public int ClickNotifyThreshold { get; set; } = 1000;

    [JsonPropertyName("launchAtStartup")]
    public bool LaunchAtStartup { get; set; }

    [JsonPropertyName("analyticsEnabled")]
    public bool AnalyticsEnabled { get; set; } = true;

    [JsonPropertyName("analyticsApiKey")]
    public string? AnalyticsApiKey { get; set; } = "phc_TYyyKIfGgL1CXZx7t9dY7igE3yNwNpjj9aqItSpNVLx";

    [JsonPropertyName("analyticsHost")]
    public string? AnalyticsHost { get; set; }

    [JsonPropertyName("analyticsDistinctId")]
    public string? AnalyticsDistinctId { get; set; }

    [JsonPropertyName("analyticsFirstOpenUtc")]
    public DateTime? AnalyticsFirstOpenUtc { get; set; }

    [JsonPropertyName("analyticsInstallTracked")]
    public bool AnalyticsInstallTracked { get; set; }

    [JsonPropertyName("mouseMetersPerPixel")]
    public double MouseMetersPerPixel { get; set; } = DefaultMouseMetersPerPixel;

    [JsonPropertyName("mouseDistanceUnit")]
    public string MouseDistanceUnit { get; set; } = "auto"; // auto | px

    [JsonPropertyName("keyHistorySelectedRangeIndex")]
    public int KeyHistorySelectedRangeIndex { get; set; } = 1;

    [JsonPropertyName("mainWindowLeft")]
    public double? MainWindowLeft { get; set; }

    [JsonPropertyName("mainWindowTop")]
    public double? MainWindowTop { get; set; }

    [JsonPropertyName("mainWindowWidth")]
    public double? MainWindowWidth { get; set; }

    [JsonPropertyName("mainWindowHeight")]
    public double? MainWindowHeight { get; set; }

    [JsonPropertyName("languagePreference")]
    public string LanguagePreference { get; set; } = "system";  // "system" | "zh-Hans" | "en"
}
