using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using KeyStats.Helpers;
using KeyStats.Models;
using KeyStats.Services;
using KeyStats.Views;

namespace KeyStats.ViewModels;

public class KeyCountItem
{
    public string Key { get; set; } = "";
    public string Count { get; set; } = "";
}

public class AppStatsItem
{
    public string Name { get; set; } = "";
    public string KeyPresses { get; set; } = "0";
    public string Clicks { get; set; } = "0";
    public ImageSource? Icon { get; set; }
    public bool HasIcon => Icon != null;
}

public class ChartDataPoint
{
    public DateTime Date { get; set; }
    public double Value { get; set; }
}

public class StatsPopupViewModel : ViewModelBase
{
    private string _keyPresses = "0";
    private string _totalClicks = "0";
    private string _leftClicks = "0";
    private string _rightClicks = "0";
    private string _middleClicks = "0";
    private string _sideBackClicks = "0";
    private string _sideForwardClicks = "0";
    private bool _isSideClickRowVisible;
    private string _mouseDistance = "0 px";
    private string _scrollDistance = "0 px";
    private string _peakKPS = "0";
    private string _peakCPS = "0";
    private bool _isPeakPopupOpen;
    private int _selectedRangeIndex;
    private int _selectedMetricIndex;
    private int _selectedChartStyleIndex;
    private string _historySummary = "总计: 0";
    private ObservableCollection<ChartDataPoint> _chartData = new();

    public string KeyPresses
    {
        get => _keyPresses;
        set => SetProperty(ref _keyPresses, value);
    }

    public string TotalClicks
    {
        get => _totalClicks;
        set => SetProperty(ref _totalClicks, value);
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

    public string MiddleClicks
    {
        get => _middleClicks;
        set => SetProperty(ref _middleClicks, value);
    }

    public string SideBackClicks
    {
        get => _sideBackClicks;
        set => SetProperty(ref _sideBackClicks, value);
    }

    public string SideForwardClicks
    {
        get => _sideForwardClicks;
        set => SetProperty(ref _sideForwardClicks, value);
    }

    public bool IsSideClickRowVisible
    {
        get => _isSideClickRowVisible;
        set => SetProperty(ref _isSideClickRowVisible, value);
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

    public string PeakKPS
    {
        get => _peakKPS;
        set => SetProperty(ref _peakKPS, value);
    }

    public string PeakCPS
    {
        get => _peakCPS;
        set => SetProperty(ref _peakCPS, value);
    }

    public bool IsPeakPopupOpen
    {
        get => _isPeakPopupOpen;
        set => SetProperty(ref _isPeakPopupOpen, value);
    }

    public int SelectedRangeIndex
    {
        get => _selectedRangeIndex;
        set
        {
            if (SetProperty(ref _selectedRangeIndex, value))
            {
                App.CurrentApp?.TrackClick("chart_range", new Dictionary<string, object?>
                {
                    ["range"] = value == 0 ? "7d" : "30d"
                });
                UpdateHistorySection();
            }
        }
    }

    public int SelectedMetricIndex
    {
        get => _selectedMetricIndex;
        set
        {
            if (SetProperty(ref _selectedMetricIndex, value))
            {
                App.CurrentApp?.TrackClick("chart_metric", new Dictionary<string, object?>
                {
                    ["metric"] = value switch
                    {
                        0 => "clicks",
                        1 => "key_presses",
                        2 => "mouse_distance",
                        3 => "scroll_distance",
                        _ => "unknown"
                    }
                });
                UpdateHistorySection();
            }
        }
    }

    public int SelectedChartStyleIndex
    {
        get => _selectedChartStyleIndex;
        set
        {
            if (SetProperty(ref _selectedChartStyleIndex, value))
            {
                App.CurrentApp?.TrackClick("chart_style", new Dictionary<string, object?>
                {
                    ["style"] = value == 0 ? "line" : "bar"
                });
                UpdateHistorySection();
            }
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
    
    public ObservableCollection<AppStatsItem> AppStatsItems { get; } = new();

    public ObservableCollection<ChartDataPoint> ChartData
    {
        get => _chartData;
        set => SetProperty(ref _chartData, value);
    }

    public ICommand QuitCommand { get; }

    public StatsPopupViewModel()
    {
        QuitCommand = new RelayCommand(Quit);

        UpdateStats();
        UpdateKeyBreakdown();
        UpdateAppStats();
        UpdateHistorySection();

        StatsManager.Instance.StatsChanged += OnStatsChanged;
    }

    private void OnStatsChanged(StatsManager.StatsUpdateKind updateKind)
    {
        Application.Current?.Dispatcher.Invoke(() =>
        {
            if (updateKind == StatsManager.StatsUpdateKind.MouseDistanceOnly)
            {
                UpdateStats();
                return;
            }

            RefreshAllSections();
        });
    }

    private void RefreshAllSections()
    {
        UpdateStats();
        UpdateKeyBreakdown();
        UpdateAppStats();
        UpdateHistorySection();
    }

    private void UpdateStats()
    {
        var stats = StatsManager.Instance.CurrentStats;
        var manager = StatsManager.Instance;

        KeyPresses = stats.KeyPresses.ToString("N0");
        TotalClicks = stats.TotalClicks.ToString("N0");
        LeftClicks = stats.LeftClicks.ToString("N0");
        RightClicks = stats.RightClicks.ToString("N0");
        MiddleClicks = stats.MiddleClicks.ToString("N0");
        SideBackClicks = stats.SideBackClicks.ToString("N0");
        SideForwardClicks = stats.SideForwardClicks.ToString("N0");
        IsSideClickRowVisible = (stats.SideBackClicks + stats.SideForwardClicks) > 0;
        MouseDistance = manager.FormatMouseDistance(stats.MouseDistance);
        ScrollDistance = stats.FormattedScrollDistance;
        PeakKPS = stats.PeakKPS > 0
            ? Math.Round(stats.PeakKPS, MidpointRounding.AwayFromZero).ToString("N0")
            : "0";
        PeakCPS = stats.PeakCPS > 0
            ? Math.Round(stats.PeakCPS, MidpointRounding.AwayFromZero).ToString("N0")
            : "0";
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

    private void UpdateAppStats()
    {
        var manager = StatsManager.Instance;
        var sortedApps = manager.GetAppStatsSorted(int.MaxValue);

        AppStatsItems.Clear();

        foreach (var app in sortedApps)
        {
            AppStatsItems.Add(new AppStatsItem
            {
                Name = app.DisplayName,
                KeyPresses = manager.FormatNumber(app.KeyPresses),
                Clicks = manager.FormatNumber(app.TotalClicks),
                Icon = AppIconHelper.GetAppIcon(app.AppName)
            });
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
            0 => StatsManager.HistoryMetric.Clicks,
            1 => StatsManager.HistoryMetric.KeyPresses,
            2 => StatsManager.HistoryMetric.MouseDistance,
            3 => StatsManager.HistoryMetric.ScrollDistance,
            _ => StatsManager.HistoryMetric.Clicks
        };

        var series = StatsManager.Instance.GetHistorySeries(range, metric);

        ChartData = new ObservableCollection<ChartDataPoint>(
            series.Select(point => new ChartDataPoint { Date = point.Date, Value = point.Value }));

        var total = series.Sum(x => x.Value);
        var formatted = StatsManager.Instance.FormatHistoryValue(metric, total);
        HistorySummary = $"总计: {formatted}";
    }

    private void Quit()
    {
        App.CurrentApp?.TrackClick("popup_quit");
        StatsManager.Instance.FlushPendingSave();
        InputMonitorService.Instance.StopMonitoring();
        Application.Current.Shutdown();
    }

    public void Cleanup()
    {
        StatsManager.Instance.StatsChanged -= OnStatsChanged;
    }
}
