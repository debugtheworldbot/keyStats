using System.Collections.ObjectModel;
using System.Windows;
using System.Windows.Input;
using KeyStats.Services;
using KeyStats.Views;

namespace KeyStats.ViewModels;

public class KeyCountItem
{
    public string Key { get; set; } = "";
    public string Count { get; set; } = "";
}

public class ChartDataPoint
{
    public DateTime Date { get; set; }
    public double Value { get; set; }
}

public class StatsPopupViewModel : ViewModelBase
{
    private string _keyPresses = "0";
    private string _leftClicks = "0";
    private string _rightClicks = "0";
    private string _mouseDistance = "0 px";
    private string _scrollDistance = "0 px";
    private int _selectedRangeIndex;
    private int _selectedMetricIndex;
    private int _selectedChartStyleIndex;
    private string _historySummary = "总计: 0";

    public string KeyPresses
    {
        get => _keyPresses;
        set => SetProperty(ref _keyPresses, value);
    }

    public string LeftClicks
    {
        get => _leftClicks;
        set => SetProperty(ref _leftClicks, value);
    }

    public string RightClicks
    {
        get => _rightClicks;
        set => SetProperty(ref _rightClicks, value);
    }

    public string MouseDistance
    {
        get => _mouseDistance;
        set => SetProperty(ref _mouseDistance, value);
    }

    public string ScrollDistance
    {
        get => _scrollDistance;
        set => SetProperty(ref _scrollDistance, value);
    }

    public int SelectedRangeIndex
    {
        get => _selectedRangeIndex;
        set
        {
            if (SetProperty(ref _selectedRangeIndex, value))
                UpdateHistorySection();
        }
    }

    public int SelectedMetricIndex
    {
        get => _selectedMetricIndex;
        set
        {
            if (SetProperty(ref _selectedMetricIndex, value))
                UpdateHistorySection();
        }
    }

    public int SelectedChartStyleIndex
    {
        get => _selectedChartStyleIndex;
        set
        {
            if (SetProperty(ref _selectedChartStyleIndex, value))
                UpdateHistorySection();
        }
    }

    public string HistorySummary
    {
        get => _historySummary;
        set => SetProperty(ref _historySummary, value);
    }

    public ObservableCollection<KeyCountItem> Column1Items { get; } = new();
    public ObservableCollection<KeyCountItem> Column2Items { get; } = new();
    public ObservableCollection<KeyCountItem> Column3Items { get; } = new();

    public ObservableCollection<ChartDataPoint> ChartData { get; } = new();

    public ICommand OpenSettingsCommand { get; }
    public ICommand QuitCommand { get; }

    public event Action? RequestClose;

    private SettingsWindow? _settingsWindow;

    public StatsPopupViewModel()
    {
        OpenSettingsCommand = new RelayCommand(OpenSettings);
        QuitCommand = new RelayCommand(Quit);

        UpdateStats();
        UpdateKeyBreakdown();
        UpdateHistorySection();

        StatsManager.Instance.StatsUpdateRequested += OnStatsUpdateRequested;
    }

    private void OnStatsUpdateRequested()
    {
        Application.Current?.Dispatcher.Invoke(() =>
        {
            UpdateStats();
            UpdateKeyBreakdown();
            UpdateHistorySection();
        });
    }

    private void UpdateStats()
    {
        var stats = StatsManager.Instance.CurrentStats;
        var manager = StatsManager.Instance;

        KeyPresses = stats.KeyPresses.ToString("N0");
        LeftClicks = stats.LeftClicks.ToString("N0");
        RightClicks = stats.RightClicks.ToString("N0");
        MouseDistance = stats.FormattedMouseDistance;
        ScrollDistance = stats.FormattedScrollDistance;
    }

    private void UpdateKeyBreakdown()
    {
        var items = StatsManager.Instance.GetKeyPressBreakdownSorted();
        var manager = StatsManager.Instance;

        Column1Items.Clear();
        Column2Items.Clear();
        Column3Items.Clear();

        var limitedItems = items.Take(15).ToList();

        for (int i = 0; i < limitedItems.Count; i++)
        {
            var item = new KeyCountItem
            {
                Key = limitedItems[i].Key,
                Count = manager.FormatNumber(limitedItems[i].Count)
            };

            var columnIndex = i / 5;
            switch (columnIndex)
            {
                case 0:
                    Column1Items.Add(item);
                    break;
                case 1:
                    Column2Items.Add(item);
                    break;
                case 2:
                    Column3Items.Add(item);
                    break;
            }
        }
    }

    private void UpdateHistorySection()
    {
        var range = SelectedRangeIndex switch
        {
            0 => StatsManager.HistoryRange.Week,
            1 => StatsManager.HistoryRange.Month,
            _ => StatsManager.HistoryRange.Week
        };

        var metric = SelectedMetricIndex switch
        {
            0 => StatsManager.HistoryMetric.KeyPresses,
            1 => StatsManager.HistoryMetric.Clicks,
            2 => StatsManager.HistoryMetric.MouseDistance,
            3 => StatsManager.HistoryMetric.ScrollDistance,
            _ => StatsManager.HistoryMetric.KeyPresses
        };

        var series = StatsManager.Instance.GetHistorySeries(range, metric);

        ChartData.Clear();
        foreach (var point in series)
        {
            ChartData.Add(new ChartDataPoint { Date = point.Date, Value = point.Value });
        }

        var total = series.Sum(x => x.Value);
        var formatted = StatsManager.Instance.FormatHistoryValue(metric, total);
        HistorySummary = $"总计: {formatted}";

        OnPropertyChanged(nameof(ChartData));
    }

    private void OpenSettings()
    {
        if (_settingsWindow != null)
        {
            _settingsWindow.Activate();
            return;
        }

        _settingsWindow = new SettingsWindow();
        _settingsWindow.Closed += (_, _) => _settingsWindow = null;
        _settingsWindow.Show();
        RequestClose?.Invoke();
    }

    private void Quit()
    {
        StatsManager.Instance.FlushPendingSave();
        InputMonitorService.Instance.StopMonitoring();
        Application.Current.Shutdown();
    }

    public void Cleanup()
    {
        StatsManager.Instance.StatsUpdateRequested -= OnStatsUpdateRequested;
    }
}
