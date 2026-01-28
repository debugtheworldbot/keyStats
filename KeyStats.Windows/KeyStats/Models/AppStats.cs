using System.Text.Json.Serialization;

namespace KeyStats.Models;

public class AppStats
{
    public string AppName { get; set; } = string.Empty;
    public string DisplayName { get; set; } = string.Empty;
    public int KeyPresses { get; set; }
    public int LeftClicks { get; set; }
    public int RightClicks { get; set; }
    public double ScrollDistance { get; set; }

    [JsonIgnore]
    public int TotalClicks => LeftClicks + RightClicks;

    [JsonIgnore]
    public bool HasActivity => KeyPresses > 0 || LeftClicks > 0 || RightClicks > 0 || ScrollDistance > 0;

    public AppStats() { }

    public AppStats(string appName, string displayName = "")
    {
        AppName = appName;
        DisplayName = string.IsNullOrEmpty(displayName) ? appName : displayName;
    }

    public AppStats(AppStats source)
    {
        AppName = source.AppName;
        DisplayName = source.DisplayName;
        KeyPresses = source.KeyPresses;
        LeftClicks = source.LeftClicks;
        RightClicks = source.RightClicks;
        ScrollDistance = source.ScrollDistance;
    }

    public void RecordKeyPress() => KeyPresses++;
    public void RecordLeftClick() => LeftClicks++;
    public void RecordRightClick() => RightClicks++;
    public void AddScrollDistance(double distance) => ScrollDistance += distance;
}
