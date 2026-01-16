using System.Text.Json;
using System.Timers;
using KeyStats.Helpers;
using KeyStats.Models;
using Timer = System.Timers.Timer;
using Color = System.Drawing.Color;

namespace KeyStats.Services;

public class StatsManager : IDisposable
{
    private static StatsManager? _instance;
    public static StatsManager Instance => _instance ??= new StatsManager();

    private const double MetersPerPixel = 0.000264583;

    private readonly string _dataFolder;
    private readonly string _statsFilePath;
    private readonly string _historyFilePath;
    private readonly string _settingsFilePath;

    private readonly object _lock = new();
    private Timer? _saveTimer;
    private Timer? _midnightTimer;
    private Timer? _inputRateTimer;
    private Timer? _statsUpdateTimer;

    private readonly double _saveInterval = 2000; // 2 seconds
    private readonly double _statsUpdateDebounceInterval = 300; // 0.3 seconds
    private readonly double _inputRateWindowSeconds = 3.0;
    private readonly double _inputRateBucketInterval = 500; // 0.5 seconds
    private readonly double[] _inputRateApmThresholds = { 0, 80, 160, 240 };

    private int[] _inputRateBuckets;
    private int _inputRateBucketIndex;
    private bool _pendingSave;
    private bool _pendingStatsUpdate;

    private int _lastNotifiedKeyPresses;
    private int _lastNotifiedClicks;

    public DailyStats CurrentStats { get; private set; }
    public AppSettings Settings { get; private set; }
    public Dictionary<string, DailyStats> History { get; private set; } = new();

    public double CurrentInputRatePerSecond { get; private set; }
    public Color? CurrentIconTintColor { get; private set; }

    public event Action? TrayUpdateRequested;
    public event Action? StatsUpdateRequested;

    private StatsManager()
    {
        _dataFolder = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "KeyStats");
        Directory.CreateDirectory(_dataFolder);

        _statsFilePath = Path.Combine(_dataFolder, "daily_stats.json");
        _historyFilePath = Path.Combine(_dataFolder, "history.json");
        _settingsFilePath = Path.Combine(_dataFolder, "settings.json");

        var bucketCount = Math.Max(1, (int)(_inputRateWindowSeconds / (_inputRateBucketInterval / 1000.0)));
        _inputRateBuckets = new int[bucketCount];

        Settings = LoadSettings();
        History = LoadHistory();
        CurrentStats = LoadStats() ?? new DailyStats();

        // Check if stats are from today
        if (CurrentStats.Date.Date != DateTime.Today)
        {
            CurrentStats = new DailyStats();
        }

        UpdateNotificationBaselines();
        SaveStats();

        if (Settings.EnableDynamicIconColor)
        {
            ResetInputRateBuckets();
            StartInputRateTracking();
            UpdateCurrentInputRate();
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
        monitor.MouseMoved += OnMouseMoved;
        monitor.MouseScrolled += OnMouseScrolled;
    }

    private void OnKeyPressed(string keyName)
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
        }

        RegisterInputEvent();
        NotifyTrayUpdate();
        NotifyStatsUpdate();
        NotifyKeyPressThresholdIfNeeded();
    }

    private void OnLeftClick()
    {
        lock (_lock)
        {
            EnsureCurrentDay();
            CurrentStats.LeftClicks++;
        }

        RegisterInputEvent();
        NotifyTrayUpdate();
        NotifyStatsUpdate();
        NotifyClickThresholdIfNeeded();
    }

    private void OnRightClick()
    {
        lock (_lock)
        {
            EnsureCurrentDay();
            CurrentStats.RightClicks++;
        }

        RegisterInputEvent();
        NotifyTrayUpdate();
        NotifyStatsUpdate();
        NotifyClickThresholdIfNeeded();
    }

    private void OnMouseMoved(double distance)
    {
        lock (_lock)
        {
            EnsureCurrentDay();
            CurrentStats.MouseDistance += distance;
        }

        ScheduleDebouncedStatsUpdate();
        ScheduleSave();
    }

    private void OnMouseScrolled(double distance)
    {
        lock (_lock)
        {
            EnsureCurrentDay();
            CurrentStats.ScrollDistance += Math.Abs(distance);
        }

        ScheduleDebouncedStatsUpdate();
        ScheduleSave();
    }

    private void RegisterInputEvent()
    {
        if (!Settings.EnableDynamicIconColor) return;

        lock (_lock)
        {
            _inputRateBuckets[_inputRateBucketIndex]++;
        }

        ScheduleSave();
    }

    private void ResetInputRateBuckets()
    {
        lock (_lock)
        {
            _inputRateBuckets = new int[_inputRateBuckets.Length];
            _inputRateBucketIndex = 0;
        }
    }

    private void StartInputRateTracking()
    {
        _inputRateTimer?.Stop();
        _inputRateTimer = new Timer(_inputRateBucketInterval);
        _inputRateTimer.Elapsed += (_, _) => AdvanceInputRateBucket();
        _inputRateTimer.Start();
    }

    private void StopInputRateTracking()
    {
        _inputRateTimer?.Stop();
        _inputRateTimer?.Dispose();
        _inputRateTimer = null;
    }

    private void AdvanceInputRateBucket()
    {
        lock (_lock)
        {
            _inputRateBucketIndex = (_inputRateBucketIndex + 1) % _inputRateBuckets.Length;
            _inputRateBuckets[_inputRateBucketIndex] = 0;
        }

        UpdateCurrentInputRate();
    }

    private void UpdateCurrentInputRate()
    {
        int totalEvents;
        lock (_lock)
        {
            totalEvents = _inputRateBuckets.Sum();
        }

        CurrentInputRatePerSecond = totalEvents / _inputRateWindowSeconds;
        CurrentIconTintColor = Settings.EnableDynamicIconColor
            ? IconGenerator.GetRateColor(CurrentInputRatePerSecond)
            : null;

        if (CurrentIconTintColor == Color.Empty)
        {
            CurrentIconTintColor = null;
        }

        NotifyTrayUpdate();
    }

    public void SetEnableDynamicIconColor(bool enabled)
    {
        Settings.EnableDynamicIconColor = enabled;
        SaveSettings();

        if (enabled)
        {
            ResetInputRateBuckets();
            StartInputRateTracking();
            UpdateCurrentInputRate();
        }
        else
        {
            StopInputRateTracking();
            CurrentIconTintColor = null;
            NotifyTrayUpdate();
        }
    }

    private void EnsureCurrentDay()
    {
        if (CurrentStats.Date.Date != DateTime.Today)
        {
            ResetStats(DateTime.Today);
        }
    }

    private void ScheduleSave()
    {
        if (_pendingSave) return;
        _pendingSave = true;

        _saveTimer?.Stop();
        _saveTimer = new Timer(_saveInterval);
        _saveTimer.Elapsed += (_, _) =>
        {
            _saveTimer?.Stop();
            _pendingSave = false;
            SaveStats();
            SaveHistory();
        };
        _saveTimer.Start();
    }

    private void ScheduleDebouncedStatsUpdate()
    {
        if (_pendingStatsUpdate) return;
        _pendingStatsUpdate = true;

        _statsUpdateTimer?.Stop();
        _statsUpdateTimer = new Timer(_statsUpdateDebounceInterval);
        _statsUpdateTimer.Elapsed += (_, _) =>
        {
            _statsUpdateTimer?.Stop();
            _pendingStatsUpdate = false;
            NotifyStatsUpdate();
        };
        _statsUpdateTimer.Start();
    }

    private void NotifyTrayUpdate()
    {
        TrayUpdateRequested?.Invoke();
    }

    private void NotifyStatsUpdate()
    {
        StatsUpdateRequested?.Invoke();
    }

    #region Persistence

    private void SaveStats()
    {
        lock (_lock)
        {
            try
            {
                var json = JsonSerializer.Serialize(CurrentStats, new JsonSerializerOptions { WriteIndented = true });
                var tempPath = _statsFilePath + ".tmp";
                File.WriteAllText(tempPath, json);
                File.Move(tempPath, _statsFilePath, true);
            }
            catch (Exception ex)
            {
                System.Diagnostics.Debug.WriteLine($"Error saving stats: {ex.Message}");
            }

            RecordCurrentStatsToHistory();
        }
    }

    private DailyStats? LoadStats()
    {
        try
        {
            if (File.Exists(_statsFilePath))
            {
                var json = File.ReadAllText(_statsFilePath);
                return JsonSerializer.Deserialize<DailyStats>(json);
            }
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"Error loading stats: {ex.Message}");
        }
        return null;
    }

    private void RecordCurrentStatsToHistory()
    {
        var key = CurrentStats.Date.ToString("yyyy-MM-dd");
        History[key] = CurrentStats;
        SaveHistory();
    }

    private void SaveHistory()
    {
        try
        {
            var json = JsonSerializer.Serialize(History, new JsonSerializerOptions { WriteIndented = true });
            var tempPath = _historyFilePath + ".tmp";
            File.WriteAllText(tempPath, json);
            File.Move(tempPath, _historyFilePath, true);
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"Error saving history: {ex.Message}");
        }
    }

    private Dictionary<string, DailyStats> LoadHistory()
    {
        try
        {
            if (File.Exists(_historyFilePath))
            {
                var json = File.ReadAllText(_historyFilePath);
                return JsonSerializer.Deserialize<Dictionary<string, DailyStats>>(json) ?? new();
            }
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"Error loading history: {ex.Message}");
        }
        return new();
    }

    public void SaveSettings()
    {
        try
        {
            var json = JsonSerializer.Serialize(Settings, new JsonSerializerOptions { WriteIndented = true });
            var tempPath = _settingsFilePath + ".tmp";
            File.WriteAllText(tempPath, json);
            File.Move(tempPath, _settingsFilePath, true);
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"Error saving settings: {ex.Message}");
        }
    }

    private AppSettings LoadSettings()
    {
        try
        {
            if (File.Exists(_settingsFilePath))
            {
                var json = File.ReadAllText(_settingsFilePath);
                return JsonSerializer.Deserialize<AppSettings>(json) ?? new AppSettings();
            }
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"Error loading settings: {ex.Message}");
        }
        return new AppSettings();
    }

    #endregion

    #region Midnight Reset

    private void SetupMidnightReset()
    {
        ScheduleNextMidnightReset();
    }

    private void ScheduleNextMidnightReset()
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

    private void PerformMidnightReset()
    {
        var now = DateTime.Now;
        if (CurrentStats.Date.Date != now.Date)
        {
            ResetStats(now);
        }
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
            CurrentStats = new DailyStats(date);
        }

        UpdateNotificationBaselines();
        NotifyTrayUpdate();
        NotifyStatsUpdate();
        SaveStats();
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
        if (count % threshold != 0) return;
        if (count == _lastNotifiedKeyPresses) return;
        _lastNotifiedKeyPresses = count;
        NotificationService.Instance.SendThresholdNotification(NotificationService.Metric.KeyPresses, count);
    }

    private void NotifyClickThresholdIfNeeded()
    {
        if (!Settings.NotificationsEnabled) return;
        var threshold = Settings.ClickNotifyThreshold;
        if (threshold <= 0) return;
        var count = CurrentStats.TotalClicks;
        if (count % threshold != 0) return;
        if (count == _lastNotifiedClicks) return;
        _lastNotifiedClicks = count;
        NotificationService.Instance.SendThresholdNotification(NotificationService.Metric.Clicks, count);
    }

    #endregion

    #region Formatting

    public (string Keys, string Clicks) GetTrayTextParts()
    {
        var keys = Settings.ShowKeyPressesInTray ? FormatMenuBarNumber(CurrentStats.KeyPresses) : "";
        var clicks = Settings.ShowMouseClicksInTray ? FormatMenuBarNumber(CurrentStats.TotalClicks) : "";
        return (keys, clicks);
    }

    public string GetTooltipText()
    {
        return $"Keys: {CurrentStats.KeyPresses:N0} | Clicks: {CurrentStats.TotalClicks:N0}";
    }

    private string FormatMenuBarNumber(int number)
    {
        if (number >= 1_000_000)
            return $"{number / 1_000_000.0:F2}M";
        if (number >= 1_000)
            return $"{number / 1_000.0:F2}k";
        return number.ToString();
    }

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

    #endregion

    #region History

    public enum HistoryRange { Today, Yesterday, Week, Month }
    public enum HistoryMetric { KeyPresses, Clicks, MouseDistance, ScrollDistance }

    public List<(DateTime Date, double Value)> GetHistorySeries(HistoryRange range, HistoryMetric metric)
    {
        var dates = GetDatesInRange(range);
        return dates.Select(date =>
        {
            var key = date.ToString("yyyy-MM-dd");
            var stats = History.TryGetValue(key, out var s) ? s : new DailyStats(date);
            return (date, GetMetricValue(metric, stats));
        }).ToList();
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

    private string FormatMouseDistance(double distance)
    {
        var meters = distance * MetersPerPixel;
        if (meters >= 1000)
            return $"{meters / 1000:F2} km";
        if (distance >= 1000)
            return $"{meters:F1} m";
        return $"{distance:F0} px";
    }

    private string FormatScrollDistance(double distance)
    {
        if (distance >= 10000)
            return $"{distance / 1000:F1} k";
        return $"{distance:F0} px";
    }

    #endregion

    public void FlushPendingSave()
    {
        _saveTimer?.Stop();
        _statsUpdateTimer?.Stop();
        _midnightTimer?.Stop();
        _inputRateTimer?.Stop();
        SaveStats();
        SaveHistory();
        SaveSettings();
    }

    public void Dispose()
    {
        FlushPendingSave();
        _saveTimer?.Dispose();
        _statsUpdateTimer?.Dispose();
        _midnightTimer?.Dispose();
        _inputRateTimer?.Dispose();
        _instance = null;
    }
}
