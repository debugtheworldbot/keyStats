using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using KeyStats.Helpers;
using KeyStats.Models;
using KeyStats.Services;
using KeyStats.Views.Controls;
using Strings = KeyStats.Properties.Strings;

namespace KeyStats.Views;

public partial class YearReviewWindow : Window
{
    private const int PastYearRangeId = 0;

    private readonly bool _isInitialized;
    private Dictionary<DateTime, DailyStats> _history = new();
    private int _personaRangeIndex = 2;
    private RangeOption _selectedRange = new(PastYearRangeId, Strings.YearReview_RangePast12Months);
    private readonly DispatcherTimer _refreshTimer = new() { Interval = TimeSpan.FromSeconds(5) };

    public YearReviewWindow()
    {
        InitializeComponent();
        _refreshTimer.Tick += OnRefreshTimerTick;
        ContributionWall.LessText = Strings.Settings_HeatmapPreviewLess;
        ContributionWall.MoreText = Strings.Settings_HeatmapPreviewMore;
        ContributionWall.TooltipFormatter = FormatTooltip;

        LoadHistory();
        LoadRangeOptions();
        PersonaMonthButton.IsChecked = true;
        _isInitialized = true;
        RefreshWall();
        RefreshPersona();

        Loaded += OnLoaded;
        Closed += OnClosed;
        ThemeManager.Instance.ThemeChanged += OnThemeChanged;
        StatsManager.Instance.StatsUpdateRequested += OnStatsUpdateRequested;
    }

    private bool IsClicksMetric => MetricClicksButton.IsChecked == true;

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        ApplyWindowBackdrop();
        App.CurrentApp?.TrackPageView("year_review");
    }

    private void OnClosed(object? sender, EventArgs e)
    {
        ThemeManager.Instance.ThemeChanged -= OnThemeChanged;
        StatsManager.Instance.StatsUpdateRequested -= OnStatsUpdateRequested;
        _refreshTimer.Stop();
        _refreshTimer.Tick -= OnRefreshTimerTick;
    }

    private void OnThemeChanged()
    {
        Dispatcher.BeginInvoke(new Action(ApplyWindowBackdrop));
    }

    // 打字时统计更新很频繁，合并成最多每 5 秒刷新一次，避免反复复制整份历史
    private void OnStatsUpdateRequested()
    {
        Dispatcher.BeginInvoke(new Action(() =>
        {
            if (_refreshTimer.IsEnabled)
            {
                return;
            }
            _refreshTimer.Start();
        }));
    }

    private void OnRefreshTimerTick(object? sender, EventArgs e)
    {
        _refreshTimer.Stop();
        LoadHistory();
        RefreshWall();
        RefreshPersona();
    }

    private void ApplyWindowBackdrop()
    {
        WindowBackdropHelper.Apply(this, NativeInterop.DwmSystemBackdropType.TransientWindow);
    }

    private void LoadHistory()
    {
        _history = new Dictionary<DateTime, DailyStats>();
        foreach (var pair in StatsManager.Instance.GetLocalHistorySnapshot())
        {
            if (DateTime.TryParseExact(pair.Key, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var date))
            {
                _history[date.Date] = pair.Value;
            }
        }
    }

    private void LoadRangeOptions()
    {
        var today = DateTime.Today;
        var firstYear = _history.Keys.Where(HasActivity).Select(d => d.Year).DefaultIfEmpty(today.Year).Min();
        var options = new List<RangeOption> { new(PastYearRangeId, Strings.YearReview_RangePast12Months) };
        for (var year = today.Year; year >= firstYear; year--)
        {
            options.Add(new RangeOption(year, string.Format(Strings.YearReview_RangeYearFormat, year)));
        }
        WallRangePanel.Children.Clear();
        foreach (var option in options)
        {
            var button = new RadioButton
            {
                Content = option.Label,
                Tag = option,
                GroupName = "YearReviewWallRange",
                Style = (Style)FindResource("YearReviewSegmentButton"),
                IsChecked = option.Id == _selectedRange.Id
            };
            button.Checked += WallRange_Checked;
            WallRangePanel.Children.Add(button);
        }
    }

    private bool HasActivity(DateTime date)
    {
        return _history.TryGetValue(date, out var stats) && (stats.KeyPresses > 0 || stats.TotalClicks > 0);
    }

    private int ValueFor(DateTime date)
    {
        if (!_history.TryGetValue(date, out var stats))
        {
            return 0;
        }
        return IsClicksMetric ? stats.TotalClicks : stats.KeyPresses;
    }

    private void RefreshWall()
    {
        if (!_isInitialized)
        {
            return;
        }

        var range = _selectedRange;
        var today = DateTime.Today;
        DateTime rangeStart;
        DateTime rangeEnd;
        if (range.Id == PastYearRangeId)
        {
            rangeEnd = today;
            rangeStart = StartOfWeek(today).AddDays(-52 * 7);
        }
        else
        {
            rangeStart = new DateTime(range.Id, 1, 1);
            rangeEnd = new DateTime(range.Id, 12, 31) < today ? new DateTime(range.Id, 12, 31) : today;
        }

        var gridStart = StartOfWeek(rangeStart);
        var gridEnd = range.Id == PastYearRangeId
            ? StartOfWeek(today).AddDays(6)
            : StartOfWeek(new DateTime(range.Id, 12, 31)).AddDays(6);

        var days = new List<ContributionDay>();
        for (var date = gridStart; date <= gridEnd; date = date.AddDays(1))
        {
            var inRange = date >= rangeStart && date <= rangeEnd;
            days.Add(new ContributionDay(date, inRange ? ValueFor(date) : 0, inRange));
        }
        ContributionWall.Apply(days);

        var inRangeDays = days.Where(d => d.IsInRange).ToList();
        TotalValueText.Text = inRangeDays.Sum(d => (long)d.Value).ToString("N0", CultureInfo.CurrentCulture);
        ActiveDaysValueText.Text = FormatDays(inRangeDays.Count(d => d.Value > 0));
        LongestStreakValueText.Text = FormatDays(LongestStreak(inRangeDays));
        CurrentStreakValueText.Text = rangeEnd == today ? FormatDays(CurrentStreak(today)) : "—";

        var best = inRangeDays.Where(d => d.Value > 0).OrderByDescending(d => d.Value).ThenBy(d => d.Date).FirstOrDefault();
        BestDayValueText.Text = best == null ? "—" : best.Value.ToString("N0", CultureInfo.CurrentCulture);
        BestDayDetailText.Text = best == null
            ? string.Empty
            : best.Date.ToString(Strings.YearReview_ShortDateFormat, CultureInfo.CurrentUICulture);
    }

    private static int LongestStreak(IEnumerable<ContributionDay> days)
    {
        var longest = 0;
        var current = 0;
        foreach (var day in days)
        {
            current = day.Value > 0 ? current + 1 : 0;
            longest = Math.Max(longest, current);
        }
        return longest;
    }

    // 从今天往回数连续有记录的天数；今天还没开始用时从昨天算起
    private int CurrentStreak(DateTime today)
    {
        var date = ValueFor(today) > 0 ? today : today.AddDays(-1);
        var streak = 0;
        while (ValueFor(date) > 0)
        {
            streak++;
            date = date.AddDays(-1);
        }
        return streak;
    }

    private static DateTime StartOfWeek(DateTime date)
    {
        var offset = ((int)date.DayOfWeek + 6) % 7;
        return date.Date.AddDays(-offset);
    }

    private static string FormatDays(int days)
    {
        return string.Format(CultureInfo.CurrentCulture, Strings.YearReview_DaysFormat, days);
    }

    private string FormatTooltip(ContributionDay day)
    {
        var dateText = day.Date.ToString(Strings.YearReview_TooltipDateFormat, CultureInfo.CurrentUICulture);
        var format = IsClicksMetric ? Strings.YearReview_TooltipClicksFormat : Strings.YearReview_TooltipKeysFormat;
        return string.Format(CultureInfo.CurrentCulture, format, dateText, day.Value);
    }

    private void RefreshPersona()
    {
        if (!_isInitialized)
        {
            return;
        }

        var today = DateTime.Today;
        var start = _personaRangeIndex switch
        {
            0 => today,
            1 => today.AddDays(-6),
            2 => today.AddDays(-29),
            _ => DateTime.MinValue
        };

        var keyCounts = new Dictionary<string, int>(StringComparer.Ordinal);
        var totalKeys = 0;
        var totalClicks = 0;
        foreach (var pair in _history.Where(p => p.Key >= start && p.Key <= today))
        {
            totalKeys += pair.Value.KeyPresses;
            totalClicks += pair.Value.TotalClicks;
            foreach (var key in pair.Value.KeyPressCounts)
            {
                keyCounts[key.Key] = keyCounts.TryGetValue(key.Key, out var existing) ? existing + key.Value : key.Value;
            }
        }

        var result = KeyboardPersonaAnalyzer.Analyze(keyCounts, totalKeys, totalClicks);
        if (result.HasEnoughData)
        {
            PersonaTitleText.Text = PersonaName(result.Persona);
            PersonaDescText.Text = PersonaDescription(result.Persona);
            PersonaTagsList.ItemsSource = result.SecondaryPersonas.Select(PersonaName).ToList();
        }
        else
        {
            PersonaTitleText.Text = "—";
            PersonaDescText.Text = Strings.YearReview_PersonaNotEnough;
            PersonaTagsList.ItemsSource = null;
        }

        var culture = CultureInfo.CurrentCulture;
        PersonaTotalsText.Text = string.Format(culture, Strings.YearReview_PersonaTotalsFormat, totalKeys, totalClicks);
        PersonaMetricsList.ItemsSource = new List<PersonaMetric>
        {
            new(Strings.YearReview_MetricShortcutRatio, Percent(result.ShortcutRatio),
                string.Format(culture, Strings.YearReview_MetricShortcutDetailFormat, result.ShortcutCount)),
            new(Strings.YearReview_MetricRegret, Percent(result.RegretRatio),
                string.Format(culture, Strings.YearReview_MetricRegretDetailFormat, result.RegretCount)),
            new(Strings.YearReview_MetricCopyPaste,
                string.Format(culture, Strings.YearReview_MetricCopyPasteValueFormat, result.CopyCount, result.PasteCount),
                "Ctrl+C / Ctrl+V"),
            new(Strings.YearReview_MetricUndo, result.UndoCount.ToString("N0", culture), "Ctrl+Z"),
            new(Strings.YearReview_MetricArrow, Percent(result.ArrowRatio),
                string.Format(culture, Strings.YearReview_MetricArrowDetailFormat, result.ArrowCount)),
            new(Strings.YearReview_MetricClickRatio,
                string.Format(culture, Strings.YearReview_MetricClickRatioValueFormat, Math.Round(result.ClicksPerKey * 100)),
                string.Empty),
            new(Strings.YearReview_MetricTopKeys,
                result.TopKeys.Count == 0 ? "—" : string.Join("  ·  ", result.TopKeys.Select(k => k.Key)),
                Strings.YearReview_MetricTopKeysDetail),
        };
    }

    private static string Percent(double ratio)
    {
        return (ratio * 100).ToString("0.0", CultureInfo.CurrentCulture) + "%";
    }

    private static string PersonaName(KeyboardPersona persona) => persona switch
    {
        KeyboardPersona.ShortcutMaster => Strings.YearReview_Persona_ShortcutMaster,
        KeyboardPersona.CopyPasteEngineer => Strings.YearReview_Persona_CopyPasteEngineer,
        KeyboardPersona.Perfectionist => Strings.YearReview_Persona_Perfectionist,
        KeyboardPersona.ArrowKeyWalker => Strings.YearReview_Persona_ArrowKeyWalker,
        KeyboardPersona.MousePerson => Strings.YearReview_Persona_MousePerson,
        KeyboardPersona.KeyboardPurist => Strings.YearReview_Persona_KeyboardPurist,
        _ => Strings.YearReview_Persona_BalancedPlayer
    };

    private static string PersonaDescription(KeyboardPersona persona) => persona switch
    {
        KeyboardPersona.ShortcutMaster => Strings.YearReview_Persona_ShortcutMasterDesc,
        KeyboardPersona.CopyPasteEngineer => Strings.YearReview_Persona_CopyPasteEngineerDesc,
        KeyboardPersona.Perfectionist => Strings.YearReview_Persona_PerfectionistDesc,
        KeyboardPersona.ArrowKeyWalker => Strings.YearReview_Persona_ArrowKeyWalkerDesc,
        KeyboardPersona.MousePerson => Strings.YearReview_Persona_MousePersonDesc,
        KeyboardPersona.KeyboardPurist => Strings.YearReview_Persona_KeyboardPuristDesc,
        _ => Strings.YearReview_Persona_BalancedPlayerDesc
    };

    private void Tab_Checked(object sender, RoutedEventArgs e)
    {
        if (!_isInitialized)
        {
            return;
        }

        var isWall = WallTabButton.IsChecked == true;
        WallPanel.Visibility = isWall ? Visibility.Visible : Visibility.Collapsed;
        PersonaPanel.Visibility = isWall ? Visibility.Collapsed : Visibility.Visible;
        App.CurrentApp?.TrackClick("year_review_tab", new Dictionary<string, object?>
        {
            ["tab"] = isWall ? "wall" : "persona"
        });
    }

    private void WallRange_Checked(object sender, RoutedEventArgs e)
    {
        if (sender is not RadioButton { Tag: RangeOption range })
        {
            return;
        }

        _selectedRange = range;
        if (!_isInitialized)
        {
            return;
        }

        RefreshWall();
        App.CurrentApp?.TrackClick("year_review_range", new Dictionary<string, object?>
        {
            ["range"] = range.Id == PastYearRangeId ? "past_12_months" : range.Id.ToString(CultureInfo.InvariantCulture)
        });
    }

    private void Metric_Checked(object sender, RoutedEventArgs e)
    {
        if (!_isInitialized)
        {
            return;
        }

        RefreshWall();
        App.CurrentApp?.TrackClick("year_review_metric", new Dictionary<string, object?>
        {
            ["metric"] = IsClicksMetric ? "clicks" : "keys"
        });
    }

    private void PersonaRange_Checked(object sender, RoutedEventArgs e)
    {
        if (sender is not RadioButton button || !int.TryParse(button.Tag as string, out var index))
        {
            return;
        }

        _personaRangeIndex = index;
        if (!_isInitialized)
        {
            return;
        }

        RefreshPersona();
        App.CurrentApp?.TrackClick("year_review_persona_range", new Dictionary<string, object?>
        {
            ["range"] = index switch { 0 => "today", 1 => "week", 2 => "month", _ => "all" }
        });
    }

    private sealed class RangeOption
    {
        public RangeOption(int id, string label)
        {
            Id = id;
            Label = label;
        }

        public int Id { get; }

        public string Label { get; }
    }

    private sealed class PersonaMetric
    {
        public PersonaMetric(string title, string value, string detail)
        {
            Title = title;
            Value = value;
            Detail = detail;
        }

        public string Title { get; }

        public string Value { get; }

        public string Detail { get; }
    }
}
