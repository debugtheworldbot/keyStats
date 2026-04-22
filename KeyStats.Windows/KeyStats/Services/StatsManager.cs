using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Timers;
using KeyStats.Models;
using Timer = System.Timers.Timer;

namespace KeyStats.Services;

public class StatsManager : IDisposable
{
    public enum StatsUpdateKind
    {
        Full,
        MouseDistanceOnly
    }

    private static StatsManager? _instance;
    public static StatsManager Instance => _instance ??= new StatsManager();

    private const double DefaultMetersPerPixel = AppSettings.DefaultMouseMetersPerPixel;

    private readonly string _dataFolder;
    private readonly string _statsFilePath;
    private readonly string _historyFilePath;
    private readonly string _settingsFilePath;

    private readonly object _lock = new();
    private Timer? _saveTimer;
    private Timer? _midnightTimer;
    private Timer? _statsUpdateTimer;
    private Timer? _mouseMoveUpdateTimer;
    private Timer? _settingsSaveTimer;

    private readonly double _saveInterval = 2000; // 2 seconds
    private readonly double _statsUpdateDebounceInterval = 300; // 0.3 seconds
    private readonly double _mouseMoveIdleUpdateInterval = 350; // 0.35 seconds
    private readonly double _settingsSaveInterval = 500; // 0.5 seconds — collapses per-keystroke text-changed bursts
    private const int MaxMissingDayBackfillDays = 31;
    private bool _pendingSave;
    private bool _pendingStatsUpdate;
    private bool _pendingMouseMoveUpdate;
    private bool _pendingSettingsSave;

    // KPS/CPS peak tracking (1-second sliding window)
    private readonly Queue<DateTime> _recentKeyTimestamps = new();
    private readonly Queue<DateTime> _recentClickTimestamps = new();

    private int _lastNotifiedKeyPresses;
    private int _lastNotifiedClicks;

    public DailyStats CurrentStats { get; private set; }
    public AppSettings Settings { get; private set; }
    public Dictionary<string, DailyStats> History { get; private set; } = new();

    public event Action? StatsUpdateRequested;
    public event Action<StatsUpdateKind>? StatsChanged;

    private StatsManager()
    {
        _dataFolder = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "KeyStats");
        Directory.CreateDirectory(_dataFolder);

        _statsFilePath = Path.Combine(_dataFolder, "daily_stats.json");
        _historyFilePath = Path.Combine(_dataFolder, "history.json");
        _settingsFilePath = Path.Combine(_dataFolder, "settings.json");

        Settings = LoadSettings();
        History = LoadHistory();
        CurrentStats = LoadStats() ?? new DailyStats();

        if (CurrentStats.Date.Date != DateTime.Today)
        {
            SynchronizeCurrentDay(DateTime.Today, notifyStatsUpdate: false);
        }
        else
        {
            UpdateNotificationBaselines();
            SaveStats();
        }

        SetupMidnightReset();
        SetupInputMonitor();
    }

    private void SetupInputMonitor()
    {
        var monitor = InputMonitorService.Instance;
        monitor.KeyPressed += OnKeyPressed;
        monitor.LeftMouseClicked += OnLeftClick;
        monitor.RightMouseClicked += OnRightClick;
        monitor.MiddleMouseClicked += OnMiddleClick;
        monitor.SideBackMouseClicked += OnSideBackClick;
        monitor.SideForwardMouseClicked += OnSideForwardClick;
        monitor.MouseMoved += OnMouseMoved;
        monitor.MouseScrolled += OnMouseScrolled;
    }

    private void UpdateAppStats(string appName, string displayName, Action<AppStats> updateAction)
    {
        if (string.IsNullOrWhiteSpace(appName)) return;

        var normalizedAppName = appName.Trim();
        var normalizedDisplayName = NormalizeDisplayName(normalizedAppName, displayName);

        if (!CurrentStats.AppStats.TryGetValue(normalizedAppName, out var appStats))
        {
            appStats = new AppStats(normalizedAppName, normalizedDisplayName);
            CurrentStats.AppStats[normalizedAppName] = appStats;
        }
        else if (ShouldUpdateDisplayName(appStats, normalizedDisplayName))
        {
            appStats.DisplayName = normalizedDisplayName;
        }

        updateAction(appStats);
    }

    private static string NormalizeDisplayName(string appName, string displayName)
    {
        if (string.IsNullOrWhiteSpace(displayName))
        {
            return appName;
        }

        var normalizedDisplay = displayName.Trim();
        return string.Equals(normalizedDisplay, "Unknown", StringComparison.OrdinalIgnoreCase)
            ? appName
            : normalizedDisplay;
    }

    private static bool ShouldUpdateDisplayName(AppStats appStats, string incomingDisplayName)
    {
        if (string.IsNullOrWhiteSpace(incomingDisplayName))
        {
            return false;
        }

        if (string.Equals(appStats.DisplayName, incomingDisplayName, StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        if (string.IsNullOrWhiteSpace(appStats.DisplayName))
        {
            return true;
        }

        // Prefer richer labels over raw process names (e.g. javaw -> Minecraft).
        return string.Equals(appStats.DisplayName, appStats.AppName, StringComparison.OrdinalIgnoreCase) &&
               !string.Equals(incomingDisplayName, appStats.AppName, StringComparison.OrdinalIgnoreCase);
    }

    private void OnKeyPressed(string keyName, string appName, string displayName)
    {
        lock (_lock)
        {
            EnsureCurrentDay();
            CurrentStats.KeyPresses++;
            if (!string.IsNullOrEmpty(keyName))
            {
                if (!CurrentStats.KeyPressCounts.ContainsKey(keyName))
                {
                    CurrentStats.KeyPressCounts[keyName] = 0;
                }
                CurrentStats.KeyPressCounts[keyName]++;
            }
            UpdateAppStats(appName, displayName, stats => stats.RecordKeyPress());
        }

        RecordKeyForPeakKPS();
        NotifyStatsUpdate();
        NotifyKeyPressThresholdIfNeeded();
        ScheduleSave();
    }

    private void OnLeftClick(string appName, string displayName)
    {
        lock (_lock)
        {
            EnsureCurrentDay();
            CurrentStats.LeftClicks++;
            UpdateAppStats(appName, displayName, stats => stats.RecordLeftClick());
        }

        RecordClickForPeakCPS();
        NotifyStatsUpdate();
        NotifyClickThresholdIfNeeded();
        ScheduleSave();
    }

    private void OnRightClick(string appName, string displayName)
    {
        lock (_lock)
        {
            EnsureCurrentDay();
            CurrentStats.RightClicks++;
            UpdateAppStats(appName, displayName, stats => stats.RecordRightClick());
        }

        RecordClickForPeakCPS();
        NotifyStatsUpdate();
        NotifyClickThresholdIfNeeded();
        ScheduleSave();
    }

    private void OnMiddleClick(string appName, string displayName)
    {
        lock (_lock)
        {
            EnsureCurrentDay();
            CurrentStats.MiddleClicks++;
            UpdateAppStats(appName, displayName, stats => stats.RecordMiddleClick());
        }

        RecordClickForPeakCPS();
        NotifyStatsUpdate();
        NotifyClickThresholdIfNeeded();
        ScheduleSave();
    }

    private void OnSideBackClick(string appName, string displayName)
    {
        lock (_lock)
        {
            EnsureCurrentDay();
            CurrentStats.SideBackClicks++;
            UpdateAppStats(appName, displayName, stats => stats.RecordSideBackClick());
        }

        RecordClickForPeakCPS();
        NotifyStatsUpdate();
        NotifyClickThresholdIfNeeded();
        ScheduleSave();
    }

    private void OnSideForwardClick(string appName, string displayName)
    {
        lock (_lock)
        {
            EnsureCurrentDay();
            CurrentStats.SideForwardClicks++;
            UpdateAppStats(appName, displayName, stats => stats.RecordSideForwardClick());
        }

        RecordClickForPeakCPS();
        NotifyStatsUpdate();
        NotifyClickThresholdIfNeeded();
        ScheduleSave();
    }

    private void OnMouseMoved(double distance)
    {
        lock (_lock)
        {
            EnsureCurrentDay();
            CurrentStats.MouseDistance += distance;
        }

        ScheduleMouseMoveIdleUpdate();
        ScheduleSave();
    }

    private void OnMouseScrolled(double distance, string appName, string displayName)
    {
        lock (_lock)
        {
            EnsureCurrentDay();
            CurrentStats.ScrollDistance += Math.Abs(distance);
            UpdateAppStats(appName, displayName, stats => stats.AddScrollDistance(Math.Abs(distance)));
        }

        ScheduleDebouncedStatsUpdate();
        ScheduleSave();
    }

    private void EnsureCurrentDay()
    {
        SynchronizeCurrentDay(DateTime.Today, notifyStatsUpdate: true);
    }

    private void RecordKeyForPeakKPS()
    {
        var now = DateTime.UtcNow;
        var cutoff = now.AddSeconds(-1.0);
        lock (_lock)
        {
            _recentKeyTimestamps.Enqueue(now);
            while (_recentKeyTimestamps.Count > 0 && _recentKeyTimestamps.Peek() <= cutoff)
            {
                _recentKeyTimestamps.Dequeue();
            }
            var currentKPS = (double)_recentKeyTimestamps.Count;
            if (currentKPS > CurrentStats.PeakKPS)
            {
                CurrentStats.PeakKPS = currentKPS;
            }
        }
    }

    private void RecordClickForPeakCPS()
    {
        var now = DateTime.UtcNow;
        var cutoff = now.AddSeconds(-1.0);
        lock (_lock)
        {
            _recentClickTimestamps.Enqueue(now);
            while (_recentClickTimestamps.Count > 0 && _recentClickTimestamps.Peek() <= cutoff)
            {
                _recentClickTimestamps.Dequeue();
            }
            var currentCPS = (double)_recentClickTimestamps.Count;
            if (currentCPS > CurrentStats.PeakCPS)
            {
                CurrentStats.PeakCPS = currentCPS;
            }
        }
    }

    private void ScheduleSave()
    {
        lock (_lock)
        {
            _pendingSave = true;

            if (_saveTimer == null)
            {
                _saveTimer = new Timer(_saveInterval)
                {
                    AutoReset = false
                };
                _saveTimer.Elapsed += (_, _) =>
                {
                    lock (_lock)
                    {
                        if (!_pendingSave)
                        {
                            return;
                        }

                        _pendingSave = false;
                    }

                    SaveStats();
                };
            }

            var saveTimer = _saveTimer;
            if (saveTimer == null)
            {
                return;
            }

            saveTimer.Stop();
            saveTimer.Start();
        }
    }

    private void ScheduleDebouncedStatsUpdate()
    {
        lock (_lock)
        {
            if (_pendingStatsUpdate) return;
            _pendingStatsUpdate = true;
        }

        _statsUpdateTimer?.Stop();
        _statsUpdateTimer = new Timer(_statsUpdateDebounceInterval);
        _statsUpdateTimer.Elapsed += (_, _) =>
        {
            _statsUpdateTimer?.Stop();
            lock (_lock)
            {
                _pendingStatsUpdate = false;
            }
            NotifyStatsUpdate();
        };
        _statsUpdateTimer.Start();
    }

    private void ScheduleMouseMoveIdleUpdate()
    {
        lock (_lock)
        {
            _pendingMouseMoveUpdate = true;
        }

        if (_mouseMoveUpdateTimer == null)
        {
            _mouseMoveUpdateTimer = new Timer(_mouseMoveIdleUpdateInterval)
            {
                AutoReset = false
            };
            _mouseMoveUpdateTimer.Elapsed += (_, _) =>
            {
                lock (_lock)
                {
                    if (!_pendingMouseMoveUpdate)
                    {
                        return;
                    }

                    _pendingMouseMoveUpdate = false;
                }

                NotifyStatsUpdate(StatsUpdateKind.MouseDistanceOnly);
            };
        }

        var mouseMoveUpdateTimer = _mouseMoveUpdateTimer;
        if (mouseMoveUpdateTimer == null)
        {
            return;
        }

        mouseMoveUpdateTimer.Stop();
        mouseMoveUpdateTimer.Start();
    }

    private void NotifyStatsUpdate(StatsUpdateKind kind = StatsUpdateKind.Full)
    {
        StatsChanged?.Invoke(kind);

        if (kind == StatsUpdateKind.Full)
        {
            StatsUpdateRequested?.Invoke();
        }
    }

    #region Persistence

    private void SaveStats()
    {
        DailyStats statsSnapshot;

        lock (_lock)
        {
            statsSnapshot = CloneDailyStats(CurrentStats, CurrentStats.Date.Date);
            // Mirror today's counters into the in-memory History dict so query paths
            // that read from History stay in sync. The history *file* is no longer
            // re-written here — past-day data only changes at day rollover / import /
            // reset / shutdown, so writing it every 2s is wasted I/O.
            RecordCurrentStatsToHistory();
        }

        WriteJsonDurable(_statsFilePath, statsSnapshot, "stats");
    }

    private void SaveHistory()
    {
        Dictionary<string, DailyStats> snapshot;
        lock (_lock)
        {
            snapshot = CloneHistorySnapshot(History);
        }
        WriteJsonDurable(_historyFilePath, snapshot, "history");
    }

    private DailyStats? LoadStats()
    {
        var primary = TryDeserialize<DailyStats>(_statsFilePath);
        if (primary != null) return primary;

        var backup = TryDeserialize<DailyStats>(_statsFilePath + ".bak");
        if (backup != null)
        {
            System.Diagnostics.Debug.WriteLine("Recovered daily_stats from .bak");
            return backup;
        }

        // Last resort: today's entry in already-loaded History.
        var todayKey = DateTime.Today.ToString("yyyy-MM-dd");
        if (History.TryGetValue(todayKey, out var fromHistory))
        {
            System.Diagnostics.Debug.WriteLine("Recovered daily_stats from history.json");
            // Force date to today: this branch only fires when history has a today-keyed
            // entry, so a corrupt Date field shouldn't cause SynchronizeCurrentDay to
            // discard the recovered counts on startup.
            return CloneDailyStats(fromHistory, DateTime.Today);
        }

        return null;
    }

    private void RecordCurrentStatsToHistory()
    {
        var key = CurrentStats.Date.ToString("yyyy-MM-dd");
        // 创建 CurrentStats 的副本，避免引用共享导致的数据丢失
        var statsCopy = new DailyStats(CurrentStats.Date)
        {
            KeyPresses = CurrentStats.KeyPresses,
            LeftClicks = CurrentStats.LeftClicks,
            RightClicks = CurrentStats.RightClicks,
            MiddleClicks = CurrentStats.MiddleClicks,
            SideBackClicks = CurrentStats.SideBackClicks,
            SideForwardClicks = CurrentStats.SideForwardClicks,
            MouseDistance = CurrentStats.MouseDistance,
            ScrollDistance = CurrentStats.ScrollDistance,
            PeakKPS = CurrentStats.PeakKPS,
            PeakCPS = CurrentStats.PeakCPS,
            KeyPressCounts = new Dictionary<string, int>(CurrentStats.KeyPressCounts),
            AppStats = CurrentStats.AppStats.ToDictionary(k => k.Key, v => new AppStats(v.Value))
        };
        History[key] = statsCopy;
    }

    private Dictionary<string, DailyStats> CloneHistorySnapshot(Dictionary<string, DailyStats> source)
    {
        return source.ToDictionary(
            kvp => kvp.Key,
            kvp => CloneDailyStats(kvp.Value, kvp.Value.Date.Date));
    }


    private Dictionary<string, DailyStats> LoadHistory()
    {
        var primary = TryDeserialize<Dictionary<string, DailyStats>>(_historyFilePath);
        if (primary != null) return primary;

        var backup = TryDeserialize<Dictionary<string, DailyStats>>(_historyFilePath + ".bak");
        if (backup != null)
        {
            System.Diagnostics.Debug.WriteLine("Recovered history from .bak");
            return backup;
        }

        return new();
    }

    public void SaveSettings()
    {
        // UI call sites can fire per-keystroke (e.g. NotificationSettingsWindow's
        // OnThresholdTextChanged), so debounce the durable write — otherwise every
        // keystroke would block the UI thread on a synchronous FlushFileBuffers.
        lock (_lock)
        {
            _pendingSettingsSave = true;

            if (_settingsSaveTimer == null)
            {
                _settingsSaveTimer = new Timer(_settingsSaveInterval) { AutoReset = false };
                _settingsSaveTimer.Elapsed += (_, _) =>
                {
                    lock (_lock)
                    {
                        if (!_pendingSettingsSave) return;
                        _pendingSettingsSave = false;
                    }

                    FlushSettings();
                };
            }

            _settingsSaveTimer.Stop();
            _settingsSaveTimer.Start();
        }
    }

    private void FlushSettings()
    {
        WriteJsonDurable(_settingsFilePath, Settings, "settings");
    }

    private AppSettings LoadSettings()
    {
        return TryDeserialize<AppSettings>(_settingsFilePath)
            ?? TryDeserialize<AppSettings>(_settingsFilePath + ".bak")
            ?? new AppSettings();
    }

    private static void WriteJsonDurable<T>(string targetPath, T value, string contextLabel)
    {
        var tempPath = targetPath + ".tmp";
        var backupPath = targetPath + ".bak";

        try
        {
            // Serialize inside the try/catch — System.Text.Json throws on NaN/Infinity
            // by default, and an autosave-thread escape would crash the app.
            var json = JsonSerializer.Serialize(value, new JsonSerializerOptions { WriteIndented = true });
            var bytes = Encoding.UTF8.GetBytes(json);

            // WriteThrough + Flush(true) ensures FlushFileBuffers is issued, so the
            // tmp file's data blocks are durable before we swap it in. Otherwise a
            // power loss right after Replace can leave a 0-byte / truncated target.
            using (var fs = new FileStream(
                tempPath,
                FileMode.Create,
                FileAccess.Write,
                FileShare.None,
                bufferSize: 4096,
                options: FileOptions.WriteThrough))
            {
                fs.Write(bytes, 0, bytes.Length);
                fs.Flush(true);
            }

            if (File.Exists(targetPath))
            {
                File.Replace(tempPath, targetPath, backupPath);
            }
            else
            {
                File.Move(tempPath, targetPath);
            }
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"Error saving {contextLabel}: {ex.Message}");
        }
    }

    private static T? TryDeserialize<T>(string path) where T : class
    {
        try
        {
            if (!File.Exists(path)) return null;
            var json = File.ReadAllText(path);
            if (string.IsNullOrWhiteSpace(json)) return null;
            return JsonSerializer.Deserialize<T>(json);
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"Error loading {path}: {ex.Message}");
            return null;
        }
    }

    #endregion

    #region Export

    public enum ImportMode
    {
        Overwrite,
        Merge
    }

    public byte[] ExportStatsData()
    {
        ExportPayload payload;
        lock (_lock)
        {
            var normalizedDate = CurrentStats.Date.Date;
            var currentCopy = CloneDailyStats(CurrentStats, normalizedDate);
            var exportHistory = new Dictionary<string, DailyStats>(History.Count + 1);

            foreach (var kvp in History)
            {
                exportHistory[kvp.Key] = CloneDailyStats(kvp.Value, kvp.Value.Date.Date);
            }

            var key = normalizedDate.ToString("yyyy-MM-dd");
            // Ensure current stats are included (overwrite today's history entry if present).
            exportHistory[key] = currentCopy;

            payload = new ExportPayload
            {
                Version = 1,
                ExportedAt = DateTime.UtcNow,
                CurrentStats = currentCopy,
                History = exportHistory
            };
        }

        var options = new JsonSerializerOptions
        {
            WriteIndented = true,
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase
        };
        var json = JsonSerializer.Serialize(payload, options);
        return Encoding.UTF8.GetBytes(json);
    }

    public void ImportStatsData(byte[] data)
    {
        ImportStatsData(data, ImportMode.Overwrite);
    }

    public void ImportStatsData(byte[] data, ImportMode mode)
    {
        if (data == null || data.Length == 0)
        {
            throw new InvalidDataException("导入文件为空。");
        }

        var deserializeOptions = new JsonSerializerOptions
        {
            PropertyNameCaseInsensitive = true
        };

        ExportPayload payload;
        try
        {
            payload = JsonSerializer.Deserialize<ExportPayload>(data, deserializeOptions)
                ?? throw new InvalidDataException("数据格式无效。");
        }
        catch (InvalidDataException)
        {
            throw;
        }
        catch (Exception ex)
        {
            throw new InvalidDataException("数据格式无效。", ex);
        }

        if (payload.Version != 1)
        {
            throw new InvalidDataException("不支持的导出版本。");
        }

        lock (_lock)
        {
            _saveTimer?.Stop();
            _pendingSave = false;
            _statsUpdateTimer?.Stop();
            _pendingStatsUpdate = false;
            _mouseMoveUpdateTimer?.Stop();
            _pendingMouseMoveUpdate = false;

            var importedHistory = NormalizeHistory(payload.History);
            var importedCurrent = NormalizeDailyStats(payload.CurrentStats, DateTime.Today);
            importedHistory[importedCurrent.Date.ToString("yyyy-MM-dd")] = CloneDailyStats(importedCurrent, importedCurrent.Date);

            var todayKey = DateTime.Today.ToString("yyyy-MM-dd");
            if (mode == ImportMode.Merge)
            {
                var mergedHistory = CloneHistorySnapshot(History);
                var currentSnapshot = CloneDailyStats(CurrentStats, CurrentStats.Date.Date);
                mergedHistory[currentSnapshot.Date.ToString("yyyy-MM-dd")] = currentSnapshot;

                foreach (var kvp in importedHistory)
                {
                    if (mergedHistory.TryGetValue(kvp.Key, out var existing))
                    {
                        mergedHistory[kvp.Key] = MergeDailyStats(existing, kvp.Value);
                    }
                    else
                    {
                        mergedHistory[kvp.Key] = CloneDailyStats(kvp.Value, kvp.Value.Date.Date);
                    }
                }

                History = mergedHistory;
            }
            else
            {
                History = importedHistory;
            }

            CurrentStats = History.TryGetValue(todayKey, out var todayStats)
                ? CloneDailyStats(todayStats, todayStats.Date.Date)
                : new DailyStats(DateTime.Today);

            UpdateNotificationBaselines();
        }

        SaveStats();
        SaveHistory();
        NotifyStatsUpdate();
    }

    private static DailyStats CloneDailyStats(DailyStats source, DateTime dateOverride)
    {
        var normalizedDate = dateOverride.Date;
        return new DailyStats(normalizedDate)
        {
            KeyPresses = source.KeyPresses,
            LeftClicks = source.LeftClicks,
            RightClicks = source.RightClicks,
            MiddleClicks = source.MiddleClicks,
            SideBackClicks = source.SideBackClicks,
            SideForwardClicks = source.SideForwardClicks,
            MouseDistance = source.MouseDistance,
            ScrollDistance = source.ScrollDistance,
            PeakKPS = source.PeakKPS,
            PeakCPS = source.PeakCPS,
            KeyPressCounts = new Dictionary<string, int>(source.KeyPressCounts),
            AppStats = source.AppStats.ToDictionary(k => k.Key, v => new AppStats(v.Value))
        };
    }

    private static Dictionary<string, DailyStats> NormalizeHistory(Dictionary<string, DailyStats>? source)
    {
        var normalized = new Dictionary<string, DailyStats>();
        if (source == null)
        {
            return normalized;
        }

        foreach (var kvp in source)
        {
            var fallbackDate = DateTime.Today;
            if (DateTime.TryParseExact(
                kvp.Key,
                "yyyy-MM-dd",
                CultureInfo.InvariantCulture,
                DateTimeStyles.None,
                out var parsedDate))
            {
                fallbackDate = parsedDate.Date;
            }

            var daily = NormalizeDailyStats(kvp.Value, fallbackDate);
            normalized[daily.Date.ToString("yyyy-MM-dd")] = daily;
        }

        return normalized;
    }

    private static DailyStats NormalizeDailyStats(DailyStats? source, DateTime fallbackDate)
    {
        var normalizedDate = source?.Date.Date ?? fallbackDate.Date;
        if (normalizedDate == DateTime.MinValue.Date)
        {
            normalizedDate = fallbackDate.Date;
        }

        var keyPressCounts = new Dictionary<string, int>(StringComparer.Ordinal);
        if (source?.KeyPressCounts != null)
        {
            foreach (var kvp in source.KeyPressCounts)
            {
                var key = (kvp.Key ?? string.Empty).Trim();
                var count = Math.Max(0, kvp.Value);
                if (string.IsNullOrWhiteSpace(key) || count <= 0)
                {
                    continue;
                }

                keyPressCounts[key] = count;
            }
        }

        var appStats = new Dictionary<string, AppStats>(StringComparer.OrdinalIgnoreCase);
        if (source?.AppStats != null)
        {
            foreach (var kvp in source.AppStats)
            {
                var keyName = (kvp.Key ?? string.Empty).Trim();
                var sourceStats = kvp.Value ?? new AppStats();
                var appName = string.IsNullOrWhiteSpace(sourceStats.AppName)
                    ? keyName
                    : sourceStats.AppName.Trim();

                if (string.IsNullOrWhiteSpace(appName))
                {
                    continue;
                }

                var displayName = string.IsNullOrWhiteSpace(sourceStats.DisplayName)
                    ? appName
                    : sourceStats.DisplayName.Trim();

                appStats[appName] = new AppStats(appName, displayName)
                {
                    KeyPresses = Math.Max(0, sourceStats.KeyPresses),
                    LeftClicks = Math.Max(0, sourceStats.LeftClicks),
                    RightClicks = Math.Max(0, sourceStats.RightClicks),
                    MiddleClicks = Math.Max(0, sourceStats.MiddleClicks),
                    SideBackClicks = Math.Max(0, sourceStats.SideBackClicks),
                    SideForwardClicks = Math.Max(0, sourceStats.SideForwardClicks),
                    ScrollDistance = SanitizeDistance(sourceStats.ScrollDistance)
                };
            }
        }

        return new DailyStats(normalizedDate)
        {
            KeyPresses = Math.Max(0, source?.KeyPresses ?? 0),
            KeyPressCounts = keyPressCounts,
            LeftClicks = Math.Max(0, source?.LeftClicks ?? 0),
            RightClicks = Math.Max(0, source?.RightClicks ?? 0),
            MiddleClicks = Math.Max(0, source?.MiddleClicks ?? 0),
            SideBackClicks = Math.Max(0, source?.SideBackClicks ?? 0),
            SideForwardClicks = Math.Max(0, source?.SideForwardClicks ?? 0),
            MouseDistance = SanitizeDistance(source?.MouseDistance ?? 0),
            ScrollDistance = SanitizeDistance(source?.ScrollDistance ?? 0),
            PeakKPS = Math.Max(0, source?.PeakKPS ?? 0),
            PeakCPS = Math.Max(0, source?.PeakCPS ?? 0),
            AppStats = appStats
        };
    }

    private static DailyStats MergeDailyStats(DailyStats existing, DailyStats incoming)
    {
        var normalizedExisting = NormalizeDailyStats(existing, existing.Date.Date);
        var normalizedIncoming = NormalizeDailyStats(incoming, normalizedExisting.Date.Date);

        var keyPressCounts = new Dictionary<string, int>(normalizedExisting.KeyPressCounts, StringComparer.Ordinal);
        foreach (var kvp in normalizedIncoming.KeyPressCounts)
        {
            keyPressCounts[kvp.Key] = keyPressCounts.TryGetValue(kvp.Key, out var current)
                ? current + kvp.Value
                : kvp.Value;
        }

        var appStats = new Dictionary<string, AppStats>(StringComparer.OrdinalIgnoreCase);
        foreach (var kvp in normalizedExisting.AppStats)
        {
            appStats[kvp.Key] = new AppStats(kvp.Value);
        }

        foreach (var kvp in normalizedIncoming.AppStats)
        {
            if (!appStats.TryGetValue(kvp.Key, out var existingApp))
            {
                appStats[kvp.Key] = new AppStats(kvp.Value);
                continue;
            }

            if (string.IsNullOrWhiteSpace(existingApp.DisplayName) && !string.IsNullOrWhiteSpace(kvp.Value.DisplayName))
            {
                existingApp.DisplayName = kvp.Value.DisplayName;
            }

            existingApp.KeyPresses += kvp.Value.KeyPresses;
            existingApp.LeftClicks += kvp.Value.LeftClicks;
            existingApp.RightClicks += kvp.Value.RightClicks;
            existingApp.MiddleClicks += kvp.Value.MiddleClicks;
            existingApp.SideBackClicks += kvp.Value.SideBackClicks;
            existingApp.SideForwardClicks += kvp.Value.SideForwardClicks;
            existingApp.ScrollDistance += kvp.Value.ScrollDistance;
        }

        return new DailyStats(normalizedExisting.Date.Date)
        {
            KeyPresses = normalizedExisting.KeyPresses + normalizedIncoming.KeyPresses,
            LeftClicks = normalizedExisting.LeftClicks + normalizedIncoming.LeftClicks,
            RightClicks = normalizedExisting.RightClicks + normalizedIncoming.RightClicks,
            MiddleClicks = normalizedExisting.MiddleClicks + normalizedIncoming.MiddleClicks,
            SideBackClicks = normalizedExisting.SideBackClicks + normalizedIncoming.SideBackClicks,
            SideForwardClicks = normalizedExisting.SideForwardClicks + normalizedIncoming.SideForwardClicks,
            MouseDistance = normalizedExisting.MouseDistance + normalizedIncoming.MouseDistance,
            ScrollDistance = normalizedExisting.ScrollDistance + normalizedIncoming.ScrollDistance,
            PeakKPS = Math.Max(normalizedExisting.PeakKPS, normalizedIncoming.PeakKPS),
            PeakCPS = Math.Max(normalizedExisting.PeakCPS, normalizedIncoming.PeakCPS),
            KeyPressCounts = keyPressCounts,
            AppStats = appStats
        };
    }

    private static double SanitizeDistance(double value)
    {
        if (double.IsNaN(value) || double.IsInfinity(value) || value < 0)
        {
            return 0;
        }
        return value;
    }

    private sealed class ExportPayload
    {
        public int Version { get; set; }
        public DateTime ExportedAt { get; set; } = DateTime.UtcNow;
        public DailyStats CurrentStats { get; set; } = new();
        public Dictionary<string, DailyStats> History { get; set; } = new();
    }

    #endregion

    #region Midnight Reset

    private void SetupMidnightReset()
    {
        ScheduleNextMidnightReset();
    }

    private readonly object _midnightTimerLock = new();

    private void ScheduleNextMidnightReset()
    {
        lock (_midnightTimerLock)
        {
            _midnightTimer?.Stop();
            _midnightTimer?.Dispose();

            var now = DateTime.Now;
            var nextMidnight = DateTime.Today.AddDays(1);
            var timeUntilMidnight = nextMidnight - now;

            _midnightTimer = new Timer(timeUntilMidnight.TotalMilliseconds);
            _midnightTimer.Elapsed += (_, _) => PerformMidnightReset();
            _midnightTimer.AutoReset = false;
            _midnightTimer.Start();
        }
    }

    private void PerformMidnightReset()
    {
        SynchronizeCurrentDay(DateTime.Now, notifyStatsUpdate: true);
        ScheduleNextMidnightReset();
    }

    public void HandleSystemResume()
    {
        SynchronizeCurrentDay(DateTime.Now, notifyStatsUpdate: true);
        ScheduleNextMidnightReset();
    }

    public void ResetStats()
    {
        ResetStats(DateTime.Today);
    }

    private void ResetStats(DateTime date)
    {
        lock (_lock)
        {
            // 先保存旧数据到 History，避免丢失最后一次保存后的增量
            RecordCurrentStatsToHistory();

            // 然后创建新的统计对象
            CurrentStats = new DailyStats(date);
        }

        SaveHistory();
        UpdateNotificationBaselines();
        NotifyStatsUpdate();
        SaveStats();
    }

    private void SynchronizeCurrentDay(DateTime targetDate, bool notifyStatsUpdate)
    {
        var normalizedTargetDate = targetDate.Date;
        var changed = false;

        lock (_lock)
        {
            var currentDate = CurrentStats.Date.Date;
            if (currentDate == normalizedTargetDate)
            {
                return;
            }

            History[currentDate.ToString("yyyy-MM-dd")] = CloneDailyStats(CurrentStats, currentDate);

            if (currentDate < normalizedTargetDate)
            {
                var missingDayCount = (normalizedTargetDate - currentDate).Days - 1;
                if (missingDayCount > 0 && missingDayCount <= MaxMissingDayBackfillDays)
                {
                    for (var missingDate = currentDate.AddDays(1); missingDate < normalizedTargetDate; missingDate = missingDate.AddDays(1))
                    {
                        var key = missingDate.ToString("yyyy-MM-dd");
                        if (!History.ContainsKey(key))
                        {
                            History[key] = new DailyStats(missingDate);
                        }
                    }
                }
            }

            CurrentStats = new DailyStats(normalizedTargetDate);
            _recentKeyTimestamps.Clear();
            _recentClickTimestamps.Clear();
            UpdateNotificationBaselines();
            changed = true;
        }

        if (!changed)
        {
            return;
        }

        if (notifyStatsUpdate)
        {
            NotifyStatsUpdate();
        }

        SaveStats();
        // Persist History too — past-day data just changed (today's counters were
        // archived and possibly missing days were back-filled).
        SaveHistory();
    }

    #endregion

    #region Notifications

    private void UpdateNotificationBaselines()
    {
        _lastNotifiedKeyPresses = NormalizedBaseline(CurrentStats.KeyPresses, Settings.KeyPressNotifyThreshold);
        _lastNotifiedClicks = NormalizedBaseline(CurrentStats.TotalClicks, Settings.ClickNotifyThreshold);
    }

    private int NormalizedBaseline(int count, int threshold)
    {
        if (threshold <= 0) return 0;
        return (count / threshold) * threshold;
    }

    private void NotifyKeyPressThresholdIfNeeded()
    {
        if (!Settings.NotificationsEnabled) return;
        var threshold = Settings.KeyPressNotifyThreshold;
        if (threshold <= 0) return;
        var count = CurrentStats.KeyPresses;
        
        // 计算当前计数对应的阈值里程碑（向下取整到最近的阈值倍数）
        var currentThreshold = NormalizedBaseline(count, threshold);
        
        // 如果当前阈值里程碑大于上次通知的阈值里程碑，则发送通知
        if (currentThreshold > _lastNotifiedKeyPresses)
        {
            _lastNotifiedKeyPresses = currentThreshold;
            NotificationService.Instance.SendThresholdNotification(NotificationService.Metric.KeyPresses, currentThreshold);
        }
    }

    private void NotifyClickThresholdIfNeeded()
    {
        if (!Settings.NotificationsEnabled) return;
        var threshold = Settings.ClickNotifyThreshold;
        if (threshold <= 0) return;
        var count = CurrentStats.TotalClicks;
        
        // 计算当前计数对应的阈值里程碑（向下取整到最近的阈值倍数）
        var currentThreshold = NormalizedBaseline(count, threshold);
        
        // 如果当前阈值里程碑大于上次通知的阈值里程碑，则发送通知
        if (currentThreshold > _lastNotifiedClicks)
        {
            _lastNotifiedClicks = currentThreshold;
            NotificationService.Instance.SendThresholdNotification(NotificationService.Metric.Clicks, currentThreshold);
        }
    }

    #endregion

    #region Formatting

    public string FormatNumber(int number)
    {
        if (number >= 1_000_000)
            return $"{number / 1_000_000.0:F1}M";
        if (number >= 1_000)
            return $"{number / 1_000.0:F1}k";
        return number.ToString("N0");
    }

    public List<(string Key, int Count)> GetKeyPressBreakdownSorted()
    {
        lock (_lock)
        {
            return CurrentStats.KeyPressCounts
                .OrderByDescending(x => x.Value)
                .ThenBy(x => x.Key, StringComparer.OrdinalIgnoreCase)
                .Select(x => (x.Key, x.Value))
                .ToList();
        }
    }

    public List<AppStats> GetAppStatsSorted(int limit = 5)
    {
        lock (_lock)
        {
            return CurrentStats.AppStats.Values
                .OrderByDescending(a => a.KeyPresses + a.TotalClicks + a.ScrollDistance)
                .Take(limit)
                .Select(a => new AppStats(a))
                .ToList();
        }
    }

    #endregion

    #region App Stats Summary

    public enum AppStatsRange { Today, Week, Month, All }

    public sealed class KeyboardHeatmapDay
    {
        public DateTime Date { get; set; }
        public int TotalKeyPresses { get; set; }
        public Dictionary<string, int> KeyCounts { get; set; } = new(StringComparer.Ordinal);
    }

    public List<AppStats> GetAppStatsSummary(AppStatsRange range)
    {
        lock (_lock)
        {
            var totals = new Dictionary<string, AppStats>(StringComparer.OrdinalIgnoreCase);
            var dates = GetAppStatsDates(range);
            foreach (var date in dates)
            {
                var daily = GetDailyStats(date);
                MergeAppStats(daily, totals);
            }

            return totals.Values
                .Select(a => new AppStats(a))
                .ToList();
        }
    }

    public (DateTime Start, DateTime End) GetKeyboardHeatmapDateBounds()
    {
        lock (_lock)
        {
            var today = DateTime.Today;
            var start = today;

            var currentDate = CurrentStats.Date.Date;
            if (currentDate <= today)
            {
                start = currentDate;
            }

            foreach (var daily in History.Values)
            {
                var candidate = daily.Date.Date;
                if (candidate <= today && candidate < start)
                {
                    start = candidate;
                }
            }

            return (start, today);
        }
    }

    public KeyboardHeatmapDay GetKeyboardHeatmapDay(DateTime date)
    {
        var normalizedDate = date.Date;
        lock (_lock)
        {
            var daily = GetDailyStats(normalizedDate);
            var aggregated = AggregateKeyboardHeatmapCounts(daily.KeyPressCounts);

            return new KeyboardHeatmapDay
            {
                Date = normalizedDate,
                TotalKeyPresses = Math.Max(0, daily.KeyPresses),
                KeyCounts = aggregated
            };
        }
    }

    private List<DateTime> GetAppStatsDates(AppStatsRange range)
    {
        var today = DateTime.Today;
        var dates = new List<DateTime>();

        if (range == AppStatsRange.All)
        {
            foreach (var key in History.Keys)
            {
                if (DateTime.TryParse(key, out var parsed))
                {
                    dates.Add(parsed.Date);
                }
            }
            if (!dates.Contains(today))
            {
                dates.Add(today);
            }
            return dates.Distinct().OrderBy(d => d).ToList();
        }

        var startDate = range switch
        {
            AppStatsRange.Today => today,
            AppStatsRange.Week => today.AddDays(-6),
            AppStatsRange.Month => today.AddDays(-29),
            _ => today
        };

        for (var date = startDate.Date; date <= today; date = date.AddDays(1))
        {
            dates.Add(date);
        }

        return dates;
    }

    private DailyStats GetDailyStats(DateTime date)
    {
        if (date.Date == CurrentStats.Date.Date)
        {
            return CurrentStats;
        }

        var key = date.ToString("yyyy-MM-dd");
        return History.TryGetValue(key, out var stats) ? stats : new DailyStats(date);
    }

    private static Dictionary<string, int> AggregateKeyboardHeatmapCounts(Dictionary<string, int> keyPressCounts)
    {
        var aggregated = new Dictionary<string, int>(StringComparer.Ordinal);

        foreach (var kvp in keyPressCounts)
        {
            var count = Math.Max(0, kvp.Value);
            if (count <= 0)
            {
                continue;
            }

            var rawKey = kvp.Key ?? string.Empty;
            var components = rawKey
                .Split(new[] { '+' }, StringSplitOptions.RemoveEmptyEntries)
                .Select(part => part.Trim())
                .Where(part => !string.IsNullOrWhiteSpace(part))
                .ToList();

            if (components.Count == 0)
            {
                components.Add(rawKey.Trim());
            }

            foreach (var sourceKey in components)
            {
                if (NormalizeKeyboardHeatmapKey(sourceKey) is not string normalizedKey || string.IsNullOrWhiteSpace(normalizedKey))
                {
                    continue;
                }

                aggregated[normalizedKey] = SafeAdd(aggregated.TryGetValue(normalizedKey, out var current) ? current : 0, count);
            }
        }

        return aggregated;
    }

    private static string? NormalizeKeyboardHeatmapKey(string rawKey)
    {
        var trimmed = (rawKey ?? string.Empty).Trim();
        if (string.IsNullOrWhiteSpace(trimmed))
        {
            return null;
        }

        var upper = trimmed.ToUpperInvariant();
        if (upper.Length == 1)
        {
            return upper;
        }

        if (upper.StartsWith("F", StringComparison.Ordinal) && int.TryParse(upper.Substring(1), out _))
        {
            return upper;
        }

        if (upper.StartsWith("NUM", StringComparison.Ordinal))
        {
            var suffix = upper.Substring(3);
            if (suffix.Length == 1 && char.IsDigit(suffix[0]))
            {
                return suffix;
            }

            if (suffix == ".")
            {
                return ".";
            }
            if (suffix == "+")
            {
                return "=";
            }
            if (suffix == "-")
            {
                return "-";
            }
            if (suffix == "/")
            {
                return "/";
            }
        }

        switch (upper)
        {
            case "CMD":
            case "COMMAND":
            case "WIN":
                return "Cmd";
            case "LWIN":
                return "LWin";
            case "RWIN":
                return "RWin";
            case "CTRL":
            case "CONTROL":
                return "Ctrl";
            case "LCTRL":
            case "LCTL":
            case "LCONTROL":
                return "LCtrl";
            case "RCTRL":
            case "RCTL":
            case "RCONTROL":
                return "RCtrl";
            case "OPTION":
            case "OPT":
            case "ALT":
            case "MENU":
                return "Option";
            case "LALT":
            case "LMENU":
                return "LAlt";
            case "RALT":
            case "RMENU":
                return "RAlt";
            case "SHIFT":
            case "LSHIFT":
            case "RSHIFT":
                return "Shift";
            case "FN":
            case "FUNCTION":
                return "Fn";
            case "APPS":
            case "APPLICATION":
            case "CONTEXTMENU":
                return "Apps";
            case "SPACE":
            case "SPACEBAR":
                return "Space";
            case "ESC":
            case "ESCAPE":
                return "Esc";
            case "ENTER":
            case "RETURN":
                return "Return";
            case "TAB":
                return "Tab";
            case "BACKSPACE":
            case "BKSP":
                return "Backspace";
            case "DELETE":
            case "DEL":
            case "FORWARDDELETE":
                return "Delete";
            case "INSERT":
            case "INS":
                return "Insert";
            case "CAPSLOCK":
                return "CapsLock";
            case "PAGEUP":
            case "PGUP":
            case "PRIOR":
                return "PageUp";
            case "PAGEDOWN":
            case "PGDN":
            case "NEXT":
                return "PageDown";
            case "HOME":
                return "Home";
            case "END":
                return "End";
            case "PRINTSCREEN":
            case "PRTSC":
            case "PRTSCN":
            case "SNAPSHOT":
                return "PrintScreen";
            case "SCROLLLOCK":
            case "SCROLL":
                return "ScrollLock";
            case "PAUSE":
            case "BREAK":
                return "Pause";
            case "LEFT":
            case "ARROWLEFT":
            case "LEFTARROW":
                return "Left";
            case "RIGHT":
            case "ARROWRIGHT":
            case "RIGHTARROW":
                return "Right";
            case "UP":
            case "ARROWUP":
            case "UPARROW":
                return "Up";
            case "DOWN":
            case "ARROWDOWN":
            case "DOWNARROW":
                return "Down";
            default:
                return trimmed;
        }
    }

    private static int SafeAdd(int left, int right)
    {
        if (right <= 0)
        {
            return left;
        }

        if (left > int.MaxValue - right)
        {
            return int.MaxValue;
        }

        return left + right;
    }

    private static void MergeAppStats(DailyStats daily, Dictionary<string, AppStats> totals)
    {
        if (daily.AppStats.Count == 0) return;

        foreach (var kvp in daily.AppStats)
        {
            var appName = kvp.Key;
            var source = kvp.Value;

            if (!totals.TryGetValue(appName, out var total))
            {
                total = new AppStats(appName, source.DisplayName);
                totals[appName] = total;
            }

            if (!string.IsNullOrEmpty(source.DisplayName))
            {
                total.DisplayName = source.DisplayName;
            }

            total.KeyPresses += source.KeyPresses;
            total.LeftClicks += source.LeftClicks;
            total.RightClicks += source.RightClicks;
            total.MiddleClicks += source.MiddleClicks;
            total.SideBackClicks += source.SideBackClicks;
            total.SideForwardClicks += source.SideForwardClicks;
            total.ScrollDistance += source.ScrollDistance;
        }
    }

    #endregion

    #region History

    public enum HistoryRange { Today, Yesterday, Week, Month }
    public enum HistoryMetric { KeyPresses, Clicks, MouseDistance, ScrollDistance }
    public enum KeyHistoryRange { Today, Week, Month, All }

    public List<(DateTime Date, double Value)> GetHistorySeries(HistoryRange range, HistoryMetric metric)
    {
        var dates = GetDatesInRange(range);
        lock (_lock)
        {
            return dates.Select(date =>
            {
                var key = date.ToString("yyyy-MM-dd");
                var stats = History.TryGetValue(key, out var s) ? s : new DailyStats(date);
                return (date, GetMetricValue(metric, stats));
            }).ToList();
        }
    }

    public string FormatHistoryValue(HistoryMetric metric, double value)
    {
        return metric switch
        {
            HistoryMetric.KeyPresses or HistoryMetric.Clicks => FormatNumber((int)value),
            HistoryMetric.MouseDistance => FormatMouseDistance(value),
            HistoryMetric.ScrollDistance => FormatScrollDistance(value),
            _ => value.ToString("N0")
        };
    }

    public List<(string Key, int Count)> GetHistoricalKeyCounts(KeyHistoryRange range, int limit = int.MaxValue)
    {
        lock (_lock)
        {
            var totals = new Dictionary<string, int>(StringComparer.Ordinal);
            var dates = GetDatesInKeyHistoryRange(range);

            foreach (var date in dates)
            {
                var daily = GetDailyStats(date);
                MergeKeyCounts(daily.KeyPressCounts, totals);
            }

            var sorted = totals
                .Where(x => x.Value > 0)
                .OrderByDescending(x => x.Value)
                .ThenBy(x => x.Key, StringComparer.OrdinalIgnoreCase)
                .Select(x => (x.Key, x.Value));

            if (limit > 0 && limit < int.MaxValue)
            {
                return sorted.Take(limit).ToList();
            }

            return sorted.ToList();
        }
    }

    private List<DateTime> GetDatesInRange(HistoryRange range)
    {
        var today = DateTime.Today;
        var startDate = range switch
        {
            HistoryRange.Today => today,
            HistoryRange.Yesterday => today.AddDays(-1),
            HistoryRange.Week => today.AddDays(-6),
            HistoryRange.Month => today.AddDays(-29),
            _ => today
        };

        var dates = new List<DateTime>();
        for (var date = startDate; date <= today; date = date.AddDays(1))
        {
            dates.Add(date);
        }
        return dates;
    }

    private List<DateTime> GetDatesInKeyHistoryRange(KeyHistoryRange range)
    {
        var today = DateTime.Today;
        if (range == KeyHistoryRange.All)
        {
            var dates = History.Values
                .Select(x => x.Date.Date)
                .Where(x => x <= today)
                .ToHashSet();
            dates.Add(today);
            return dates.OrderBy(x => x).ToList();
        }

        var startDate = range switch
        {
            KeyHistoryRange.Today => today,
            KeyHistoryRange.Week => today.AddDays(-6),
            KeyHistoryRange.Month => today.AddDays(-29),
            _ => today
        };

        var result = new List<DateTime>();
        for (var date = startDate.Date; date <= today; date = date.AddDays(1))
        {
            result.Add(date);
        }

        return result;
    }

    private double GetMetricValue(HistoryMetric metric, DailyStats stats)
    {
        return metric switch
        {
            HistoryMetric.KeyPresses => stats.KeyPresses,
            HistoryMetric.Clicks => stats.TotalClicks,
            HistoryMetric.MouseDistance => stats.MouseDistance,
            HistoryMetric.ScrollDistance => stats.ScrollDistance,
            _ => 0
        };
    }

    private static void MergeKeyCounts(Dictionary<string, int> source, Dictionary<string, int> target)
    {
        foreach (var kvp in source)
        {
            var key = (kvp.Key ?? string.Empty).Trim();
            if (string.IsNullOrWhiteSpace(key))
            {
                continue;
            }

            var count = Math.Max(0, kvp.Value);
            if (count <= 0)
            {
                continue;
            }

            target[key] = SafeAdd(target.TryGetValue(key, out var existing) ? existing : 0, count);
        }
    }

    public string FormatMouseDistance(double distance)
    {
        if (string.Equals(Settings.MouseDistanceUnit, "px", StringComparison.OrdinalIgnoreCase))
        {
            return $"{distance:F0} px";
        }

        var metersPerPixel = GetMetersPerPixel();
        if (metersPerPixel <= 0)
        {
            return $"{distance:F0} px";
        }

        var meters = distance * metersPerPixel;
        if (meters >= 1000)
            return $"{meters / 1000:F2} km";
        if (meters >= 1)
            return $"{meters:F1} m";
        return $"{meters * 100:F1} cm";
    }

    private string FormatScrollDistance(double distance)
    {
        if (distance >= 10000)
            return $"{distance / 1000:F1} k";
        return $"{distance:F0} px";
    }

    #endregion

    #region Mouse Calibration

    public void UpdateMouseCalibration(double metersPerPixel)
    {
        if (double.IsNaN(metersPerPixel) || double.IsInfinity(metersPerPixel) || metersPerPixel <= 0)
        {
            return;
        }

        lock (_lock)
        {
            Settings.MouseMetersPerPixel = metersPerPixel;
        }

        SaveSettings();
        NotifyStatsUpdate();
    }

    public void UpdateMouseDistanceUnit(string unit)
    {
        var normalized = string.Equals(unit, "px", StringComparison.OrdinalIgnoreCase) ? "px" : "auto";
        lock (_lock)
        {
            Settings.MouseDistanceUnit = normalized;
        }

        SaveSettings();
        NotifyStatsUpdate();
    }

    private double GetMetersPerPixel()
    {
        var metersPerPixel = Settings.MouseMetersPerPixel;
        if (double.IsNaN(metersPerPixel) || double.IsInfinity(metersPerPixel) || metersPerPixel <= 0)
        {
            return DefaultMetersPerPixel;
        }
        return metersPerPixel;
    }

    #endregion

    public void FlushPendingSave()
    {
        _saveTimer?.Stop();
        _statsUpdateTimer?.Stop();
        _mouseMoveUpdateTimer?.Stop();
        _midnightTimer?.Stop();
        _settingsSaveTimer?.Stop();

        lock (_lock)
        {
            _pendingSave = false;
            _pendingSettingsSave = false;
        }

        SaveStats();
        SaveHistory();
        FlushSettings();
    }

    public void Dispose()
    {
        FlushPendingSave();
        _saveTimer?.Dispose();
        _statsUpdateTimer?.Dispose();
        _mouseMoveUpdateTimer?.Dispose();
        _midnightTimer?.Dispose();
        _settingsSaveTimer?.Dispose();
        _instance = null;
    }
}
