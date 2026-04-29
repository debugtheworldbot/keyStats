using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Media.Animation;
using System.Windows.Forms;
using System.Windows.Threading;
using KeyStats.Helpers;
using KeyStats.Services;
using KeyStats.ViewModels;

namespace KeyStats.Views;

public partial class StatsPopupWindow : Window
{
    public enum DisplayMode
    {
        TrayPopup,
        Windowed
    }

    private const double DefaultWindowModeWidth = 520;
    private const double DefaultWindowModeHeight = 760;
    private readonly StatsPopupViewModel _viewModel;
    private readonly bool _isWindowMode;
    private bool _isFullyLoaded;
    private bool _allowClose;
    private bool _suppressStatePersistence;
    private bool _isTrayBackdropEnabled;
    private System.Drawing.Point? _anchorPoint;
    private readonly DispatcherTimer _windowStateSaveTimer;

    public StatsPopupWindow(DisplayMode displayMode, System.Drawing.Point? anchorPoint = null)
    {
        Console.WriteLine("StatsPopupWindow constructor...");
        InitializeComponent();
        Console.WriteLine("InitializeComponent done");

        _viewModel = (StatsPopupViewModel)DataContext;
        _isWindowMode = displayMode == DisplayMode.Windowed;
        _anchorPoint = anchorPoint;
        _windowStateSaveTimer = new DispatcherTimer
        {
            Interval = TimeSpan.FromMilliseconds(400)
        };
        _windowStateSaveTimer.Tick += WindowStateSaveTimer_Tick;

        ConfigureWindowForMode();
        Loaded += OnLoaded;
        Closed += OnClosed;
        Closing += OnClosing;
        LocationChanged += OnWindowBoundsChanged;
        SizeChanged += OnWindowBoundsChanged;
        SourceInitialized += OnSourceInitialized;

        ThemeManager.Instance.ThemeChanged += OnThemeChanged;

        Console.WriteLine("StatsPopupWindow constructor done");
    }

    private void OnSourceInitialized(object? sender, EventArgs e)
    {
        if (_isWindowMode)
        {
            ApplyWindowModeBackdrop();
            return;
        }

        ApplyTrayPopupBackdrop();
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        Console.WriteLine("Window loaded, positioning...");
        if (_isWindowMode)
        {
            RestoreWindowModeBounds();
            Opacity = 1;
        }
        else
        {
            PositionNearTray();
        }
        
        // Track page view
        App.CurrentApp?.TrackPageView("stats_popup");

        if (!_isWindowMode)
        {
            // Determine animation direction (slide in from taskbar side)
            var mousePos = System.Windows.Forms.Control.MousePosition;
            var screen = Screen.FromPoint(new System.Drawing.Point(mousePos.X, mousePos.Y)) ?? Screen.PrimaryScreen;
            if (screen != null)
            {
                var workingArea = screen.WorkingArea;
                var screenBounds = screen.Bounds;
                bool taskbarAtBottom = workingArea.Bottom < screenBounds.Bottom;
                bool taskbarAtTop = workingArea.Top > screenBounds.Top;
                bool taskbarAtRight = workingArea.Right < screenBounds.Right;
                bool taskbarAtLeft = workingArea.Left > screenBounds.Left;

                double slideDistance = 30;
                double translateY = 0;
                double translateX = 0;

                if (taskbarAtBottom)
                {
                    translateY = slideDistance;
                }
                else if (taskbarAtTop)
                {
                    translateY = -slideDistance;
                }
                else if (taskbarAtRight)
                {
                    translateX = slideDistance;
                }
                else if (taskbarAtLeft)
                {
                    translateX = -slideDistance;
                }
                else
                {
                    translateY = slideDistance;
                }

                var transform = (System.Windows.Media.TranslateTransform)FindName("WindowTransform");
                if (transform != null)
                {
                    transform.X = translateX;
                    transform.Y = translateY;
                }

                SlideIn(translateX, translateY);
            }
        }
        
        _isFullyLoaded = true;
        Console.WriteLine($"Window positioned at {Left}, {Top}");
        Activate();
    }
    
    private void SlideIn(double startX, double startY)
    {
        var transform = (System.Windows.Media.TranslateTransform)FindName("WindowTransform");
        if (transform == null) return;
        
        // Fade-in animation
        var opacityAnimation = new DoubleAnimation
        {
            From = 0,
            To = 1,
            Duration = TimeSpan.FromMilliseconds(200),
            EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut }
        };

        // Slide-in animation
        var translateXAnimation = new DoubleAnimation
        {
            From = startX,
            To = 0,
            Duration = TimeSpan.FromMilliseconds(200),
            EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut }
        };
        
        var translateYAnimation = new DoubleAnimation
        {
            From = startY,
            To = 0,
            Duration = TimeSpan.FromMilliseconds(200),
            EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut }
        };
        
        BeginAnimation(UIElement.OpacityProperty, opacityAnimation);
        transform.BeginAnimation(System.Windows.Media.TranslateTransform.XProperty, translateXAnimation);
        transform.BeginAnimation(System.Windows.Media.TranslateTransform.YProperty, translateYAnimation);
    }

    private void OnClosed(object? sender, EventArgs e)
    {
        _windowStateSaveTimer.Stop();

        ThemeManager.Instance.ThemeChanged -= OnThemeChanged;

        _viewModel.Cleanup();
    }

    private void OnThemeChanged()
    {
        if (_isWindowMode)
        {
            ApplyWindowModeBackdrop();
        }
        else
        {
            ApplyTrayPopupBackdrop();
        }
    }

    private void ApplyWindowModeBackdrop()
    {
        WindowBackdropHelper.Apply(this, NativeInterop.DwmSystemBackdropType.TransientWindow);

        if (FindName("RootBorder") is System.Windows.Controls.Border rootBorder)
        {
            rootBorder.SetResourceReference(
                System.Windows.Controls.Border.BackgroundProperty,
                "WindowSurfaceBrush");
            rootBorder.BorderThickness = new Thickness(0);
        }
    }

    private void ApplyTrayPopupBackdrop()
    {
        _isTrayBackdropEnabled = WindowBackdropHelper.Apply(
            this,
            NativeInterop.DwmSystemBackdropType.TransientWindow);
        ApplyTrayPopupSurface();
    }

    private void ApplyTrayPopupSurface()
    {
        if (FindName("RootBorder") is not System.Windows.Controls.Border rootBorder)
        {
            return;
        }

        rootBorder.BorderThickness = new Thickness(1);
        rootBorder.SetResourceReference(
            System.Windows.Controls.Border.BorderBrushProperty,
            "TrayPopupBorderBrush");

        rootBorder.SetResourceReference(
            System.Windows.Controls.Border.BackgroundProperty,
            _isTrayBackdropEnabled ? "TrayBackdropTintBrush" : "SurfaceBrush");
    }

    private void Window_Deactivated(object sender, EventArgs e)
    {
        if (_isWindowMode)
        {
            return;
        }

        Console.WriteLine($"Window_Deactivated called, _isFullyLoaded={_isFullyLoaded}");
        if (_isFullyLoaded)
        {
            SlideOut();
        }
    }

    private void OpenAppStats_Click(object sender, RoutedEventArgs e)
    {
        App.CurrentApp?.TrackClick("open_app_stats");
        App.CurrentApp?.ShowAppStatsWindow();
    }

    private void OpenKeyboardHeatmap_Click(object sender, RoutedEventArgs e)
    {
        App.CurrentApp?.TrackClick("open_keyboard_heatmap");
        App.CurrentApp?.ShowKeyboardHeatmapWindow();
    }

    private void OpenKeyHistory_Click(object sender, RoutedEventArgs e)
    {
        App.CurrentApp?.TrackClick("open_key_history");
        App.CurrentApp?.ShowKeyHistoryWindow();
    }
    
    private void SlideOut()
    {
        if (_isWindowMode)
        {
            CloseWindow(force: true);
            return;
        }

        var transform = (System.Windows.Media.TranslateTransform)FindName("WindowTransform");
        if (transform == null)
        {
            Close();
            return;
        }
        
        // Determine slide-out direction (toward taskbar side)
        var mousePos = System.Windows.Forms.Control.MousePosition;
        var screen = Screen.FromPoint(new System.Drawing.Point(mousePos.X, mousePos.Y)) ?? Screen.PrimaryScreen;
        if (screen == null)
        {
            Close();
            return;
        }
        
        var workingArea = screen.WorkingArea;
        var screenBounds = screen.Bounds;
        bool taskbarAtBottom = workingArea.Bottom < screenBounds.Bottom;
        bool taskbarAtTop = workingArea.Top > screenBounds.Top;
        bool taskbarAtRight = workingArea.Right < screenBounds.Right;
        bool taskbarAtLeft = workingArea.Left > screenBounds.Left;
        
        double slideDistance = 30;
        double endX = 0;
        double endY = 0;
        
        if (taskbarAtBottom)
        {
            endY = slideDistance; // slide down
        }
        else if (taskbarAtTop)
        {
            endY = -slideDistance; // slide up
        }
        else if (taskbarAtRight)
        {
            endX = slideDistance; // slide right
        }
        else if (taskbarAtLeft)
        {
            endX = -slideDistance; // slide left
        }
        else
        {
            endY = slideDistance; // default: slide down
        }

        // Fade-out animation
        var opacityAnimation = new DoubleAnimation
        {
            From = Opacity,
            To = 0,
            Duration = TimeSpan.FromMilliseconds(150),
            EasingFunction = new CubicEase { EasingMode = EasingMode.EaseIn }
        };
        
        // Slide-out animation
        var translateXAnimation = new DoubleAnimation
        {
            From = transform.X,
            To = endX,
            Duration = TimeSpan.FromMilliseconds(150),
            EasingFunction = new CubicEase { EasingMode = EasingMode.EaseIn }
        };
        
        var translateYAnimation = new DoubleAnimation
        {
            From = transform.Y,
            To = endY,
            Duration = TimeSpan.FromMilliseconds(150),
            EasingFunction = new CubicEase { EasingMode = EasingMode.EaseIn }
        };
        
        // Close the window after the animation completes
        opacityAnimation.Completed += (s, e) => Close();
        
        BeginAnimation(UIElement.OpacityProperty, opacityAnimation);
        transform.BeginAnimation(System.Windows.Media.TranslateTransform.XProperty, translateXAnimation);
        transform.BeginAnimation(System.Windows.Media.TranslateTransform.YProperty, translateYAnimation);
    }

    private void PositionNearTray()
    {
        // Get current mouse position (prefer the click-time anchor to avoid async delay drift)
        var mousePos = _anchorPoint ?? System.Windows.Forms.Control.MousePosition;
        var mouseX = mousePos.X;
        var mouseY = mousePos.Y;

        // Get the primary screen info
        var screen = Screen.FromPoint(new System.Drawing.Point(mouseX, mouseY));
        if (screen == null) screen = Screen.PrimaryScreen;
        if (screen == null) return;

        var workingArea = screen.WorkingArea;
        var screenBounds = screen.Bounds;

        // DPI scale factors (handle X/Y independently for non-uniform DPI)
        var transformToDevice = PresentationSource.FromVisual(this)?.CompositionTarget?.TransformToDevice;
        var dpiScaleX = transformToDevice?.M11 ?? 1.0;
        var dpiScaleY = transformToDevice?.M22 ?? dpiScaleX;

        // Determine taskbar position
        bool taskbarAtBottom = workingArea.Bottom < screenBounds.Bottom;
        bool taskbarAtTop = workingArea.Top > screenBounds.Top;
        bool taskbarAtRight = workingArea.Right < screenBounds.Right;
        bool taskbarAtLeft = workingArea.Left > screenBounds.Left;

        // Reserve space for the system tray area (avoid covering icons)
        const int trayAreaWidth = 250; // System tray area width (right side)
        const int spacing = 10; // Minimum gap between window and mouse/taskbar

        // Prevent window from exceeding working area at high DPI: clamp window by current screen's available height first, then read actual size for positioning
        var maxHeightDip = Math.Max(200, (workingArea.Height - spacing * 2) / dpiScaleY);
        if (Math.Abs(MaxHeight - maxHeightDip) > 0.5)
        {
            MaxHeight = maxHeightDip;
            UpdateLayout();
        }

        var windowWidthDip = ActualWidth > 0 ? ActualWidth : Width;
        var windowHeightDip = ActualHeight > 0 ? ActualHeight : Height;
        if (double.IsNaN(windowWidthDip) || windowWidthDip <= 0) windowWidthDip = 360;
        if (double.IsNaN(windowHeightDip) || windowHeightDip <= 0) windowHeightDip = 600;

        var windowWidth = windowWidthDip * dpiScaleX;
        var windowHeight = windowHeightDip * dpiScaleY;

        double left, top;

        if (taskbarAtBottom)
        {
            // Taskbar at bottom: show window above the mouse
            left = mouseX - windowWidth / 2;

            // If the mouse is on the right side of the screen (system tray area), position the window to the left to avoid covering icons
            if (mouseX > screenBounds.Right - trayAreaWidth)
            {
                // Position the window to the right side of the screen, but leave space for the system tray area
                left = screenBounds.Right - windowWidth - trayAreaWidth - spacing;
            }

            // Display the window just above the mouse with a tiny gap
            top = mouseY - windowHeight - spacing;

            // Ensure the window stays fully within the working area
            if (top + windowHeight > workingArea.Bottom - spacing)
            {
                top = workingArea.Bottom - windowHeight - spacing;
            }
        }
        else if (taskbarAtTop)
        {
            // Taskbar at top: show window below the mouse
            left = mouseX - windowWidth / 2;
            top = workingArea.Top + 10;
        }
        else if (taskbarAtRight)
        {
            // Taskbar on the right: show window to the left of the mouse
            // If the mouse is in the right-side taskbar region (likely a tray-icon click), position the window further left
            left = workingArea.Right - windowWidth - trayAreaWidth - 10;
            top = mouseY - windowHeight / 2;
        }
        else if (taskbarAtLeft)
        {
            // Taskbar on the left: show window to the right of the mouse
            left = workingArea.Left + 10;
            top = mouseY - windowHeight / 2;
        }
        else
        {
            // Default: show window near the mouse
            left = mouseX - windowWidth / 2;
            top = mouseY - windowHeight / 2;
        }

        // Ensure the window is fully within the visible screen area
        if (left < workingArea.Left)
            left = workingArea.Left + 10;
        if (left + windowWidth > workingArea.Right)
            left = workingArea.Right - windowWidth - 10;
        if (top < workingArea.Top)
            top = workingArea.Top + 10;

        // Ensure the window bottom does not extend into the taskbar area, leaving a small gap
        if (top + windowHeight > workingArea.Bottom - spacing)
            top = workingArea.Bottom - windowHeight - spacing;

        // Convert to WPF coordinates (factoring in DPI)
        Left = left / dpiScaleX;
        Top = top / dpiScaleY;
    }

    private void ConfigureWindowForMode()
    {
        if (FindName("RootBorder") is System.Windows.Controls.Border rootBorder)
        {
            rootBorder.CornerRadius = _isWindowMode ? new CornerRadius(0) : new CornerRadius(8);
        }

        if (_isWindowMode)
        {
            WindowStyle = WindowStyle.SingleBorderWindow;
            AllowsTransparency = false;
            Background = System.Windows.Media.Brushes.Transparent;
            ShowInTaskbar = true;
            Topmost = false;
            ResizeMode = ResizeMode.CanResize;
            SizeToContent = SizeToContent.Manual;
            Width = DefaultWindowModeWidth;
            Height = DefaultWindowModeHeight;
            MinWidth = 420;
            MinHeight = 560;
            MaxHeight = double.PositiveInfinity;
            Opacity = 1;
            WindowStartupLocation = WindowStartupLocation.Manual;
            return;
        }

        WindowStyle = WindowStyle.None;
        AllowsTransparency = false;
        Background = System.Windows.Media.Brushes.Transparent;
        ShowInTaskbar = false;
        Topmost = true;
        ResizeMode = ResizeMode.NoResize;
    }

    private void OnClosing(object? sender, CancelEventArgs e)
    {
        if (!_isWindowMode || _allowClose)
        {
            return;
        }

        PersistWindowModeBounds();
        e.Cancel = true;
        Hide();
    }

    private void OnWindowBoundsChanged(object? sender, EventArgs e)
    {
        if (!_isWindowMode || !_isFullyLoaded || _suppressStatePersistence || WindowState != WindowState.Normal)
        {
            return;
        }

        _windowStateSaveTimer.Stop();
        _windowStateSaveTimer.Start();
    }

    private void OnWindowBoundsChanged(object? sender, SizeChangedEventArgs e)
    {
        OnWindowBoundsChanged(sender, EventArgs.Empty);
    }

    private void WindowStateSaveTimer_Tick(object? sender, EventArgs e)
    {
        _windowStateSaveTimer.Stop();
        PersistWindowModeBounds();
    }

    public void ShowWindow(System.Drawing.Point? anchorPoint = null)
    {
        if (anchorPoint.HasValue)
        {
            _anchorPoint = anchorPoint;
        }

        if (!IsVisible)
        {
            Show();
        }

        if (_isWindowMode)
        {
            if (WindowState == WindowState.Minimized)
            {
                WindowState = WindowState.Normal;
            }
        }
        else if (_isFullyLoaded)
        {
            PositionNearTray();
        }

        Activate();
    }

    public void CloseWindow(bool force)
    {
        _allowClose = force;
        Close();
    }

    public void PrepareForExit()
    {
        _allowClose = true;
    }

    private void RestoreWindowModeBounds()
    {
        if (!_isWindowMode)
        {
            return;
        }

        var settings = StatsManager.Instance.Settings;
        var width = settings.MainWindowWidth ?? DefaultWindowModeWidth;
        var height = settings.MainWindowHeight ?? DefaultWindowModeHeight;

        Width = Math.Max(MinWidth, width);
        Height = Math.Max(MinHeight, height);

        var left = settings.MainWindowLeft;
        var top = settings.MainWindowTop;
        if (!left.HasValue || !top.HasValue)
        {
            CenterWindowOnPrimaryScreen();
            return;
        }

        WindowStartupLocation = WindowStartupLocation.Manual;
        var bounds = new Rect(left.Value, top.Value, Width, Height);
        var visibleBounds = GetVisibleWorkingArea();
        if (!visibleBounds.HasValue)
        {
            Left = left.Value;
            Top = top.Value;
            return;
        }

        var clamped = ClampToVisibleArea(bounds, visibleBounds.Value);
        _suppressStatePersistence = true;
        try
        {
            Left = clamped.Left;
            Top = clamped.Top;
            Width = clamped.Width;
            Height = clamped.Height;
        }
        finally
        {
            _suppressStatePersistence = false;
        }
    }

    private void PersistWindowModeBounds()
    {
        if (!_isWindowMode || WindowState != WindowState.Normal)
        {
            return;
        }

        var settings = StatsManager.Instance.Settings;
        settings.MainWindowLeft = Left;
        settings.MainWindowTop = Top;
        settings.MainWindowWidth = Width;
        settings.MainWindowHeight = Height;
        StatsManager.Instance.SaveSettings();
    }

    private static Rect ClampToVisibleArea(Rect bounds, Rect workingArea)
    {
        var width = Math.Min(bounds.Width, workingArea.Width);
        var height = Math.Min(bounds.Height, workingArea.Height);
        var left = Math.Max(workingArea.Left, Math.Min(bounds.Left, workingArea.Right - width));
        var top = Math.Max(workingArea.Top, Math.Min(bounds.Top, workingArea.Bottom - height));
        return new Rect(left, top, width, height);
    }

    private static Rect? GetVisibleWorkingArea()
    {
        Rect? combinedBounds = null;
        foreach (var screen in Screen.AllScreens)
        {
            var area = new Rect(
                screen.WorkingArea.Left,
                screen.WorkingArea.Top,
                screen.WorkingArea.Width,
                screen.WorkingArea.Height);

            combinedBounds = combinedBounds.HasValue ? Rect.Union(combinedBounds.Value, area) : area;
        }

        return combinedBounds;
    }

    private void CenterWindowOnPrimaryScreen()
    {
        var workArea = SystemParameters.WorkArea;
        _suppressStatePersistence = true;
        try
        {
            Left = workArea.Left + Math.Max(0, (workArea.Width - Width) / 2);
            Top = workArea.Top + Math.Max(0, (workArea.Height - Height) / 2);
        }
        finally
        {
            _suppressStatePersistence = false;
        }
    }
}
