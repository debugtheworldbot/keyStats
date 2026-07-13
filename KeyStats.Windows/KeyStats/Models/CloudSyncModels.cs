using System;
using System.Collections.Generic;
using System.Text.Json.Serialization;

namespace KeyStats.Models;

public sealed class CloudAuthRequest
{
    [JsonPropertyName("username")]
    public string Username { get; set; } = "";

    [JsonPropertyName("password")]
    public string Password { get; set; } = "";
}

public sealed class CloudAuthResponse
{
    [JsonPropertyName("token")]
    public string Token { get; set; } = "";

    [JsonPropertyName("user_id")]
    public string UserId { get; set; } = "";
}

public sealed class CloudDevice
{
    [JsonPropertyName("id")]
    public string Id { get; set; } = "";

    [JsonPropertyName("user_id")]
    public string UserId { get; set; } = "";

    [JsonPropertyName("platform")]
    public string Platform { get; set; } = "";

    [JsonPropertyName("device_name")]
    public string DeviceName { get; set; } = "";

    [JsonPropertyName("created_at")]
    public DateTime CreatedAt { get; set; }

    [JsonPropertyName("last_sync_at")]
    public DateTime? LastSyncAt { get; set; }
}

public sealed class CloudRegisterDeviceRequest
{
    [JsonPropertyName("device_id")]
    public string? DeviceId { get; set; }

    [JsonPropertyName("platform")]
    public string Platform { get; set; } = "";

    [JsonPropertyName("device_name")]
    public string DeviceName { get; set; } = "";
}

public sealed class CloudDailyStatsPayload
{
    [JsonPropertyName("date")]
    public string Date { get; set; } = "";

    [JsonPropertyName("key_presses")]
    public int KeyPresses { get; set; }

    [JsonPropertyName("key_press_counts")]
    public Dictionary<string, int>? KeyPressCounts { get; set; }

    [JsonPropertyName("left_clicks")]
    public int LeftClicks { get; set; }

    [JsonPropertyName("right_clicks")]
    public int RightClicks { get; set; }

    [JsonPropertyName("side_back_clicks")]
    public int SideBackClicks { get; set; }

    [JsonPropertyName("side_forward_clicks")]
    public int SideForwardClicks { get; set; }

    [JsonPropertyName("mouse_distance")]
    public double MouseDistance { get; set; }

    [JsonPropertyName("scroll_distance")]
    public double ScrollDistance { get; set; }

    [JsonPropertyName("peak_kps")]
    public int PeakKPS { get; set; }

    [JsonPropertyName("peak_cps")]
    public int PeakCPS { get; set; }

    [JsonPropertyName("app_stats")]
    public Dictionary<string, CloudAppStatsPayload>? AppStats { get; set; }
}

public sealed class CloudAppStatsPayload
{
    [JsonPropertyName("bundle_id")]
    public string BundleId { get; set; } = "";

    [JsonPropertyName("display_name")]
    public string DisplayName { get; set; } = "";

    [JsonPropertyName("key_presses")]
    public int KeyPresses { get; set; }

    [JsonPropertyName("left_clicks")]
    public int LeftClicks { get; set; }

    [JsonPropertyName("right_clicks")]
    public int RightClicks { get; set; }

    [JsonPropertyName("side_back_clicks")]
    public int SideBackClicks { get; set; }

    [JsonPropertyName("side_forward_clicks")]
    public int SideForwardClicks { get; set; }

    [JsonPropertyName("scroll_distance")]
    public double ScrollDistance { get; set; }
}

public sealed class CloudUpsertStatsRequest
{
    [JsonPropertyName("device_id")]
    public string DeviceId { get; set; } = "";

    [JsonPropertyName("date")]
    public string Date { get; set; } = "";

    [JsonPropertyName("version")]
    public long Version { get; set; }

    [JsonPropertyName("stats")]
    public CloudDailyStatsPayload Stats { get; set; } = new();
}

public sealed class CloudBulkUpsertStatsRequest
{
    [JsonPropertyName("device_id")]
    public string DeviceId { get; set; } = "";

    [JsonPropertyName("records")]
    public List<CloudBulkStatsRecord> Records { get; set; } = new();
}

public sealed class CloudBulkStatsRecord
{
    [JsonPropertyName("date")]
    public string Date { get; set; } = "";

    [JsonPropertyName("version")]
    public long Version { get; set; }

    [JsonPropertyName("stats")]
    public CloudDailyStatsPayload Stats { get; set; } = new();
}

public sealed class CloudStatsRecord
{
    [JsonPropertyName("device_id")]
    public string DeviceId { get; set; } = "";

    [JsonPropertyName("platform")]
    public string Platform { get; set; } = "";

    [JsonPropertyName("device_name")]
    public string DeviceName { get; set; } = "";

    [JsonPropertyName("date")]
    public string Date { get; set; } = "";

    [JsonPropertyName("version")]
    public long Version { get; set; }

    [JsonPropertyName("updated_at")]
    public DateTime UpdatedAt { get; set; }

    [JsonPropertyName("stats")]
    public CloudDailyStatsPayload Stats { get; set; } = new();
}

public sealed class CloudDevicesResponse
{
    [JsonPropertyName("devices")]
    public List<CloudDevice> Devices { get; set; } = new();
}

public sealed class CloudStatsListResponse
{
    [JsonPropertyName("records")]
    public List<CloudStatsRecord> Records { get; set; } = new();
}

public sealed class CloudAPIErrorResponse
{
    [JsonPropertyName("error")]
    public string Error { get; set; } = "";
}

public enum CloudSyncStatusKind
{
    Idle,
    Syncing,
    Success,
    Failed
}

public sealed class CloudSyncStatus
{
    public CloudSyncStatusKind Kind { get; init; } = CloudSyncStatusKind.Idle;
    public DateTime? SuccessAt { get; init; }
    public string? ErrorMessage { get; init; }
}

public enum StatsDisplaySelectionKind
{
    Local,
    AllDevices,
    Device
}

public sealed class StatsDisplaySelection : IEquatable<StatsDisplaySelection>
{
    public StatsDisplaySelectionKind Kind { get; init; } = StatsDisplaySelectionKind.Local;
    public string? DeviceId { get; init; }

    public static StatsDisplaySelection Local { get; } = new() { Kind = StatsDisplaySelectionKind.Local };
    public static StatsDisplaySelection AllDevices { get; } = new() { Kind = StatsDisplaySelectionKind.AllDevices };

    public static StatsDisplaySelection ForDevice(string deviceId) =>
        new() { Kind = StatsDisplaySelectionKind.Device, DeviceId = deviceId };

    public string PersistedValue => Kind switch
    {
        StatsDisplaySelectionKind.Local => "local",
        StatsDisplaySelectionKind.AllDevices => "all",
        StatsDisplaySelectionKind.Device => string.IsNullOrWhiteSpace(DeviceId) ? "local" : $"device:{DeviceId}",
        _ => "local"
    };

    public static StatsDisplaySelection FromPersisted(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw) || raw == "local")
        {
            return Local;
        }

        if (raw == "all")
        {
            return AllDevices;
        }

        const string prefix = "device:";
        if (raw.StartsWith(prefix, StringComparison.Ordinal))
        {
            var id = raw.Substring(prefix.Length);
            return string.IsNullOrWhiteSpace(id) ? Local : ForDevice(id);
        }

        return Local;
    }

    public string AnalyticsValue => Kind switch
    {
        StatsDisplaySelectionKind.Local => "local",
        StatsDisplaySelectionKind.AllDevices => "all",
        StatsDisplaySelectionKind.Device => "device",
        _ => "local"
    };

    public bool Equals(StatsDisplaySelection? other)
    {
        if (other is null) return false;
        if (Kind != other.Kind) return false;
        return Kind != StatsDisplaySelectionKind.Device ||
               string.Equals(DeviceId, other.DeviceId, StringComparison.Ordinal);
    }

    public override bool Equals(object? obj) => Equals(obj as StatsDisplaySelection);

    public override int GetHashCode()
    {
        unchecked
        {
            return ((int)Kind * 397) ^ (DeviceId?.GetHashCode() ?? 0);
        }
    }
}

public sealed class StatsDisplayTab
{
    public StatsDisplaySelection Selection { get; init; } = StatsDisplaySelection.Local;
    public string Label { get; init; } = "";
}

public sealed class DeviceTodaySummary
{
    public string DeviceId { get; init; } = "";
    public string Platform { get; init; } = "";
    public string DeviceName { get; init; } = "";
    public bool IsLocal { get; init; }
    public int KeyPresses { get; init; }
    public int LeftClicks { get; init; }
    public int RightClicks { get; init; }
    public int SideBackClicks { get; init; }
    public int SideForwardClicks { get; init; }
    public double MouseDistance { get; init; }
    public double ScrollDistance { get; init; }
    public int PeakKPS { get; init; }
    public int PeakCPS { get; init; }
    public DateTime? LastSyncAt { get; init; }

    public int TotalClicks => LeftClicks + RightClicks + SideBackClicks + SideForwardClicks;

    public string TitleText
    {
        get
        {
            var name = DeviceName?.Trim() ?? "";
            if (!string.IsNullOrEmpty(name)) return name;
            return Platform switch
            {
                "macos" => "macOS",
                "windows" => "Windows",
                "linux" => "Linux",
                _ => string.IsNullOrWhiteSpace(Platform) ? "Device" : Platform
            };
        }
    }
}

public sealed class CloudSyncException : Exception
{
    public CloudSyncException(string message) : base(message) { }
}
