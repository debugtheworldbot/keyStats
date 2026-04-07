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
        
        // 追踪页面浏览
        App.CurrentApp?.TrackPageView("stats_popup");
        
        if (!_isWindowMode)
        {
            // 确定动画方向（从任务栏方向滑入）
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
        
        // 淡入动画
        var opacityAnimation = new DoubleAnimation
        {
            From = 0,
            To = 1,
            Duration = TimeSpan.FromMilliseconds(200),
            EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut }
        };
        
        // 滑入动画
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
        
        // 确定滑出方向（向任务栏方向滑出）
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
            endY = slideDistance; // 向下滑出
        }
        else if (taskbarAtTop)
        {
            endY = -slideDistance; // 向上滑出
        }
        else if (taskbarAtRight)
        {
            endX = slideDistance; // 向右滑出
        }
        else if (taskbarAtLeft)
        {
            endX = -slideDistance; // 向左滑出
        }
        else
        {
            endY = slideDistance; // 默认向下滑出
        }
        
        // 淡出动画
        var opacityAnimation = new DoubleAnimation
        {
            From = Opacity,
            To = 0,
            Duration = TimeSpan.FromMilliseconds(150),
            EasingFunction = new CubicEase { EasingMode = EasingMode.EaseIn }
        };
        
        // 滑出动画
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
        
        // 动画完成后关闭窗口
        opacityAnimation.Completed += (s, e) => Close();
        
        BeginAnimation(UIElement.OpacityProperty, opacityAnimation);
        transform.BeginAnimation(System.Windows.Media.TranslateTransform.XProperty, translateXAnimation);
        transform.BeginAnimation(System.Windows.Media.TranslateTransform.YProperty, translateYAnimation);
    }

    private void PositionNearTray()
    {
        // 获取鼠标当前位置（优先使用点击时的锚点，避免异步延迟导致位置偏移）
        var mousePos = _anchorPoint ?? System.Windows.Forms.Control.MousePosition;
        var mouseX = mousePos.X;
        var mouseY = mousePos.Y;

        // 获取主屏幕信息
        var screen = Screen.FromPoint(new System.Drawing.Point(mouseX, mouseY));
        if (screen == null) screen = Screen.PrimaryScreen;
        if (screen == null) return;

        var workingArea = screen.WorkingArea;
        var screenBounds = screen.Bounds;
        
        // DPI 缩放因子（独立处理 X/Y，兼容非等比 DPI）
        var transformToDevice = PresentationSource.FromVisual(this)?.CompositionTarget?.TransformToDevice;
        var dpiScaleX = transformToDevice?.M11 ?? 1.0;
        var dpiScaleY = transformToDevice?.M22 ?? dpiScaleX;

        // 确定任务栏位置
        bool taskbarAtBottom = workingArea.Bottom < screenBounds.Bottom;
        bool taskbarAtTop = workingArea.Top > screenBounds.Top;
        bool taskbarAtRight = workingArea.Right < screenBounds.Right;
        bool taskbarAtLeft = workingArea.Left > screenBounds.Left;

        // 系统托盘区域预留空间（避免遮挡图标）
        const int trayAreaWidth = 250; // 系统托盘区域宽度（右侧）
        const int spacing = 10; // 窗口与鼠标/任务栏的最小间距

        // 避免高缩放下窗口超出工作区：先按当前屏幕可用高度约束窗口，再读取实际尺寸参与定位
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
            // 任务栏在底部：窗口显示在鼠标上方
            left = mouseX - windowWidth / 2;
            
            // 如果鼠标在屏幕右侧（系统托盘区域），窗口定位到左侧，避免遮挡图标
            if (mouseX > screenBounds.Right - trayAreaWidth)
            {
                // 窗口定位到屏幕右侧，但留出系统托盘区域
                left = screenBounds.Right - windowWidth - trayAreaWidth - spacing;
            }
            
            // 窗口紧贴鼠标上方显示，只保留很小的间距
            top = mouseY - windowHeight - spacing;
            
            // 确保窗口完全在工作区域内
            if (top + windowHeight > workingArea.Bottom - spacing)
            {
                top = workingArea.Bottom - windowHeight - spacing;
            }
        }
        else if (taskbarAtTop)
        {
            // 任务栏在顶部：窗口显示在鼠标下方
            left = mouseX - windowWidth / 2;
            top = workingArea.Top + 10;
        }
        else if (taskbarAtRight)
        {
            // 任务栏在右侧：窗口显示在鼠标左侧
            // 如果鼠标在任务栏右侧区域（可能有点击托盘图标），窗口定位到更左侧
            left = workingArea.Right - windowWidth - trayAreaWidth - 10;
            top = mouseY - windowHeight / 2;
        }
        else if (taskbarAtLeft)
        {
            // 任务栏在左侧：窗口显示在鼠标右侧
            left = workingArea.Left + 10;
            top = mouseY - windowHeight / 2;
        }
        else
        {
            // 默认：窗口显示在鼠标附近
            left = mouseX - windowWidth / 2;
            top = mouseY - windowHeight / 2;
        }

        // 确保窗口完全在屏幕可见区域内
        if (left < workingArea.Left)
            left = workingArea.Left + 10;
        if (left + windowWidth > workingArea.Right)
            left = workingArea.Right - windowWidth - 10;
        if (top < workingArea.Top)
            top = workingArea.Top + 10;

        // 确保窗口底部不会延伸到任务栏区域，保持小间距
        if (top + windowHeight > workingArea.Bottom - spacing)
            top = workingArea.Bottom - windowHeight - spacing;

        // 转换为 WPF 坐标（考虑 DPI）
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
