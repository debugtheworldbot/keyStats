using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using KeyStats.Helpers;
using KeyStats.Services;
using KeyStats.Views.Controls;

namespace KeyStats.Views;

public partial class KeyboardHeatmapWindow : Window
{
    private enum DaySlideDirection
    {
        Left,
        Right
    }

    private DateTime _selectedDate = DateTime.Today;
    private DateTime _startDate = DateTime.Today;
    private DateTime _endDate = DateTime.Today;
    private bool _pendingRefresh;
    private bool _isTransitionAnimating;
    private bool _suppressCalendarSelection;

    public KeyboardHeatmapWindow()
    {
        InitializeComponent();
        ApplyLocalizedText();
        RefreshData();
        UpdateAppearance();

        Loaded += OnLoaded;
        Activated += OnActivated;
        Closed += OnClosed;
        StatsManager.Instance.StatsUpdateRequested += OnStatsUpdateRequested;
        ThemeManager.Instance.ThemeChanged += OnThemeChanged;
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        ApplyWindowBackdrop();
        RefreshData();
        App.CurrentApp?.TrackPageView("keyboard_heatmap");
    }

    private void OnClosed(object? sender, EventArgs e)
    {
        StatsManager.Instance.StatsUpdateRequested -= OnStatsUpdateRequested;
        ThemeManager.Instance.ThemeChanged -= OnThemeChanged;
    }

    private void OnActivated(object? sender, EventArgs e)
    {
        RefreshData();
    }

    private void OnThemeChanged()
    {
        Dispatcher.BeginInvoke(new Action(() =>
        {
            UpdateAppearance();
            RefreshData();
        }));
    }

    private void OnStatsUpdateRequested()
    {
        Dispatcher.BeginInvoke(new Action(() =>
        {
            if (_pendingRefresh)
            {
                return;
            }

            _pendingRefresh = true;
            Dispatcher.BeginInvoke(new Action(() =>
            {
                _pendingRefresh = false;
                if (!_isTransitionAnimating)
                {
                    RefreshData();
                }
            }), DispatcherPriority.Background);
        }), DispatcherPriority.Background);
    }

    private void ApplyLocalizedText()
    {
        Title = "键盘热力图";
        TitleText.Text = "键盘热力图";
        SubtitleText.Text = "按日期查看键盘热区，仅展示聚合计数，不记录输入内容";
        PrevDayButton.Content = "前一天";
        NextDayButton.Content = "后一天";
        BackToTodayButton.Content = "回到今天";
        EmptyBadgeText.Text = "当天暂无键盘数据";
        DatePickerButton.ToolTip = "选择日期";
    }

    private void UpdateAppearance()
    {
        ApplyWindowBackdrop();

        var isDark = ThemeManager.Instance.IsDarkTheme;
        var badgeColor = isDark
            ? Color.FromArgb(220, 45, 45, 45)
            : Color.FromArgb(220, 248, 248, 248);
        EmptyBadge.Background = new SolidColorBrush(badgeColor);
        KeyboardHeatmapView.InvalidateVisual();
    }

    private void ApplyWindowBackdrop()
    {
        WindowBackdropHelper.Apply(this, NativeInterop.DwmSystemBackdropType.TransientWindow);
    }

    private void RefreshData()
    {
        var manager = StatsManager.Instance;
        var bounds = manager.GetKeyboardHeatmapDateBounds();
        _startDate = bounds.Start.Date;
        _endDate = bounds.End.Date;
        _selectedDate = ClampDate(_selectedDate);

        var dayData = manager.GetKeyboardHeatmapDay(_selectedDate);
        var visibleCounts = dayData.KeyCounts
            .Where(kvp => KeyboardHeatmapControl.SupportedKeyIds.Contains(kvp.Key))
            .ToDictionary(kvp => kvp.Key, kvp => kvp.Value, StringComparer.Ordinal);
        KeyboardHeatmapView.Apply(visibleCounts);

        var activeKeys = visibleCounts.Values.Count(value => value > 0);
        var totalFormatted = dayData.TotalKeyPresses.ToString("N0", CultureInfo.CurrentCulture);
        var activeFormatted = activeKeys.ToString("N0", CultureInfo.CurrentCulture);
        SummaryText.Text = string.Format(CultureInfo.CurrentCulture, SummaryTemplate(), totalFormatted, activeFormatted);
        DateText.Text = DisplayDateString(_selectedDate);

        var hasActivity = dayData.TotalKeyPresses > 0;
        EmptyOverlay.Visibility = hasActivity ? Visibility.Collapsed : Visibility.Visible;
        EmptyBadge.Visibility = hasActivity ? Visibility.Collapsed : Visibility.Visible;

        UpdateNavigationState();
        UpdateDatePickerState();
    }

    private string SummaryTemplate()
    {
        return "总按键: {0} · 活跃按键: {1}";
    }

    private string DisplayDateString(DateTime date)
    {
        if (date.Year == DateTime.Today.Year)
        {
            return $"{date.Month}月{date.Day}日";
        }

        return $"{date.Year}年{date.Month}月{date.Day}日";
    }

    private DateTime ClampDate(DateTime date)
    {
        var normalized = date.Date;
        if (normalized < _startDate)
        {
            return _startDate;
        }

        if (normalized > _endDate)
        {
            return _endDate;
        }

        return normalized;
    }

    private void UpdateNavigationState()
    {
        var today = DateTime.Today;
        PrevDayButton.IsEnabled = _selectedDate > _startDate;
        NextDayButton.IsEnabled = _selectedDate < _endDate;
        BackToTodayButton.Visibility = _selectedDate == today ? Visibility.Collapsed : Visibility.Visible;
    }

    private void UpdateDatePickerState()
    {
        var minDate = _startDate.Date;
        var maxDate = _endDate.Date;
        if (maxDate < minDate)
        {
            maxDate = minDate;
        }

        var displayStart = new DateTime(minDate.Year, minDate.Month, 1);
        var displayEnd = new DateTime(maxDate.Year, maxDate.Month, DateTime.DaysInMonth(maxDate.Year, maxDate.Month));

        DatePickerCalendar.DisplayDateStart = displayStart;
        DatePickerCalendar.DisplayDateEnd = displayEnd;
        DatePickerCalendar.BlackoutDates.Clear();

        if (minDate > DateTime.MinValue.Date)
        {
            DatePickerCalendar.BlackoutDates.Add(new CalendarDateRange(DateTime.MinValue.Date, minDate.AddDays(-1)));
        }

        if (maxDate < DateTime.MaxValue.Date)
        {
            DatePickerCalendar.BlackoutDates.Add(new CalendarDateRange(maxDate.AddDays(1), DateTime.MaxValue.Date));
        }

        if (!DatePickerPopup.IsOpen)
        {
            _suppressCalendarSelection = true;
            var clamped = ClampDate(_selectedDate);
            DatePickerCalendar.DisplayDate = clamped;
            DatePickerCalendar.SelectedDate = clamped;
            _suppressCalendarSelection = false;
        }

        DatePickerButton.IsEnabled = minDate <= maxDate;
    }

    private void OpenDatePicker_Click(object sender, RoutedEventArgs e)
    {
        if (DatePickerPopup.IsOpen)
        {
            DatePickerPopup.IsOpen = false;
            return;
        }

        UpdateDatePickerState();
        DatePickerPopup.IsOpen = true;
        DatePickerCalendar.Focus();
    }

    private void DatePickerPopup_Closed(object sender, EventArgs e)
    {
        DatePickerButton.Focus();
    }

    private void DatePickerCalendar_SelectedDatesChanged(object? sender, SelectionChangedEventArgs e)
    {
        if (_suppressCalendarSelection)
        {
            return;
        }

        if (DatePickerCalendar.SelectedDate is not DateTime selected)
        {
            return;
        }

        DatePickerPopup.IsOpen = false;
        TransitionToDate(selected.Date);
    }

    private void ShowPreviousDay_Click(object sender, RoutedEventArgs e)
    {
        var target = _selectedDate.AddDays(-1);
        if (target < _startDate)
        {
            return;
        }

        TransitionToDate(target);
    }

    private void ShowNextDay_Click(object sender, RoutedEventArgs e)
    {
        var target = _selectedDate.AddDays(1);
        if (target > _endDate)
        {
            return;
        }

        TransitionToDate(target);
    }

    private void BackToToday_Click(object sender, RoutedEventArgs e)
    {
        TransitionToDate(DateTime.Today);
    }

    private void TransitionToDate(DateTime targetDate)
    {
        DatePickerPopup.IsOpen = false;

        var target = ClampDate(targetDate);
        if (target == _selectedDate)
        {
            return;
        }

        var direction = target < _selectedDate ? DaySlideDirection.Left : DaySlideDirection.Right;
        var snapshot = CaptureCurrentLayerSnapshot();

        _selectedDate = target;
        RefreshData();
        AnimateDayTransition(direction, snapshot);
    }

    private BitmapSource? CaptureCurrentLayerSnapshot()
    {
        CurrentHeatmapLayer.UpdateLayout();
        if (CurrentHeatmapLayer.ActualWidth <= 0 || CurrentHeatmapLayer.ActualHeight <= 0)
        {
            return null;
        }

        var dpi = VisualTreeHelper.GetDpi(this);
        var pixelWidth = Math.Max(1, (int)Math.Round(CurrentHeatmapLayer.ActualWidth * dpi.DpiScaleX));
        var pixelHeight = Math.Max(1, (int)Math.Round(CurrentHeatmapLayer.ActualHeight * dpi.DpiScaleY));
        var bitmap = new RenderTargetBitmap(
            pixelWidth,
            pixelHeight,
            96 * dpi.DpiScaleX,
            96 * dpi.DpiScaleY,
            PixelFormats.Pbgra32);
        bitmap.Render(CurrentHeatmapLayer);
        bitmap.Freeze();
        return bitmap;
    }

    private void AnimateDayTransition(DaySlideDirection direction, BitmapSource? previousSnapshot)
    {
        if (_isTransitionAnimating)
        {
            return;
        }

        _isTransitionAnimating = true;
        var duration = TimeSpan.FromMilliseconds(160);
        var slideDistance = Math.Max(260, HeatmapAnimationHost.ActualWidth * 0.88);
        var incomingOffset = direction == DaySlideDirection.Left ? -slideDistance : slideDistance;
        var outgoingOffset = -incomingOffset;
        var easing = new CubicEase { EasingMode = EasingMode.EaseOut };

        CurrentLayerTransform.X = incomingOffset;
        CurrentHeatmapLayer.Opacity = 0;

        if (previousSnapshot != null)
        {
            PreviousSnapshotImage.Source = previousSnapshot;
            PreviousSnapshotImage.Visibility = Visibility.Visible;
            PreviousLayerTransform.X = 0;
            PreviousSnapshotImage.Opacity = 1;
        }
        else
        {
            PreviousSnapshotImage.Visibility = Visibility.Collapsed;
            PreviousSnapshotImage.Source = null;
        }

        var incomingX = new DoubleAnimation(incomingOffset, 0, duration) { EasingFunction = easing };
        var incomingOpacity = new DoubleAnimation(0, 1, duration) { EasingFunction = easing };

        incomingX.Completed += (_, _) =>
        {
            CurrentLayerTransform.BeginAnimation(TranslateTransform.XProperty, null);
            CurrentHeatmapLayer.BeginAnimation(UIElement.OpacityProperty, null);
            PreviousLayerTransform.BeginAnimation(TranslateTransform.XProperty, null);
            PreviousSnapshotImage.BeginAnimation(UIElement.OpacityProperty, null);

            PreviousSnapshotImage.Visibility = Visibility.Collapsed;
            PreviousSnapshotImage.Source = null;
            PreviousLayerTransform.X = 0;
            CurrentLayerTransform.X = 0;
            CurrentHeatmapLayer.Opacity = 1;
            _isTransitionAnimating = false;
        };

        CurrentLayerTransform.BeginAnimation(TranslateTransform.XProperty, incomingX);
        CurrentHeatmapLayer.BeginAnimation(UIElement.OpacityProperty, incomingOpacity);

        if (previousSnapshot != null)
        {
            var outgoingX = new DoubleAnimation(0, outgoingOffset, duration) { EasingFunction = easing };
            var outgoingOpacity = new DoubleAnimation(1, 0, duration) { EasingFunction = easing };
            PreviousLayerTransform.BeginAnimation(TranslateTransform.XProperty, outgoingX);
            PreviousSnapshotImage.BeginAnimation(UIElement.OpacityProperty, outgoingOpacity);
        }
    }
}
