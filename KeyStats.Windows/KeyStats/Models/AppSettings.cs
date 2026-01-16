using System.Text.Json.Serialization;

namespace KeyStats.Models;

public class AppSettings
{
    [JsonPropertyName("showKeyPressesInTray")]
    public bool ShowKeyPressesInTray { get; set; } = true;

    [JsonPropertyName("showMouseClicksInTray")]
    public bool ShowMouseClicksInTray { get; set; } = true;

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
}

public enum DynamicIconColorStyle
{
    Icon,
    Dot
}
