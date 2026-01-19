using System;
using System.Text.Json.Serialization;

namespace KeyStats.Models;

public class AppSettings
{
    [JsonPropertyName("showKeyPressesInTray")]
    public bool ShowKeyPressesInTray { get; set; } = false; // 默认只显示键盘图标

    [JsonPropertyName("showMouseClicksInTray")]
    public bool ShowMouseClicksInTray { get; set; } = false; // 默认只显示键盘图标

    [JsonPropertyName("notificationsEnabled")]
    public bool NotificationsEnabled { get; set; }

    [JsonPropertyName("keyPressNotifyThreshold")]
    public int KeyPressNotifyThreshold { get; set; } = 1000;

    [JsonPropertyName("clickNotifyThreshold")]
    public int ClickNotifyThreshold { get; set; } = 1000;

    [JsonPropertyName("enableDynamicIconColor")]
    public bool EnableDynamicIconColor { get; set; }

    [JsonPropertyName("dynamicIconColorStyle")]
    public DynamicIconColorStyle DynamicIconColorStyle { get; set; } = DynamicIconColorStyle.Icon;

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
}

public enum DynamicIconColorStyle
{
    Icon,
    Dot
}
