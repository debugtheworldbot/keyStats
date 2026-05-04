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

namespace KeyStats.ViewModels;

public class AppStatsRowItem
{
    public string AppName { get; set; } = "";
    public string DisplayName { get; set; } = "";
    public ImageSource? Icon { get; set; }
    public bool HasIcon => Icon != null;

    public string KeysText { get; set; } = "0";
    public string ClicksText { get; set; } = "0";
    public string ScrollText { get; set; } = "0";

    public double KeysRatio { get; set; }
    public double ClicksRatio { get; set; }
    public double ScrollRatio { get; set; }

    public bool KeysLabelInside { get; set; }
    public bool ClicksLabelInside { get; set; }
    public bool ScrollLabelInside { get; set; }
    public bool KeysLabelOutside => !KeysLabelInside;
    public bool ClicksLabelOutside => !ClicksLabelInside;
    public bool ScrollLabelOutside => !ScrollLabelInside;
}

public class AppStatsViewModel : ViewModelBase
{
    private const double LabelInsideThreshold = 0.45;

    private int _selectedRangeIndex;
    private SortMetric _sortMetric = SortMetric.Keys;
    private string _summaryText = "";
    private bool _hasData;
    private bool _isEmpty = true;
    private string _emptyText = KeyStats.Properties.Strings.AppStats_Empty;
    private string _keysHeader = KeyStats.Properties.Strings.AppStats_ColumnKeys;
    private string _clicksHeader = KeyStats.Properties.Strings.AppStats_ColumnClicks;
    private string _scrollHeader = KeyStats.Properties.Strings.AppStats_ColumnScroll;

    public ObservableCollection<AppStatsRowItem> AppStatsItems { get; } = new();

    public ICommand SortCommand { get; }

    public int SelectedRangeIndex
    {
        get => _selectedRangeIndex;
        set
        {
            if (SetProperty(ref _selectedRangeIndex, value))
            {
                RefreshData();
            }
        }
    }

    public string SummaryText
    {
        get => _summaryText;
        set => SetProperty(ref _summaryText, value);
    }

    public bool HasData
    {
        get => _hasData;
        set => SetProperty(ref _hasData, value);
    }

    public bool IsEmpty
    {
        get => _isEmpty;
        set => SetProperty(ref _isEmpty, value);
    }

    public string EmptyText
    {
        get => _emptyText;
        set => SetProperty(ref _emptyText, value);
    }

    public string KeysHeader
    {
        get => _keysHeader;
        set => SetProperty(ref _keysHeader, value);
    }

    public string ClicksHeader
    {
        get => _clicksHeader;
        set => SetProperty(ref _clicksHeader, value);
    }

    public string ScrollHeader
    {
        get => _scrollHeader;
        set => SetProperty(ref _scrollHeader, value);
    }

    public AppStatsViewModel()
    {
        SortCommand = new RelayCommand(OnSortRequested);
        RefreshHeaders();
        RefreshData();
        StatsManager.Instance.StatsUpdateRequested += OnStatsUpdateRequested;
    }

    public void Cleanup()
    {
        StatsManager.Instance.StatsUpdateRequested -= OnStatsUpdateRequested;
    }

    private void OnStatsUpdateRequested()
    {
        Application.Current?.Dispatcher.Invoke(RefreshData);
    }

    private void OnSortRequested(object? parameter)
    {
        if (parameter is not string metric) return;
        _sortMetric = metric switch
        {
            "Clicks" => SortMetric.Clicks,
            "Scroll" => SortMetric.Scroll,
            _ => SortMetric.Keys
        };
        RefreshHeaders();
        RefreshData();
    }

    private void RefreshHeaders()
    {
        KeysHeader = BuildHeader(KeyStats.Properties.Strings.AppStats_ColumnKeys, SortMetric.Keys);
        ClicksHeader = BuildHeader(KeyStats.Properties.Strings.AppStats_ColumnClicks, SortMetric.Clicks);
        ScrollHeader = BuildHeader(KeyStats.Properties.Strings.AppStats_ColumnScroll, SortMetric.Scroll);
    }

    private const string SortIndicator = "↓"; // ↓ — direction-only glyph, not localized

    private string BuildHeader(string baseText, SortMetric metric)
    {
        return _sortMetric == metric ? $"{baseText} {SortIndicator}" : baseText;
    }

    private void RefreshData()
    {
        var manager = StatsManager.Instance;
        var range = SelectedRangeIndex switch
        {
            0 => StatsManager.AppStatsRange.Today,
            1 => StatsManager.AppStatsRange.Week,
            2 => StatsManager.AppStatsRange.Month,
            3 => StatsManager.AppStatsRange.All,
            _ => StatsManager.AppStatsRange.Today
        };

        var items = manager.GetAppStatsSummary(range)
            .Where(a => a.HasActivity)
            .ToList();

        items.Sort((lhs, rhs) =>
        {
            var lhsValue = SortValue(lhs);
            var rhsValue = SortValue(rhs);
            if (lhsValue != rhsValue)
            {
                return rhsValue.CompareTo(lhsValue);
            }
            return string.Compare(DisplayName(lhs), DisplayName(rhs), StringComparison.OrdinalIgnoreCase);
        });

        var maxKeys = Math.Max(1, items.Select(a => a.KeyPresses).DefaultIfEmpty(0).Max());
        var maxClicks = Math.Max(1, items.Select(a => a.TotalClicks).DefaultIfEmpty(0).Max());
        var maxScroll = Math.Max(1.0, items.Select(a => a.ScrollDistance).DefaultIfEmpty(0).Max());

        AppStatsItems.Clear();

        foreach (var app in items)
        {
            var keysRatio = app.KeyPresses / (double)maxKeys;
            var clicksRatio = app.TotalClicks / (double)maxClicks;
            var scrollRatio = app.ScrollDistance / maxScroll;
            var displayName = DisplayName(app);

            AppStatsItems.Add(new AppStatsRowItem
            {
                AppName = app.AppName,
                DisplayName = displayName,
                Icon = AppIconHelper.GetAppIcon(app.AppName, displayName),
                KeysText = manager.FormatHistoryValue(StatsManager.HistoryMetric.KeyPresses, app.KeyPresses),
                ClicksText = manager.FormatHistoryValue(StatsManager.HistoryMetric.Clicks, app.TotalClicks),
                ScrollText = manager.FormatHistoryValue(StatsManager.HistoryMetric.ScrollDistance, app.ScrollDistance),
                KeysRatio = keysRatio,
                ClicksRatio = clicksRatio,
                ScrollRatio = scrollRatio,
                KeysLabelInside = keysRatio >= LabelInsideThreshold,
                ClicksLabelInside = clicksRatio >= LabelInsideThreshold,
                ScrollLabelInside = scrollRatio >= LabelInsideThreshold
            });
        }

        var totalKeys = items.Sum(a => a.KeyPresses);
        var totalClicks = items.Sum(a => a.TotalClicks);
        var totalScroll = items.Sum(a => a.ScrollDistance);

        SummaryText = items.Count == 0
            ? ""
            : string.Format(
                KeyStats.Properties.Strings.AppStats_SummaryFormat,
                manager.FormatHistoryValue(StatsManager.HistoryMetric.KeyPresses, totalKeys),
                manager.FormatHistoryValue(StatsManager.HistoryMetric.Clicks, totalClicks),
                manager.FormatHistoryValue(StatsManager.HistoryMetric.ScrollDistance, totalScroll));

        IsEmpty = AppStatsItems.Count == 0;
        HasData = !IsEmpty;
    }

    private string DisplayName(AppStats stats)
    {
        if (!string.IsNullOrWhiteSpace(stats.DisplayName))
        {
            return stats.DisplayName;
        }
        if (!string.IsNullOrWhiteSpace(stats.AppName))
        {
            return stats.AppName;
        }
        return KeyStats.Properties.Strings.AppStats_UnknownApp;
    }

    private double SortValue(AppStats stats)
    {
        return _sortMetric switch
        {
            SortMetric.Keys => stats.KeyPresses,
            SortMetric.Clicks => stats.TotalClicks,
            SortMetric.Scroll => stats.ScrollDistance,
            _ => stats.KeyPresses
        };
    }

    private enum SortMetric
    {
        Keys,
        Clicks,
        Scroll
    }
}
