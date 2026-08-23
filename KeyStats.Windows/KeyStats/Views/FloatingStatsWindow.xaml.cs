using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using KeyStats.Helpers;
using KeyStats.Models;
using KeyStats.Services;
using KeyStats.ViewModels;
using Microsoft.Win32;
using Forms = System.Windows.Forms;

namespace KeyStats.Views;

public partial class FloatingStatsWindow : Window
{
    private const double EdgeMargin = 16;
    private const double SingleRowWidth = 72;
    private const double SingleRowHeight = 28;
    private const double DoubleRowWidth = 32;
    private const double DoubleRowHeight = 38;
    private readonly FloatingStatsViewModel _viewModel;
    private readonly DispatcherTimer _positionSaveTimer;
    private bool _isLoaded;
    private bool _isRestoringPosition;

    public FloatingStatsWindow()
    {
        InitializeComponent();
        _viewModel = new FloatingStatsViewModel();
        DataContext = _viewModel;
        _positionSaveTimer = new DispatcherTimer
        {
            Interval = TimeSpan.FromMilliseconds(400)
        };
        _positionSaveTimer.Tick += PositionSaveTimer_Tick;

        var settings = StatsManager.Instance.Settings;
        Topmost = settings.FloatingStatsTopmost;
        UpdateDragCursor();
        ApplyFontSettings();
        ApplyLayoutSettings();

        SourceInitialized += OnSourceInitialized;
        Loaded += OnLoaded;
        Closed += OnClosed;
        LocationChanged += OnLocationChanged;
        ThemeManager.Instance.ThemeChanged += OnThemeChanged;
        SystemEvents.DisplaySettingsChanged += OnDisplaySettingsChanged;
    }

    public void ShowWindow()
    {
        if (!IsVisible)
        {
            Show();
        }
    }

    public void ApplyBehaviorSettings()
    {
        var settings = StatsManager.Instance.Settings;
        Topmost = settings.FloatingStatsTopmost;
        UpdateDragCursor();
        ApplyFontSettings();
        if (ApplyLayoutSettings())
        {
            EnsureVisiblePosition();
        }
    }

    private void OnSourceInitialized(object? sender, EventArgs e)
    {
        ApplySurface();
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        RestorePosition();
        RootBorder.ContextMenu = BuildContextMenu();
        _isLoaded = true;

        App.CurrentApp?.TrackPageView("floating_stats", new Dictionary<string, object?>
        {
            ["primary_metric"] = _viewModel.PrimaryMetricId,
            ["secondary_metric"] = _viewModel.SecondaryMetricId,
            ["layout"] = StatsManager.Instance.Settings.FloatingStatsLayoutMode
        });
    }

    private void OnClosed(object? sender, EventArgs e)
    {
        _positionSaveTimer.Stop();
        ThemeManager.Instance.ThemeChanged -= OnThemeChanged;
        SystemEvents.DisplaySettingsChanged -= OnDisplaySettingsChanged;
        _viewModel.Cleanup();
    }

    private void OnThemeChanged()
    {
        Dispatcher.BeginInvoke(new Action(ApplySurface));
    }

    private void OnDisplaySettingsChanged(object? sender, EventArgs e)
    {
        Dispatcher.BeginInvoke(new Action(EnsureVisiblePosition));
    }

    private void ApplySurface()
    {
        RootBorder.SetResourceReference(
            Border.BackgroundProperty,
            "FloatingStatsSurfaceBrush");
        RootBorder.SetResourceReference(
            Border.BorderBrushProperty,
            "TrayPopupBorderBrush");
    }

    private void RootBorder_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ChangedButton != MouseButton.Left)
        {
            return;
        }

        if (e.ClickCount == 2)
        {
            App.CurrentApp?.TrackClick("floating_stats_open_details");
            App.CurrentApp?.ShowMainWindow();
            e.Handled = true;
            return;
        }

        if (StatsManager.Instance.Settings.FloatingStatsPositionLocked)
        {
            return;
        }

        try
        {
            DragMove();
        }
        catch (InvalidOperationException)
        {
            // The mouse may be released before WPF enters the native drag loop.
        }
        finally
        {
            EnsureVisiblePosition();
        }
    }

    private ContextMenu BuildContextMenu()
    {
        var menu = new ContextMenu();
        var lockPositionItem = new MenuItem
        {
            Header = KeyStats.Properties.Strings.FloatingStats_LockPosition,
            IsCheckable = true,
            IsChecked = StatsManager.Instance.Settings.FloatingStatsPositionLocked
        };
        lockPositionItem.Click += (_, _) =>
        {
            var isLocked = lockPositionItem.IsChecked;
            var settings = StatsManager.Instance.Settings;
            settings.FloatingStatsPositionLocked = isLocked;
            StatsManager.Instance.SaveSettings();
            ApplyBehaviorSettings();
            App.CurrentApp?.TrackClick("floating_stats_position_lock", new Dictionary<string, object?>
            {
                ["enabled"] = isLocked
            });
        };
        menu.Items.Add(lockPositionItem);

        var hideItem = new MenuItem
        {
            Header = KeyStats.Properties.Strings.FloatingStats_Hide
        };
        hideItem.Click += (_, _) =>
        {
            App.CurrentApp?.TrackClick("floating_stats_hide");
            App.CurrentApp?.SetFloatingStatsVisible(false);
        };
        menu.Items.Add(hideItem);
        menu.Items.Add(new Separator());

        var settingsItem = new MenuItem
        {
            Header = KeyStats.Properties.Strings.Tray_Settings
        };
        settingsItem.Click += (_, _) =>
        {
            App.CurrentApp?.TrackClick("floating_stats_settings");
            App.CurrentApp?.ShowSettingsWindow();
        };
        menu.Items.Add(settingsItem);
        menu.Opened += (_, _) =>
        {
            lockPositionItem.IsChecked = StatsManager.Instance.Settings.FloatingStatsPositionLocked;
        };

        return menu;
    }

    private void UpdateDragCursor()
    {
        RootBorder.Cursor = StatsManager.Instance.Settings.FloatingStatsPositionLocked
            ? Cursors.Arrow
            : Cursors.SizeAll;
    }

    private void ApplyFontSettings()
    {
        var fontSize = StatsManager.Instance.Settings.FloatingStatsFontSize;
        SinglePrimaryValueTextBlock.FontSize = fontSize;
        SingleSecondaryValueTextBlock.FontSize = fontSize;
        DoublePrimaryValueTextBlock.FontSize = fontSize;
        DoubleSecondaryValueTextBlock.FontSize = fontSize;
    }

    private bool ApplyLayoutSettings()
    {
        var settings = StatsManager.Instance.Settings;
        var useDoubleRow = string.Equals(
            settings.FloatingStatsLayoutMode,
            AppSettings.FloatingStatsDoubleRowLayoutMode,
            StringComparison.Ordinal);
        var layoutScale = settings.FloatingStatsFontSize / (double)AppSettings.FloatingStatsLayoutBaseFontSize;
        var baseWidth = useDoubleRow ? DoubleRowWidth : SingleRowWidth;
        var baseHeight = useDoubleRow ? DoubleRowHeight : SingleRowHeight;
        var targetWidth = Math.Round(baseWidth * layoutScale, MidpointRounding.AwayFromZero);
        var targetHeight = Math.Round(baseHeight * layoutScale, MidpointRounding.AwayFromZero);
        var sizeChanged = !Width.Equals(targetWidth) || !Height.Equals(targetHeight);

        SingleRowLayout.Visibility = useDoubleRow ? Visibility.Collapsed : Visibility.Visible;
        DoubleRowLayout.Visibility = useDoubleRow ? Visibility.Visible : Visibility.Collapsed;
        Width = targetWidth;
        Height = targetHeight;
        return sizeChanged;
    }

    private void OnLocationChanged(object? sender, EventArgs e)
    {
        if (!_isLoaded || _isRestoringPosition)
        {
            return;
        }

        ClampCurrentPositionToWorkingArea();
        _positionSaveTimer.Stop();
        _positionSaveTimer.Start();
    }

    private void PositionSaveTimer_Tick(object? sender, EventArgs e)
    {
        _positionSaveTimer.Stop();
        SaveCurrentPosition();
    }

    private void SaveCurrentPosition()
    {
        var settings = StatsManager.Instance.Settings;
        settings.FloatingStatsLeft = Left;
        settings.FloatingStatsTop = Top;
        var monitorDeviceName = GetCurrentMonitorDeviceName();
        if (!string.IsNullOrWhiteSpace(monitorDeviceName))
        {
            settings.FloatingStatsMonitorDeviceName = monitorDeviceName;
        }
        StatsManager.Instance.SaveSettings();
    }

    private void RestorePosition()
    {
        var workingAreas = GetWorkingAreasInDips();
        var primaryArea = workingAreas.Count > 0
            ? workingAreas[0]
            : new WorkingAreaInfo(string.Empty, SystemParameters.WorkArea);
        var settings = StatsManager.Instance.Settings;
        var savedArea = FindWorkingAreaByDeviceName(
            settings.FloatingStatsMonitorDeviceName,
            workingAreas);
        var preferredArea = savedArea ?? primaryArea;
        var requestedBounds = settings.FloatingStatsLeft.HasValue && settings.FloatingStatsTop.HasValue
            ? new Rect(settings.FloatingStatsLeft.Value, settings.FloatingStatsTop.Value, Width, Height)
            : new Rect(
                preferredArea.Bounds.Right - Width - EdgeMargin,
                preferredArea.Bounds.Top + EdgeMargin,
                Width,
                Height);

        var targetArea = savedArea ?? FindBestWorkingArea(requestedBounds, workingAreas) ?? preferredArea;
        var clamped = ClampToArea(requestedBounds, targetArea.Bounds);

        _isRestoringPosition = true;
        try
        {
            Left = clamped.Left;
            Top = clamped.Top;
        }
        finally
        {
            _isRestoringPosition = false;
        }
    }

    private void EnsureVisiblePosition()
    {
        if (!_isLoaded)
        {
            return;
        }

        ClampCurrentPositionToWorkingArea();
        _positionSaveTimer.Stop();
        SaveCurrentPosition();
    }

    private void ClampCurrentPositionToWorkingArea()
    {
        var workingAreas = GetWorkingAreasInDips();
        var preferredArea = workingAreas.Count > 0
            ? workingAreas[0]
            : new WorkingAreaInfo(string.Empty, SystemParameters.WorkArea);
        var bounds = new Rect(Left, Top, Width, Height);
        var currentArea = FindWorkingAreaByDeviceName(GetCurrentMonitorDeviceName(), workingAreas);
        var targetArea = currentArea ?? FindBestWorkingArea(bounds, workingAreas) ?? preferredArea;
        var clamped = ClampToArea(bounds, targetArea.Bounds);

        _isRestoringPosition = true;
        try
        {
            Left = clamped.Left;
            Top = clamped.Top;
        }
        finally
        {
            _isRestoringPosition = false;
        }
    }

    private List<WorkingAreaInfo> GetWorkingAreasInDips()
    {
        var areas = new List<WorkingAreaInfo>();
        var source = PresentationSource.FromVisual(this);
        var fallbackTransform = source?.CompositionTarget?.TransformFromDevice ?? Matrix.Identity;

        foreach (var screen in Forms.Screen.AllScreens)
        {
            var area = new WorkingAreaInfo(
                screen.DeviceName,
                MonitorGeometryHelper.GetWorkingAreaInDips(screen, fallbackTransform));
            if (screen.Primary)
            {
                areas.Insert(0, area);
            }
            else
            {
                areas.Add(area);
            }
        }

        return areas;
    }

    private string? GetCurrentMonitorDeviceName()
    {
        var handle = new WindowInteropHelper(this).Handle;
        return handle == IntPtr.Zero
            ? null
            : Forms.Screen.FromHandle(handle).DeviceName;
    }

    private static WorkingAreaInfo? FindWorkingAreaByDeviceName(
        string? deviceName,
        IReadOnlyList<WorkingAreaInfo> workingAreas)
    {
        if (string.IsNullOrWhiteSpace(deviceName))
        {
            return null;
        }

        foreach (var area in workingAreas)
        {
            if (string.Equals(area.DeviceName, deviceName, StringComparison.OrdinalIgnoreCase))
            {
                return area;
            }
        }

        return null;
    }

    private static WorkingAreaInfo? FindBestWorkingArea(
        Rect bounds,
        IReadOnlyList<WorkingAreaInfo> workingAreas)
    {
        WorkingAreaInfo? bestArea = null;
        var bestIntersection = 0.0;
        foreach (var area in workingAreas)
        {
            var intersection = Rect.Intersect(bounds, area.Bounds);
            var intersectionSize = intersection.IsEmpty ? 0 : intersection.Width * intersection.Height;
            if (intersectionSize <= bestIntersection)
            {
                continue;
            }

            bestIntersection = intersectionSize;
            bestArea = area;
        }

        return bestArea;
    }

    private static Rect ClampToArea(Rect bounds, Rect workingArea)
    {
        var left = Math.Max(workingArea.Left, Math.Min(bounds.Left, workingArea.Right - bounds.Width));
        var top = Math.Max(workingArea.Top, Math.Min(bounds.Top, workingArea.Bottom - bounds.Height));
        return new Rect(left, top, bounds.Width, bounds.Height);
    }

    private sealed class WorkingAreaInfo
    {
        public WorkingAreaInfo(string deviceName, Rect bounds)
        {
            DeviceName = deviceName;
            Bounds = bounds;
        }

        public string DeviceName { get; }

        public Rect Bounds { get; }
    }
}
