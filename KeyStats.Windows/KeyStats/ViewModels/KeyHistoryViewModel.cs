using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;
using System.Windows;
using System.Windows.Media;
using KeyStats.Services;

namespace KeyStats.ViewModels;

public class KeyHistoryChartItem
{
    public string Key { get; set; } = string.Empty;
    public int Count { get; set; }
    public string CountText { get; set; } = "0";
    public string PercentageText { get; set; } = "0%";
    public double Ratio { get; set; }
    public double StartAngle { get; set; }
    public double SweepAngle { get; set; }
    public Brush Brush { get; set; } = Brushes.Gray;
}

public class KeyHistoryViewModel : ViewModelBase
{
    private const int DefaultRangeIndex = 1;

    private static readonly Color[] Palette =
    {
        Color.FromRgb(0x00, 0x78, 0xD4),
        Color.FromRgb(0x2D, 0x7D, 0x46),
        Color.FromRgb(0xD1, 0x78, 0x00),
        Color.FromRgb(0x8A, 0x5C, 0xC2),
        Color.FromRgb(0xC2, 0x39, 0xB3),
        Color.FromRgb(0xD1, 0x34, 0x38),
        Color.FromRgb(0x2B, 0xA0, 0xA0),
        Color.FromRgb(0x66, 0x66, 0x66)
    };

    private int _selectedRangeIndex;
    private string _summaryText = string.Empty;
    private bool _hasData;
    private bool _isEmpty = true;
    private string _emptyText = KeyStats.Properties.Strings.KeyHistory_Empty;

    public ObservableCollection<KeyHistoryChartItem> PieChartItems { get; } = new();
    public ObservableCollection<KeyHistoryChartItem> BarChartItems { get; } = new();

    public int SelectedRangeIndex
    {
        get => _selectedRangeIndex;
        set
        {
            if (SetProperty(ref _selectedRangeIndex, value))
            {
                PersistSelectedRangeIndex(value);
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

    public KeyHistoryViewModel()
    {
        _selectedRangeIndex = LoadSelectedRangeIndex();
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

    private void RefreshData()
    {
        var manager = StatsManager.Instance;
        var range = SelectedRangeIndex switch
        {
            0 => StatsManager.KeyHistoryRange.Today,
            1 => StatsManager.KeyHistoryRange.Week,
            2 => StatsManager.KeyHistoryRange.Month,
            3 => StatsManager.KeyHistoryRange.All,
            _ => StatsManager.KeyHistoryRange.Week
        };

        var allItems = manager.GetHistoricalKeyCounts(range);
        var total = allItems.Sum(x => x.Count);
        var distinct = allItems.Count;

        PieChartItems.Clear();
        BarChartItems.Clear();

        if (total <= 0)
        {
            SummaryText = string.Empty;
            IsEmpty = true;
            HasData = false;
            return;
        }

        IsEmpty = false;
        HasData = true;
        SummaryText = string.Format(
            KeyStats.Properties.Strings.KeyHistory_SummaryFormat,
            manager.FormatNumber(total),
            manager.FormatNumber(distinct));

        var topForBar = allItems.Take(20).ToList();
        var maxCount = Math.Max(1, topForBar.Select(x => x.Count).DefaultIfEmpty(0).Max());
        for (var i = 0; i < topForBar.Count; i++)
        {
            var color = new SolidColorBrush(Palette[i % Palette.Length]);
            var item = topForBar[i];
            BarChartItems.Add(new KeyHistoryChartItem
            {
                Key = item.Key,
                Count = item.Count,
                CountText = manager.FormatNumber(item.Count),
                PercentageText = $"{(item.Count / (double)total):P1}",
                Ratio = item.Count / (double)maxCount,
                Brush = color
            });
        }

        var topForPie = allItems.Take(20).ToList();
        var pieTotal = Math.Max(1, topForPie.Sum(x => x.Count));
        var startAngle = -90.0;
        for (var i = 0; i < topForPie.Count; i++)
        {
            var item = topForPie[i];
            var sweep = i == topForPie.Count - 1
                ? 360.0 - (startAngle + 90.0)
                : 360.0 * item.Count / pieTotal;
            if (sweep < 0)
            {
                sweep = 0;
            }

            var color = new SolidColorBrush(Palette[i % Palette.Length]);
            PieChartItems.Add(new KeyHistoryChartItem
            {
                Key = item.Key,
                Count = item.Count,
                CountText = manager.FormatNumber(item.Count),
                PercentageText = $"{(item.Count / (double)total):P1}",
                Ratio = item.Count / (double)pieTotal,
                StartAngle = startAngle,
                SweepAngle = sweep,
                Brush = color
            });

            startAngle += sweep;
        }
    }

    private static int LoadSelectedRangeIndex()
    {
        var savedIndex = StatsManager.Instance.Settings.KeyHistorySelectedRangeIndex;
        return IsValidRangeIndex(savedIndex) ? savedIndex : DefaultRangeIndex;
    }

    private static void PersistSelectedRangeIndex(int selectedRangeIndex)
    {
        if (!IsValidRangeIndex(selectedRangeIndex))
        {
            return;
        }

        var manager = StatsManager.Instance;
        if (manager.Settings.KeyHistorySelectedRangeIndex == selectedRangeIndex)
        {
            return;
        }

        manager.Settings.KeyHistorySelectedRangeIndex = selectedRangeIndex;
        manager.SaveSettings();
    }

    private static bool IsValidRangeIndex(int selectedRangeIndex)
    {
        return selectedRangeIndex is >= 0 and <= 3;
    }
}
