using System;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Media.Animation;
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

        Loaded += OnLoaded;
        Closed += OnClosed;
        Console.WriteLine("StatsPopupWindow constructor done");
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        Console.WriteLine("Window loaded, positioning...");
        PositionNearTray();
        
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
            
            double slideDistance = 30; // 滑入距离（像素）
            double translateY = 0;
            double translateX = 0;
            
            if (taskbarAtBottom)
            {
                translateY = slideDistance; // 从下方滑入
            }
            else if (taskbarAtTop)
            {
                translateY = -slideDistance; // 从上方滑入
            }
            else if (taskbarAtRight)
            {
                translateX = slideDistance; // 从右侧滑入
            }
            else if (taskbarAtLeft)
            {
                translateX = -slideDistance; // 从左侧滑入
            }
            else
            {
                translateY = slideDistance; // 默认从下方滑入
            }
            
            // 设置初始位置（偏移）
            var transform = (System.Windows.Media.TranslateTransform)FindName("WindowTransform");
            if (transform != null)
            {
                transform.X = translateX;
                transform.Y = translateY;
            }
            
            // 执行滑入动画
            SlideIn(translateX, translateY);
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
        _viewModel.Cleanup();
    }

    private void Window_Deactivated(object sender, EventArgs e)
    {
        Console.WriteLine($"Window_Deactivated called, _isFullyLoaded={_isFullyLoaded}");
        if (_isFullyLoaded)
        {
            SlideOut();
        }
    }
    
    private void SlideOut()
    {
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

        // 系统托盘区域预留空间（避免遮挡图标）
        const int trayAreaWidth = 250; // 系统托盘区域宽度（右侧）
        const int spacing = 10; // 窗口与鼠标/任务栏的最小间距

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
        Left = left / dpiScale;
        Top = top / dpiScale;
    }
}
