using System;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Forms;
using KeyStats.ViewModels;

namespace KeyStats.Views;

public partial class StatsPopupWindow : Window
{
    private readonly StatsPopupViewModel _viewModel;
    private bool _isFullyLoaded;

    public StatsPopupWindow()
    {
        Console.WriteLine("StatsPopupWindow constructor...");
        InitializeComponent();
        Console.WriteLine("InitializeComponent done");

        _viewModel = (StatsPopupViewModel)DataContext;
        _viewModel.RequestClose += () => Close();

        Loaded += OnLoaded;
        Closed += OnClosed;
        Console.WriteLine("StatsPopupWindow constructor done");
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        Console.WriteLine("Window loaded, positioning...");
        PositionNearTray();
        _isFullyLoaded = true;
        Console.WriteLine($"Window positioned at {Left}, {Top}");
        Activate();
    }

    private void OnClosed(object? sender, EventArgs e)
    {
        _viewModel.Cleanup();
    }

    private void Window_Deactivated(object sender, EventArgs e)
    {
        Console.WriteLine($"Window_Deactivated called, _isFullyLoaded={_isFullyLoaded}");
        if (_isFullyLoaded)
        {
            Close();
        }
    }

    private void PositionNearTray()
    {
        // 获取鼠标当前位置（用户点击的位置）
        var mousePos = System.Windows.Forms.Control.MousePosition;
        var mouseX = mousePos.X;
        var mouseY = mousePos.Y;

        // 获取主屏幕信息
        var screen = Screen.FromPoint(new System.Drawing.Point(mouseX, mouseY));
        if (screen == null) screen = Screen.PrimaryScreen;
        if (screen == null) return;

        var workingArea = screen.WorkingArea;
        var screenBounds = screen.Bounds;
        
        // DPI 缩放因子
        var dpiScale = PresentationSource.FromVisual(this)?.CompositionTarget?.TransformToDevice.M11 ?? 1.0;
        var windowWidth = Width * dpiScale;
        var windowHeight = Height * dpiScale;

        // 确定任务栏位置
        bool taskbarAtBottom = workingArea.Bottom < screenBounds.Bottom;
        bool taskbarAtTop = workingArea.Top > screenBounds.Top;
        bool taskbarAtRight = workingArea.Right < screenBounds.Right;
        bool taskbarAtLeft = workingArea.Left > screenBounds.Left;

        double left, top;

        if (taskbarAtBottom)
        {
            // 任务栏在底部：窗口显示在鼠标上方
            left = mouseX - windowWidth / 2;
            top = workingArea.Bottom - windowHeight - 10;
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
            left = workingArea.Right - windowWidth - 10;
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
        if (top + windowHeight > workingArea.Bottom)
            top = workingArea.Bottom - windowHeight - 10;

        // 转换为 WPF 坐标（考虑 DPI）
        Left = left / dpiScale;
        Top = top / dpiScale;
    }
}
