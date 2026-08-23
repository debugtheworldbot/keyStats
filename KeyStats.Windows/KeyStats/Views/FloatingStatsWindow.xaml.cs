using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using KeyStats.Helpers;
using KeyStats.Services;
using KeyStats.ViewModels;
using Microsoft.Win32;
using Forms = System.Windows.Forms;

namespace KeyStats.Views;

public partial class FloatingStatsWindow : Window
{
    private const double EdgeMargin = 16;
    private readonly FloatingStatsViewModel _viewModel;
    private readonly DispatcherTimer _positionSaveTimer;
    private bool _isLoaded;
    private bool _isRestoringPosition;
    private bool _isBackdropEnabled;
    private ContextMenu? _metricSelectorMenu;

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

    private void OnSourceInitialized(object? sender, EventArgs e)
    {
        ApplyBackdrop();
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        RestorePosition();
        RootBorder.ContextMenu = BuildContextMenu();
        _isLoaded = true;

        App.CurrentApp?.TrackPageView("floating_stats", new Dictionary<string, object?>
        {
            ["primary_metric"] = _viewModel.PrimaryMetricId,
            ["secondary_metric"] = _viewModel.SecondaryMetricId
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
        Dispatcher.BeginInvoke(new Action(ApplyBackdrop));
    }

    private void OnDisplaySettingsChanged(object? sender, EventArgs e)
    {
        Dispatcher.BeginInvoke(new Action(EnsureVisiblePosition));
    }

    private void ApplyBackdrop()
    {
        _isBackdropEnabled = WindowBackdropHelper.Apply(
            this,
            NativeInterop.DwmSystemBackdropType.TransientWindow);
        RootBorder.SetResourceReference(
            Border.BackgroundProperty,
            _isBackdropEnabled ? "TrayBackdropTintBrush" : "SurfaceBrush");
        RootBorder.SetResourceReference(Border.BorderBrushProperty, "TrayPopupBorderBrush");
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
    }

    private ContextMenu BuildContextMenu()
    {
        var menu = new ContextMenu();

        var primaryMetricItem = new MenuItem
        {
            Header = $"{KeyStats.Properties.Strings.FloatingStats_PrimaryMetric}: {_viewModel.PrimaryLabel}"
        };
        primaryMetricItem.Click += (_, _) => OpenMetricSelector(isPrimary: true);
        menu.Items.Add(primaryMetricItem);

        var secondaryMetricItem = new MenuItem
        {
            Header = $"{KeyStats.Properties.Strings.FloatingStats_SecondaryMetric}: {_viewModel.SecondaryLabel}"
        };
        secondaryMetricItem.Click += (_, _) => OpenMetricSelector(isPrimary: false);
        menu.Items.Add(secondaryMetricItem);
        menu.Items.Add(new Separator());

        var topmostItem = new MenuItem
        {
            Header = KeyStats.Properties.Strings.FloatingStats_AlwaysOnTop,
            IsCheckable = true,
            IsChecked = StatsManager.Instance.Settings.FloatingStatsTopmost
        };
        topmostItem.Click += (_, _) =>
        {
            var enabled = topmostItem.IsChecked;
            Topmost = enabled;
            StatsManager.Instance.Settings.FloatingStatsTopmost = enabled;
            StatsManager.Instance.SaveSettings();
            App.CurrentApp?.TrackClick("floating_stats_topmost", new Dictionary<string, object?>
            {
                ["enabled"] = enabled
            });
        };
        menu.Items.Add(topmostItem);

        var lockItem = new MenuItem
        {
            Header = KeyStats.Properties.Strings.FloatingStats_LockPosition,
            IsCheckable = true,
            IsChecked = StatsManager.Instance.Settings.FloatingStatsPositionLocked
        };
        lockItem.Click += (_, _) =>
        {
            var enabled = lockItem.IsChecked;
            StatsManager.Instance.Settings.FloatingStatsPositionLocked = enabled;
            StatsManager.Instance.SaveSettings();
            UpdateDragCursor();
            App.CurrentApp?.TrackClick("floating_stats_position_lock", new Dictionary<string, object?>
            {
                ["enabled"] = enabled
            });
        };
        menu.Items.Add(lockItem);
        menu.Items.Add(new Separator());

        var openDetailsItem = new MenuItem
        {
            Header = KeyStats.Properties.Strings.FloatingStats_OpenDetails
        };
        openDetailsItem.Click += (_, _) =>
        {
            App.CurrentApp?.TrackClick("floating_stats_open_details");
            App.CurrentApp?.ShowMainWindow();
        };
        menu.Items.Add(openDetailsItem);

        var hideItem = new MenuItem
        {
            Header = KeyStats.Properties.Strings.FloatingStats_Hide
        };
        hideItem.Click += (_, _) =>
        {
            App.CurrentApp?.TrackClick("floating_stats_hide");
            Dispatcher.BeginInvoke(new Action(() => App.CurrentApp?.SetFloatingStatsVisible(false)));
        };
        menu.Items.Add(hideItem);

        return menu;
    }

    private void OpenMetricSelector(bool isPrimary)
    {
        if (_metricSelectorMenu != null)
        {
            _metricSelectorMenu.IsOpen = false;
        }
        var selector = new ContextMenu
        {
            PlacementTarget = RootBorder,
            Placement = PlacementMode.MousePoint
        };
        _metricSelectorMenu = selector;
        selector.Closed += (_, _) =>
        {
            if (ReferenceEquals(_metricSelectorMenu, selector))
            {
                _metricSelectorMenu = null;
            }
        };

        var selectedMetric = isPrimary ? _viewModel.PrimaryMetricId : _viewModel.SecondaryMetricId;
        var otherMetric = isPrimary ? _viewModel.SecondaryMetricId : _viewModel.PrimaryMetricId;

        foreach (var metricId in FloatingStatsViewModel.AvailableMetricIds)
        {
            var capturedMetricId = metricId;
            var item = new MenuItem
            {
                Header = FloatingStatsViewModel.GetMetricLabel(metricId),
                IsCheckable = true,
                IsChecked = string.Equals(metricId, selectedMetric, StringComparison.Ordinal),
                IsEnabled = !string.Equals(metricId, otherMetric, StringComparison.Ordinal)
            };
            item.Click += (_, _) =>
            {
                _viewModel.SetMetric(isPrimary, capturedMetricId);
                RootBorder.ContextMenu = BuildContextMenu();
                App.CurrentApp?.TrackClick("floating_stats_metric_change", new Dictionary<string, object?>
                {
                    ["slot"] = isPrimary ? "primary" : "secondary",
                    ["metric"] = capturedMetricId
                });
            };
            selector.Items.Add(item);
        }

        Dispatcher.BeginInvoke(new Action(() => selector.IsOpen = true));
    }

    private void UpdateDragCursor()
    {
        RootBorder.Cursor = StatsManager.Instance.Settings.FloatingStatsPositionLocked
            ? Cursors.Arrow
            : Cursors.SizeAll;
    }

    private void OnLocationChanged(object? sender, EventArgs e)
    {
        if (!_isLoaded || _isRestoringPosition)
        {
            return;
        }

        _positionSaveTimer.Stop();
        _positionSaveTimer.Start();
    }

    private void PositionSaveTimer_Tick(object? sender, EventArgs e)
    {
        _positionSaveTimer.Stop();
        var settings = StatsManager.Instance.Settings;
        settings.FloatingStatsLeft = Left;
        settings.FloatingStatsTop = Top;
        StatsManager.Instance.SaveSettings();
    }

    private void RestorePosition()
    {
        var workingAreas = GetWorkingAreasInDips();
        var preferredArea = workingAreas.Count > 0
            ? workingAreas[0]
            : SystemParameters.WorkArea;
        var settings = StatsManager.Instance.Settings;
        var requestedBounds = settings.FloatingStatsLeft.HasValue && settings.FloatingStatsTop.HasValue
            ? new Rect(settings.FloatingStatsLeft.Value, settings.FloatingStatsTop.Value, Width, Height)
            : new Rect(
                preferredArea.Right - Width - EdgeMargin,
                preferredArea.Top + EdgeMargin,
                Width,
                Height);

        var targetArea = FindBestWorkingArea(requestedBounds, workingAreas) ?? preferredArea;
        var clamped = ClampToArea(requestedBounds, targetArea);

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

        var workingAreas = GetWorkingAreasInDips();
        var preferredArea = workingAreas.Count > 0
            ? workingAreas[0]
            : SystemParameters.WorkArea;
        var bounds = new Rect(Left, Top, Width, Height);
        var targetArea = FindBestWorkingArea(bounds, workingAreas) ?? preferredArea;
        var clamped = ClampToArea(bounds, targetArea);

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

        var settings = StatsManager.Instance.Settings;
        settings.FloatingStatsLeft = Left;
        settings.FloatingStatsTop = Top;
        StatsManager.Instance.SaveSettings();
    }

    private List<Rect> GetWorkingAreasInDips()
    {
        var areas = new List<Rect>();
        var source = PresentationSource.FromVisual(this);
        var fromDevice = source?.CompositionTarget?.TransformFromDevice ?? Matrix.Identity;

        foreach (var screen in Forms.Screen.AllScreens)
        {
            var topLeft = fromDevice.Transform(new Point(screen.WorkingArea.Left, screen.WorkingArea.Top));
            var bottomRight = fromDevice.Transform(new Point(screen.WorkingArea.Right, screen.WorkingArea.Bottom));
            var area = new Rect(topLeft, bottomRight);
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

    private static Rect? FindBestWorkingArea(Rect bounds, IReadOnlyList<Rect> workingAreas)
    {
        Rect? bestArea = null;
        var bestIntersection = 0.0;
        foreach (var area in workingAreas)
        {
            var intersection = Rect.Intersect(bounds, area);
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
}
