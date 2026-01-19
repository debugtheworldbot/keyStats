using System;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using System.Reflection;
using System.IO;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using KeyStats.Helpers;
using KeyStats.Services;
using KeyStats.Views;
using DrawingIcon = System.Drawing.Icon;
using PixelFormat = System.Drawing.Imaging.PixelFormat;
using static KeyStats.Helpers.NativeInterop;

namespace KeyStats.ViewModels;

public class TrayIconViewModel : ViewModelBase
{
    private DrawingIcon? _trayIcon;
    private string _tooltipText = "KeyStats";
    private StatsPopupWindow? _popupWindow;

    public DrawingIcon? TrayIcon
    {
        get => _trayIcon;
        set => SetProperty(ref _trayIcon, value);
    }

    public string TooltipText
    {
        get => _tooltipText;
        set => SetProperty(ref _tooltipText, value);
    }

    public ICommand TogglePopupCommand { get; }
    public ICommand ShowStatsCommand { get; }
    public ICommand QuitCommand { get; }

    public TrayIconViewModel()
    {
        TogglePopupCommand = new RelayCommand(TogglePopup);
        ShowStatsCommand = new RelayCommand(ShowStats);
        QuitCommand = new RelayCommand(Quit);

        UpdateTrayIcon();
        UpdateTooltip();

        StatsManager.Instance.TrayUpdateRequested += OnTrayUpdateRequested;
    }

    private void OnTrayUpdateRequested()
    {
        Application.Current?.Dispatcher.Invoke(() =>
        {
            UpdateTrayIcon();
            UpdateTooltip();
        });
    }

    private void UpdateTrayIcon()
    {
        // Dispose old icon to prevent memory leak
        _trayIcon?.Dispose();

        // 使用静态图标文件
        try
        {
            var assembly = Assembly.GetExecutingAssembly();
            var resourceName = "KeyStats.Resources.Icons.tray-icon.png";

            using var stream = assembly.GetManifestResourceStream(resourceName);
            if (stream != null)
            {
                using var originalBitmap = new Bitmap(stream);
                // 转换为图标，使用系统托盘图标大小
                int iconSize = GetSystemTrayIconSize();
                // 使用高质量缩放算法
                using var resizedBitmap = ResizeBitmapHighQuality(originalBitmap, iconSize, iconSize);
                var hIcon = resizedBitmap.GetHicon();
                var tempIcon = DrawingIcon.FromHandle(hIcon);
                TrayIcon = (DrawingIcon)tempIcon.Clone();
                // Clean up temp icon and GDI handle
                tempIcon.Dispose();
                NativeInterop.DestroyIcon(hIcon);
                return;
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Error loading tray icon: {ex.Message}");
        }

        // 如果加载失败，尝试从文件系统加载
        try
        {
            var exePath = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
            var iconPath = Path.Combine(exePath ?? "", "Resources", "Icons", "tray-icon.png");
            if (File.Exists(iconPath))
            {
                using var originalBitmap = new Bitmap(iconPath);
                int iconSize = GetSystemTrayIconSize();
                // 使用高质量缩放算法
                using var resizedBitmap = ResizeBitmapHighQuality(originalBitmap, iconSize, iconSize);
                var hIcon = resizedBitmap.GetHicon();
                var tempIcon = DrawingIcon.FromHandle(hIcon);
                TrayIcon = (DrawingIcon)tempIcon.Clone();
                // Clean up temp icon and GDI handle
                tempIcon.Dispose();
                NativeInterop.DestroyIcon(hIcon);
                return;
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Error loading tray icon from file: {ex.Message}");
        }

        // 如果都失败，使用默认的动态生成图标
        TrayIcon = IconGenerator.CreateTrayIconKeyboard();
    }

    private static int GetSystemTrayIconSize()
    {
        // Get DPI scale factor
        using var screen = Graphics.FromHwnd(IntPtr.Zero);
        var dpiX = screen.DpiX;

        // Base size is 16 at 96 DPI (100%)
        int size = (int)(16 * dpiX / 96);

        // Clamp to reasonable sizes
        if (size <= 16) return 16;
        if (size <= 20) return 20;
        if (size <= 24) return 24;
        if (size <= 32) return 32;
        if (size <= 48) return 48;
        return 64;
    }

    /// <summary>
    /// 使用高质量算法缩放位图，减少模糊
    /// </summary>
    private static Bitmap ResizeBitmapHighQuality(Bitmap original, int width, int height)
    {
        var resized = new Bitmap(width, height, PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(resized))
        {
            // 使用高质量设置
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            g.SmoothingMode = SmoothingMode.HighQuality;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            g.CompositingQuality = CompositingQuality.HighQuality;
            
            // 绘制缩放后的图像
            g.DrawImage(original, 0, 0, width, height);
        }
        return resized;
    }

    private void UpdateTooltip()
    {
        TooltipText = StatsManager.Instance.GetTooltipText();
    }

    private void TogglePopup()
    {
        Console.WriteLine("=== TogglePopup called ===");
        try
        {
            if (_popupWindow != null && _popupWindow.IsVisible)
            {
                Console.WriteLine("Closing existing window");
                _popupWindow.Close();
                _popupWindow = null;
            }
            else
            {
                Console.WriteLine("Calling ShowStats...");
                ShowStats();
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine($"TogglePopup error: {ex}");
        }
    }

    public void ShowStats()
    {
        try
        {
            Console.WriteLine("ShowStats called...");
            if (_popupWindow != null)
            {
                _popupWindow.Activate();
                return;
            }

            Console.WriteLine("Creating StatsPopupWindow...");
            _popupWindow = new StatsPopupWindow();
            _popupWindow.Closed += (_, _) => _popupWindow = null;
            Console.WriteLine("Showing window...");
            _popupWindow.Show();
            Console.WriteLine("Window shown.");
        }
        catch (Exception ex)
        {
            Console.WriteLine("=== ERROR IN SHOWSTATS ===");
            Console.WriteLine(ex.ToString());
            Console.WriteLine("=== END ERROR ===");
        }
    }


    private void Quit()
    {
        StatsManager.Instance.FlushPendingSave();
        InputMonitorService.Instance.StopMonitoring();
        Application.Current.Shutdown();
    }

    public void Cleanup()
    {
        StatsManager.Instance.TrayUpdateRequested -= OnTrayUpdateRequested;
    }
}
