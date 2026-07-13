using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using KeyStats.Helpers;
using KeyStats.Models;

namespace KeyStats.Services;

/// <summary>
/// Orchestrates cloud sync for Windows KeyStats.
/// Privacy: uploads aggregate daily stats per device; does not upload raw keystroke content.
/// </summary>
public sealed class CloudSyncManager
{
    private static CloudSyncManager? _instance;
    public static CloudSyncManager Instance => _instance ??= new CloudSyncManager();

    private readonly CloudSyncClient _client = new();
    private readonly object _stateLock = new();

    private readonly TimeSpan _uploadDebounceInterval = TimeSpan.FromSeconds(60);
    private readonly TimeSpan _autoSyncInterval = TimeSpan.FromSeconds(60);

    private CancellationTokenSource? _uploadDebounceCts;
    private CancellationTokenSource? _autoSyncCts;

    private CloudSyncStatus _status = new();
    private List<CloudDevice> _devices = new();
    private List<CloudStatsRecord> _remoteRecords = new();

    public event Action? StateChanged;

    private CloudSyncManager() { }

    public CloudSyncStatus Status
    {
        get { lock (_stateLock) return _status; }
    }

    public IReadOnlyList<CloudDevice> Devices
    {
        get { lock (_stateLock) return _devices.ToList(); }
    }

    public IReadOnlyList<CloudStatsRecord> RemoteRecords
    {
        get { lock (_stateLock) return _remoteRecords.ToList(); }
    }

    private AppSettings Settings => StatsManager.Instance.Settings;

    public string ServerURLString
    {
        get => Settings.CloudSyncServerURL ?? "";
        set
        {
            Settings.CloudSyncServerURL = (value ?? "").Trim();
            StatsManager.Instance.SaveSettings();
        }
    }

    public bool IsSyncEnabled
    {
        get => Settings.CloudSyncEnabled;
        set
        {
            Settings.CloudSyncEnabled = value;
            StatsManager.Instance.SaveSettings();
            if (value)
            {
                ScheduleUpload();
                _ = SyncNowAsync();
                StartAutoSyncIfNeeded();
            }
            else
            {
                CancelUploadDebounce();
                StopAutoSync();
            }
        }
    }

    public string SavedUsername => Settings.CloudSyncUsername ?? "";

    public bool IsAuthenticated => !string.IsNullOrWhiteSpace(CloudSyncCredentialStore.LoadToken());

    public bool IsCloudDisplayAvailable => IsAuthenticated && IsSyncEnabled;

    public StatsDisplaySelection DisplaySelection
    {
        get => StatsDisplaySelection.FromPersisted(Settings.CloudSyncDisplaySelection);
        set
        {
            var persisted = value.PersistedValue;
            if (string.Equals(Settings.CloudSyncDisplaySelection, persisted, StringComparison.Ordinal))
            {
                return;
            }

            Settings.CloudSyncDisplaySelection = persisted;
            StatsManager.Instance.SaveSettings();
            NotifyStateChanged();
        }
    }

    public string LocalDeviceId
    {
        get
        {
            if (!string.IsNullOrWhiteSpace(Settings.CloudSyncDeviceId))
            {
                return Settings.CloudSyncDeviceId!;
            }

            var generated = Guid.NewGuid().ToString("D").ToLowerInvariant();
            Settings.CloudSyncDeviceId = generated;
            StatsManager.Instance.SaveSettings();
            return generated;
        }
    }

    public List<StatsDisplayTab> DisplayTabs()
    {
        if (!IsCloudDisplayAvailable) return new List<StatsDisplayTab>();

        var tabs = new List<StatsDisplayTab>
        {
            new()
            {
                Selection = StatsDisplaySelection.Local,
                Label = Properties.Strings.DeviceStats_ScopeLocal
            }
        };

        var remoteDevices = Devices
            .Where(d => d.Id != LocalDeviceId)
            .OrderBy(d => d.DeviceName, StringComparer.CurrentCultureIgnoreCase)
            .ToList();

        foreach (var device in remoteDevices)
        {
            var name = (device.DeviceName ?? "").Trim();
            var label = string.IsNullOrEmpty(name) ? PlatformDisplayName(device.Platform) : name;
            tabs.Add(new StatsDisplayTab
            {
                Selection = StatsDisplaySelection.ForDevice(device.Id),
                Label = TruncatedTabLabel(label)
            });
        }

        tabs.Add(new StatsDisplayTab
        {
            Selection = StatsDisplaySelection.AllDevices,
            Label = Properties.Strings.DeviceStats_ScopeAllDevices
        });

        return tabs;
    }

    public StatsDisplaySelection ValidatedDisplaySelection()
    {
        if (!IsCloudDisplayAvailable) return StatsDisplaySelection.Local;

        var allowed = new HashSet<StatsDisplaySelection>(DisplayTabs().Select(t => t.Selection));
        var current = DisplaySelection;
        if (allowed.Contains(current)) return current;

        var fallback = StatsDisplaySelection.Local;
        if (!current.Equals(fallback))
        {
            DisplaySelection = fallback;
        }

        return fallback;
    }

    public Uri? NormalizedServerURL()
    {
        var raw = (ServerURLString ?? "").Trim();
        if (string.IsNullOrEmpty(raw)) return null;
        if (!raw.Contains("://"))
        {
            raw = "http://" + raw;
        }

        if (!Uri.TryCreate(raw, UriKind.Absolute, out var url) || string.IsNullOrWhiteSpace(url.Host))
        {
            return null;
        }

        var builder = new UriBuilder(url.Scheme, url.Host, url.Port);
        return builder.Uri;
    }

    public async Task RegisterAsync(string username, string password)
    {
        var baseUrl = NormalizedServerURL()
            ?? throw new CloudSyncException(Properties.Strings.Sync_Error_InvalidServerURL);

        var response = await _client.RegisterAsync(baseUrl, username, password).ConfigureAwait(false);
        PersistAuth(username, response.Token, response.UserId);

        if (string.IsNullOrWhiteSpace(CloudSyncCredentialStore.LoadToken()))
        {
            throw new CloudSyncException(Properties.Strings.Sync_Error_CredentialSaveFailed);
        }

        await EnsureDeviceRegisteredAsync().ConfigureAwait(false);
        Settings.CloudSyncInitialBulkUploaded = false;
        Settings.CloudSyncEnabled = true;
        StatsManager.Instance.SaveSettings();

        var error = await RunSyncPipelineAsync(includePull: true).ConfigureAwait(false);
        if (error != null)
        {
            throw new CloudSyncException(error);
        }

        SetStatus(CloudSyncStatusKind.Success, DateTime.Now, null);
        StartAutoSyncIfNeeded();
    }

    public async Task LoginAsync(string username, string password)
    {
        var baseUrl = NormalizedServerURL()
            ?? throw new CloudSyncException(Properties.Strings.Sync_Error_InvalidServerURL);

        var response = await _client.LoginAsync(baseUrl, username, password).ConfigureAwait(false);
        PersistAuth(username, response.Token, response.UserId);

        if (string.IsNullOrWhiteSpace(CloudSyncCredentialStore.LoadToken()))
        {
            throw new CloudSyncException(Properties.Strings.Sync_Error_CredentialSaveFailed);
        }

        await EnsureDeviceRegisteredAsync().ConfigureAwait(false);
        Settings.CloudSyncEnabled = true;
        StatsManager.Instance.SaveSettings();

        var error = await RunSyncPipelineAsync(includePull: true).ConfigureAwait(false);
        if (error != null)
        {
            throw new CloudSyncException(error);
        }

        SetStatus(CloudSyncStatusKind.Success, DateTime.Now, null);
        StartAutoSyncIfNeeded();
    }

    public void Logout()
    {
        CloudSyncCredentialStore.ClearCredentials();
        Settings.CloudSyncUsername = "";
        Settings.CloudSyncEnabled = false;
        StatsManager.Instance.SaveSettings();
        CancelUploadDebounce();
        StopAutoSync();
        ClearSessionState();
    }

    public void HandleLocalStatsSaved()
    {
        if (!IsSyncEnabled || !IsAuthenticated) return;
        ScheduleUpload();
    }

    public void ScheduleUpload()
    {
        CancelUploadDebounce();
        var cts = new CancellationTokenSource();
        _uploadDebounceCts = cts;

        _ = Task.Run(async () =>
        {
            try
            {
                await Task.Delay(_uploadDebounceInterval, cts.Token).ConfigureAwait(false);
                var error = await RunSyncPipelineAsync(includePull: false).ConfigureAwait(false);
                if (error != null)
                {
                    SetStatus(CloudSyncStatusKind.Failed, null, error);
                }
            }
            catch (OperationCanceledException)
            {
                // debounce cancelled
            }
        });
    }

    public async Task SyncNowAsync()
    {
        if (!IsSyncEnabled || !IsAuthenticated) return;

        SetStatus(CloudSyncStatusKind.Syncing, null, null);
        var error = await RunSyncPipelineAsync(includePull: true).ConfigureAwait(false);
        if (error != null)
        {
            SetStatus(CloudSyncStatusKind.Failed, null, error);
        }
        else
        {
            SetStatus(CloudSyncStatusKind.Success, DateTime.Now, null);
        }
    }

    public void BootstrapIfNeeded()
    {
        if (!IsSyncEnabled || !IsAuthenticated) return;
        StartAutoSyncIfNeeded();
        _ = SyncNowAsync();
    }

    public DailyStats StatsForDisplay(StatsDisplaySelection? selection = null)
    {
        var resolved = selection ?? ValidatedDisplaySelection();
        if (resolved.Kind == StatsDisplaySelectionKind.Local)
        {
            return StatsManager.Instance.CurrentStats;
        }

        if (resolved.Kind == StatsDisplaySelectionKind.AllDevices)
        {
            return AggregateTodayStats();
        }

        return TodayStatsForDevice(resolved.DeviceId ?? "");
    }

    public Dictionary<string, int> KeyPressCountsForDisplay(StatsDisplaySelection? selection = null)
    {
        var resolved = selection ?? ValidatedDisplaySelection();
        if (resolved.Kind == StatsDisplaySelectionKind.Local)
        {
            return new Dictionary<string, int>(StatsManager.Instance.CurrentStats.KeyPressCounts);
        }

        if (resolved.Kind == StatsDisplaySelectionKind.AllDevices)
        {
            return AggregatedTodayKeyPressCounts();
        }

        var deviceId = resolved.DeviceId ?? "";
        if (deviceId == LocalDeviceId)
        {
            return new Dictionary<string, int>(StatsManager.Instance.CurrentStats.KeyPressCounts);
        }

        var todayKey = DayKey(DateTime.Today);
        var record = RemoteRecords.FirstOrDefault(r => r.DeviceId == deviceId && r.Date == todayKey);
        return record?.Stats.KeyPressCounts != null
            ? new Dictionary<string, int>(record.Stats.KeyPressCounts)
            : new Dictionary<string, int>();
    }

    public List<(string Key, int Count)> KeyPressBreakdownSortedForDisplay()
    {
        var sourceCounts = IsCloudDisplayAvailable
            ? KeyPressCountsForDisplay()
            : StatsManager.Instance.CurrentStats.KeyPressCounts;

        return sourceCounts
            .Where(kvp => kvp.Value > 0)
            .OrderByDescending(kvp => kvp.Value)
            .ThenBy(kvp => kvp.Key, StringComparer.OrdinalIgnoreCase)
            .Select(kvp => (kvp.Key, kvp.Value))
            .ToList();
    }

    public (DateTime Start, DateTime End) KeyboardHeatmapDateBounds(StatsDisplaySelection? selection = null)
    {
        var resolved = selection ?? ValidatedDisplaySelection();
        if (resolved.Kind == StatsDisplaySelectionKind.Local)
        {
            return StatsManager.Instance.GetKeyboardHeatmapDateBounds();
        }

        if (resolved.Kind == StatsDisplaySelectionKind.Device)
        {
            var deviceId = resolved.DeviceId ?? "";
            if (deviceId == LocalDeviceId)
            {
                return StatsManager.Instance.GetKeyboardHeatmapDateBounds();
            }

            return RemoteKeyboardHeatmapDateBounds(deviceId);
        }

        return MergedKeyboardHeatmapDateBounds();
    }

    public StatsManager.KeyboardHeatmapDay KeyboardHeatmapDay(
        DateTime date,
        StatsDisplaySelection? selection = null)
    {
        var resolved = selection ?? ValidatedDisplaySelection();
        var normalizedDate = date.Date;

        if (resolved.Kind == StatsDisplaySelectionKind.Local)
        {
            return StatsManager.Instance.GetKeyboardHeatmapDay(normalizedDate);
        }

        if (resolved.Kind == StatsDisplaySelectionKind.Device)
        {
            var deviceId = resolved.DeviceId ?? "";
            if (deviceId == LocalDeviceId)
            {
                return StatsManager.Instance.GetKeyboardHeatmapDay(normalizedDate);
            }

            var dayKey = DayKey(normalizedDate);
            var record = RemoteRecords.FirstOrDefault(r => r.DeviceId == deviceId && r.Date == dayKey);
            if (record?.Stats.KeyPressCounts == null)
            {
                return new StatsManager.KeyboardHeatmapDay
                {
                    Date = normalizedDate,
                    TotalKeyPresses = 0,
                    KeyCounts = new Dictionary<string, int>(StringComparer.Ordinal)
                };
            }

            return StatsManager.Instance.BuildKeyboardHeatmapDay(
                normalizedDate,
                record.Stats.KeyPressCounts,
                Math.Max(0, record.Stats.KeyPresses));
        }

        return MergedKeyboardHeatmapDay(normalizedDate);
    }

    public List<AppStats> AppStatsSummary(
        StatsManager.AppStatsRange range,
        StatsDisplaySelection? selection = null)
    {
        var resolved = selection ?? ValidatedDisplaySelection();
        if (resolved.Kind == StatsDisplaySelectionKind.Local)
        {
            return StatsManager.Instance.GetAppStatsSummary(range);
        }

        if (resolved.Kind == StatsDisplaySelectionKind.Device)
        {
            var deviceId = resolved.DeviceId ?? "";
            if (deviceId == LocalDeviceId)
            {
                return StatsManager.Instance.GetAppStatsSummary(range);
            }

            return RemoteAppStatsSummary(range, deviceId);
        }

        return MergedAppStatsSummary(range);
    }

    private async Task<string?> RunSyncPipelineAsync(bool includePull)
    {
        var uploadError = await PerformUploadLocalStatsAsync().ConfigureAwait(false);
        if (uploadError != null) return uploadError;
        if (!includePull) return null;
        return await PerformPullRemoteStatsAsync().ConfigureAwait(false);
    }

    private async Task<string?> PerformUploadLocalStatsAsync()
    {
        try
        {
            await UploadLocalStatsAsync().ConfigureAwait(false);
            return null;
        }
        catch (Exception ex)
        {
            return ex.Message;
        }
    }

    private async Task<string?> PerformPullRemoteStatsAsync()
    {
        try
        {
            await PullRemoteStatsAsync().ConfigureAwait(false);
            return null;
        }
        catch (Exception ex)
        {
            return ex.Message;
        }
    }

    private async Task UploadLocalStatsAsync()
    {
        if (!IsSyncEnabled) return;

        var baseUrl = NormalizedServerURL()
            ?? throw new CloudSyncException(Properties.Strings.Sync_Error_NotConfigured);
        var token = AuthToken();

        await EnsureDeviceRegisteredAsync().ConfigureAwait(false);

        var snapshot = StatsManager.Instance.StatsSnapshotForSync();
        if (!Settings.CloudSyncInitialBulkUploaded && snapshot.Count > 1)
        {
            var dirtyRecords = snapshot
                .Where(kvp => HasStatsChanged(kvp.Key, kvp.Value))
                .Select(kvp =>
                {
                    var version = NextVersion(kvp.Key);
                    return new CloudBulkStatsRecord
                    {
                        Date = kvp.Key,
                        Version = version,
                        Stats = MakePayload(kvp.Key, kvp.Value)
                    };
                })
                .ToList();

            if (dirtyRecords.Count > 0)
            {
                await _client.BulkUpsertStatsAsync(
                    baseUrl,
                    token,
                    new CloudBulkUpsertStatsRequest
                    {
                        DeviceId = LocalDeviceId,
                        Records = dirtyRecords
                    }).ConfigureAwait(false);
                MarkUploaded(dirtyRecords, snapshot);
            }

            Settings.CloudSyncInitialBulkUploaded = true;
            StatsManager.Instance.SaveSettings();
        }
        else
        {
            var todayKey = DayKey(DateTime.Today);
            if (!snapshot.TryGetValue(todayKey, out var todayStats)) return;
            if (!HasStatsChanged(todayKey, todayStats)) return;

            var version = NextVersion(todayKey);
            var payload = MakePayload(todayKey, todayStats);
            await _client.UpsertStatsAsync(
                baseUrl,
                token,
                new CloudUpsertStatsRequest
                {
                    DeviceId = LocalDeviceId,
                    Date = todayKey,
                    Version = version,
                    Stats = payload
                }).ConfigureAwait(false);

            MarkUploaded(
                new List<CloudBulkStatsRecord>
                {
                    new() { Date = todayKey, Version = version, Stats = payload }
                },
                new Dictionary<string, DailyStats> { [todayKey] = todayStats });
        }
    }

    private async Task PullRemoteStatsAsync()
    {
        var baseUrl = NormalizedServerURL()
            ?? throw new CloudSyncException(Properties.Strings.Sync_Error_NotConfigured);
        var token = AuthToken();

        var fetchedDevices = await _client.ListDevicesAsync(baseUrl, token).ConfigureAwait(false);
        var fetchedRecords = await _client.ListStatsAsync(baseUrl, token, null, null, null).ConfigureAwait(false);
        SetRemoteData(fetchedDevices, fetchedRecords);
    }

    private async Task EnsureDeviceRegisteredAsync()
    {
        var baseUrl = NormalizedServerURL()
            ?? throw new CloudSyncException(Properties.Strings.Sync_Error_InvalidServerURL);
        var token = AuthToken();

        await _client.RegisterDeviceAsync(
            baseUrl,
            token,
            new CloudRegisterDeviceRequest
            {
                DeviceId = LocalDeviceId,
                Platform = "windows",
                DeviceName = Environment.MachineName
            }).ConfigureAwait(false);
    }

    private CloudDailyStatsPayload MakePayload(string dayKey, DailyStats stats)
    {
        var appStats = stats.AppStats.ToDictionary(
            kvp => kvp.Key,
            kvp => new CloudAppStatsPayload
            {
                BundleId = kvp.Value.AppName,
                DisplayName = kvp.Value.DisplayName,
                KeyPresses = kvp.Value.KeyPresses,
                LeftClicks = kvp.Value.LeftClicks,
                RightClicks = kvp.Value.RightClicks,
                SideBackClicks = kvp.Value.SideBackClicks,
                SideForwardClicks = kvp.Value.SideForwardClicks,
                ScrollDistance = kvp.Value.ScrollDistance
            });

        return new CloudDailyStatsPayload
        {
            Date = dayKey,
            KeyPresses = stats.KeyPresses,
            KeyPressCounts = stats.KeyPressCounts.Count > 0 ? stats.KeyPressCounts : null,
            LeftClicks = stats.LeftClicks,
            RightClicks = stats.RightClicks,
            SideBackClicks = stats.SideBackClicks,
            SideForwardClicks = stats.SideForwardClicks,
            MouseDistance = stats.MouseDistance,
            ScrollDistance = stats.ScrollDistance,
            PeakKPS = (int)Math.Round(stats.PeakKPS, MidpointRounding.AwayFromZero),
            PeakCPS = (int)Math.Round(stats.PeakCPS, MidpointRounding.AwayFromZero),
            AppStats = appStats.Count > 0 ? appStats : null
        };
    }

    private bool HasStatsChanged(string dayKey, DailyStats stats)
    {
        var fingerprint = MakeFingerprint(dayKey, stats);
        return !Settings.CloudSyncLastUploadFingerprints.TryGetValue(dayKey, out var stored) ||
               stored != fingerprint;
    }

    private long NextVersion(string dayKey)
    {
        return Settings.CloudSyncLastUploadVersions.TryGetValue(dayKey, out var current)
            ? current + 1
            : 1;
    }

    private static string MakeFingerprint(string dayKey, DailyStats stats) =>
        string.Join("|", new[]
        {
            dayKey,
            stats.KeyPresses.ToString(CultureInfo.InvariantCulture),
            stats.LeftClicks.ToString(CultureInfo.InvariantCulture),
            stats.RightClicks.ToString(CultureInfo.InvariantCulture),
            stats.SideBackClicks.ToString(CultureInfo.InvariantCulture),
            stats.SideForwardClicks.ToString(CultureInfo.InvariantCulture),
            stats.MouseDistance.ToString(CultureInfo.InvariantCulture),
            stats.ScrollDistance.ToString(CultureInfo.InvariantCulture),
            stats.PeakKPS.ToString(CultureInfo.InvariantCulture),
            stats.PeakCPS.ToString(CultureInfo.InvariantCulture)
        });

    private void MarkUploaded(IEnumerable<CloudBulkStatsRecord> records, Dictionary<string, DailyStats> snapshot)
    {
        foreach (var record in records)
        {
            Settings.CloudSyncLastUploadVersions[record.Date] = record.Version;
            if (snapshot.TryGetValue(record.Date, out var stats))
            {
                Settings.CloudSyncLastUploadFingerprints[record.Date] = MakeFingerprint(record.Date, stats);
            }
        }

        StatsManager.Instance.SaveSettings();
    }

    private DailyStats TodayStatsForDevice(string deviceId)
    {
        if (deviceId == LocalDeviceId)
        {
            return StatsManager.Instance.CurrentStats;
        }

        var todayKey = DayKey(DateTime.Today);
        var record = RemoteRecords.FirstOrDefault(r => r.DeviceId == deviceId && r.Date == todayKey);
        return record == null ? new DailyStats(DateTime.Today) : DailyStatsFromPayload(record.Stats, DateTime.Today);
    }

    private DailyStats AggregateTodayStats()
    {
        var aggregated = new DailyStats(DateTime.Today);
        var todayKey = DayKey(DateTime.Today);

        var local = StatsManager.Instance.CurrentStats;
        aggregated.KeyPresses += local.KeyPresses;
        aggregated.LeftClicks += local.LeftClicks;
        aggregated.RightClicks += local.RightClicks;
        aggregated.SideBackClicks += local.SideBackClicks;
        aggregated.SideForwardClicks += local.SideForwardClicks;
        aggregated.MouseDistance += local.MouseDistance;
        aggregated.ScrollDistance += local.ScrollDistance;
        aggregated.PeakKPS = Math.Max(aggregated.PeakKPS, local.PeakKPS);
        aggregated.PeakCPS = Math.Max(aggregated.PeakCPS, local.PeakCPS);

        foreach (var record in RemoteRecords.Where(r => r.Date == todayKey && r.DeviceId != LocalDeviceId))
        {
            aggregated.KeyPresses += record.Stats.KeyPresses;
            aggregated.LeftClicks += record.Stats.LeftClicks;
            aggregated.RightClicks += record.Stats.RightClicks;
            aggregated.SideBackClicks += record.Stats.SideBackClicks;
            aggregated.SideForwardClicks += record.Stats.SideForwardClicks;
            aggregated.MouseDistance += record.Stats.MouseDistance;
            aggregated.ScrollDistance += record.Stats.ScrollDistance;
            aggregated.PeakKPS = Math.Max(aggregated.PeakKPS, record.Stats.PeakKPS);
            aggregated.PeakCPS = Math.Max(aggregated.PeakCPS, record.Stats.PeakCPS);
        }

        return aggregated;
    }

    private Dictionary<string, int> AggregatedTodayKeyPressCounts()
    {
        var merged = new Dictionary<string, int>(StatsManager.Instance.CurrentStats.KeyPressCounts);
        var todayKey = DayKey(DateTime.Today);

        foreach (var record in RemoteRecords.Where(r => r.Date == todayKey && r.DeviceId != LocalDeviceId))
        {
            if (record.Stats.KeyPressCounts == null) continue;
            foreach (var kvp in record.Stats.KeyPressCounts)
            {
                var count = Math.Max(0, kvp.Value);
                if (count <= 0) continue;
                merged[kvp.Key] = merged.TryGetValue(kvp.Key, out var current) ? current + count : count;
            }
        }

        return merged;
    }

    private List<AppStats> RemoteAppStatsSummary(StatsManager.AppStatsRange range, string deviceId)
    {
        var totals = new Dictionary<string, AppStats>(StringComparer.OrdinalIgnoreCase);
        foreach (var record in RemoteRecords.Where(r => r.DeviceId == deviceId))
        {
            if (!RecordMatchesAppStatsRange(record, range)) continue;
            MergeAppStats(record.Stats.AppStats, totals);
        }

        return totals.Values.Select(a => new AppStats(a)).ToList();
    }

    private List<AppStats> MergedAppStatsSummary(StatsManager.AppStatsRange range)
    {
        var totals = new Dictionary<string, AppStats>(StringComparer.OrdinalIgnoreCase);
        foreach (var item in StatsManager.Instance.GetAppStatsSummary(range))
        {
            totals[item.AppName] = item;
        }

        foreach (var record in RemoteRecords.Where(r => r.DeviceId != LocalDeviceId))
        {
            if (!RecordMatchesAppStatsRange(record, range)) continue;
            MergeAppStats(record.Stats.AppStats, totals);
        }

        return totals.Values.Select(a => new AppStats(a)).ToList();
    }

    private bool RecordMatchesAppStatsRange(CloudStatsRecord record, StatsManager.AppStatsRange range)
    {
        if (range == StatsManager.AppStatsRange.All) return true;
        return DayKeysForRange(range).Contains(record.Date);
    }

    private HashSet<string> DayKeysForRange(StatsManager.AppStatsRange range)
    {
        var today = DateTime.Today;
        return range switch
        {
            StatsManager.AppStatsRange.Today => new HashSet<string> { DayKey(today) },
            StatsManager.AppStatsRange.Week => DayKeysEndingAt(today, 7),
            StatsManager.AppStatsRange.Month => DayKeysEndingAt(today, 30),
            _ => new HashSet<string>()
        };
    }

    private static HashSet<string> DayKeysEndingAt(DateTime end, int dayCount)
    {
        var keys = new HashSet<string>(StringComparer.Ordinal);
        for (var offset = 0; offset < dayCount; offset++)
        {
            keys.Add(DayKey(end.AddDays(-offset)));
        }

        return keys;
    }

    private static void MergeAppStats(
        Dictionary<string, CloudAppStatsPayload>? payload,
        Dictionary<string, AppStats> totals)
    {
        if (payload == null || payload.Count == 0) return;

        foreach (var cloudApp in payload.Values)
        {
            var bundleId = cloudApp.BundleId;
            if (string.IsNullOrWhiteSpace(bundleId)) continue;

            if (!totals.TryGetValue(bundleId, out var total))
            {
                total = new AppStats(bundleId, cloudApp.DisplayName);
                totals[bundleId] = total;
            }

            if (!string.IsNullOrWhiteSpace(cloudApp.DisplayName))
            {
                total.DisplayName = cloudApp.DisplayName;
            }

            total.KeyPresses += cloudApp.KeyPresses;
            total.LeftClicks += cloudApp.LeftClicks;
            total.RightClicks += cloudApp.RightClicks;
            total.SideBackClicks += cloudApp.SideBackClicks;
            total.SideForwardClicks += cloudApp.SideForwardClicks;
            total.ScrollDistance += cloudApp.ScrollDistance;
        }
    }

    private (DateTime Start, DateTime End) RemoteKeyboardHeatmapDateBounds(string deviceId)
    {
        var today = DateTime.Today;
        DateTime? earliest = null;

        foreach (var record in RemoteRecords.Where(r => r.DeviceId == deviceId))
        {
            if (!RecordHasKeyboardHeatmapData(record)) continue;
            if (!TryParseDayKey(record.Date, out var date)) continue;

            var normalized = date.Date;
            if (normalized > today) continue;
            if (earliest == null || normalized < earliest)
            {
                earliest = normalized;
            }
        }

        var start = earliest ?? today;
        return (start < today ? start : today, today);
    }

    private (DateTime Start, DateTime End) MergedKeyboardHeatmapDateBounds()
    {
        var localBounds = StatsManager.Instance.GetKeyboardHeatmapDateBounds();
        var today = localBounds.End;
        var start = localBounds.Start;

        foreach (var record in RemoteRecords.Where(r => r.DeviceId != LocalDeviceId))
        {
            if (!RecordHasKeyboardHeatmapData(record)) continue;
            if (!TryParseDayKey(record.Date, out var date)) continue;

            var normalized = date.Date;
            if (normalized > today) continue;
            if (normalized < start) start = normalized;
        }

        return (start < today ? start : today, today);
    }

    private StatsManager.KeyboardHeatmapDay MergedKeyboardHeatmapDay(DateTime date)
    {
        var localDay = StatsManager.Instance.GetKeyboardHeatmapDay(date);
        var mergedCounts = new Dictionary<string, int>(localDay.KeyCounts, StringComparer.Ordinal);
        var totalPresses = localDay.TotalKeyPresses;
        var dayKey = DayKey(date);

        foreach (var record in RemoteRecords.Where(r => r.Date == dayKey && r.DeviceId != LocalDeviceId))
        {
            if (record.Stats.KeyPressCounts == null) continue;
            foreach (var kvp in record.Stats.KeyPressCounts)
            {
                var count = Math.Max(0, kvp.Value);
                if (count <= 0) continue;
                mergedCounts[kvp.Key] = mergedCounts.TryGetValue(kvp.Key, out var current) ? current + count : count;
            }

            totalPresses += record.Stats.KeyPresses;
        }

        return new StatsManager.KeyboardHeatmapDay
        {
            Date = date,
            TotalKeyPresses = totalPresses,
            KeyCounts = mergedCounts
        };
    }

    private static bool RecordHasKeyboardHeatmapData(CloudStatsRecord record) =>
        record.Stats.KeyPresses > 0 ||
        (record.Stats.KeyPressCounts?.Count ?? 0) > 0;

    private static DailyStats DailyStatsFromPayload(CloudDailyStatsPayload payload, DateTime date)
    {
        return new DailyStats(date)
        {
            KeyPresses = payload.KeyPresses,
            KeyPressCounts = payload.KeyPressCounts != null
                ? new Dictionary<string, int>(payload.KeyPressCounts)
                : new Dictionary<string, int>(),
            LeftClicks = payload.LeftClicks,
            RightClicks = payload.RightClicks,
            SideBackClicks = payload.SideBackClicks,
            SideForwardClicks = payload.SideForwardClicks,
            MouseDistance = payload.MouseDistance,
            ScrollDistance = payload.ScrollDistance,
            PeakKPS = payload.PeakKPS,
            PeakCPS = payload.PeakCPS
        };
    }

    private void StartAutoSyncIfNeeded()
    {
        if (!IsSyncEnabled || !IsAuthenticated)
        {
            StopAutoSync();
            return;
        }

        if (_autoSyncCts != null) return;

        var cts = new CancellationTokenSource();
        _autoSyncCts = cts;

        _ = Task.Run(async () =>
        {
            while (!cts.Token.IsCancellationRequested)
            {
                try
                {
                    await Task.Delay(_autoSyncInterval, cts.Token).ConfigureAwait(false);
                }
                catch (OperationCanceledException)
                {
                    break;
                }

                if (!IsSyncEnabled || !IsAuthenticated) break;

                SetStatus(CloudSyncStatusKind.Syncing, null, null);
                var error = await RunSyncPipelineAsync(includePull: true).ConfigureAwait(false);
                if (error != null)
                {
                    SetStatus(CloudSyncStatusKind.Failed, null, error);
                }
                else
                {
                    SetStatus(CloudSyncStatusKind.Success, DateTime.Now, null);
                }
            }
        });
    }

    private void StopAutoSync()
    {
        _autoSyncCts?.Cancel();
        _autoSyncCts?.Dispose();
        _autoSyncCts = null;
    }

    private void CancelUploadDebounce()
    {
        _uploadDebounceCts?.Cancel();
        _uploadDebounceCts?.Dispose();
        _uploadDebounceCts = null;
    }

    private void PersistAuth(string username, string token, string userId)
    {
        CloudSyncCredentialStore.SaveToken(token);
        CloudSyncCredentialStore.SaveUserId(userId);
        Settings.CloudSyncUsername = username;
        StatsManager.Instance.SaveSettings();
    }

    private string AuthToken()
    {
        var token = CloudSyncCredentialStore.LoadToken();
        if (string.IsNullOrWhiteSpace(token))
        {
            throw new CloudSyncException(Properties.Strings.Sync_Error_NotAuthenticated);
        }

        return token;
    }

    private void SetRemoteData(List<CloudDevice> devices, List<CloudStatsRecord> records)
    {
        lock (_stateLock)
        {
            _devices = devices;
            _remoteRecords = records;
        }

        NotifyStateChanged();
    }

    private void SetStatus(CloudSyncStatusKind kind, DateTime? successAt, string? errorMessage)
    {
        lock (_stateLock)
        {
            _status = new CloudSyncStatus
            {
                Kind = kind,
                SuccessAt = successAt,
                ErrorMessage = errorMessage
            };
        }

        NotifyStateChanged();
    }

    private void ClearSessionState()
    {
        lock (_stateLock)
        {
            _devices = new List<CloudDevice>();
            _remoteRecords = new List<CloudStatsRecord>();
            _status = new CloudSyncStatus();
        }

        NotifyStateChanged();
    }

    private void NotifyStateChanged() => StateChanged?.Invoke();

    private static string PlatformDisplayName(string platform) =>
        (platform ?? "").ToLowerInvariant() switch
        {
            "macos" => "macOS",
            "windows" => "Windows",
            "linux" => "Linux",
            _ => string.IsNullOrWhiteSpace(platform) ? "Device" : platform
        };

    private static string TruncatedTabLabel(string label, int maxLength = 14)
    {
        if (label.Length <= maxLength) return label;
        return label.Substring(0, Math.Max(1, maxLength - 1)) + "…";
    }

    public static string DayKey(DateTime date) =>
        date.Date.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);

    private static bool TryParseDayKey(string dayKey, out DateTime date) =>
        DateTime.TryParseExact(
            dayKey,
            "yyyy-MM-dd",
            CultureInfo.InvariantCulture,
            DateTimeStyles.None,
            out date);
}
