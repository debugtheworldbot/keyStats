using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Data;
using System.Threading.Tasks;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using KeyStats.Helpers;
using KeyStats.Services;
using KeyStats.ViewModels;
using KeyStats.Views;
using DotPostHog;
using DotPostHog.Model;
using Microsoft.Toolkit.Uwp.Notifications;
using Microsoft.Win32;
using Forms = System.Windows.Forms;

namespace KeyStats;

public partial class App : System.Windows.Application
{
    private Forms.NotifyIcon? _trayIcon;
    private TrayIconViewModel? _trayIconViewModel;
    private TrayContextMenuHost? _trayContextMenuHost;
    private SettingsWindow? _settingsWindow;
    private NotificationSettingsWindow? _notificationSettingsWindow;
    private MouseCalibrationWindow? _mouseCalibrationWindow;
    private AppStatsWindow? _appStatsWindow;
    private KeyboardHeatmapWindow? _keyboardHeatmapWindow;
    private KeyHistoryWindow? _keyHistoryWindow;
    private System.Threading.Mutex? _singleInstanceMutex;
    private string? _appVersion;
    private IPostHogAnalytics? _postHogClient;

    protected override void OnStartup(StartupEventArgs e)
    {
#if DEBUG
        // 在 Debug 模式下分配控制台窗口，方便查看输出
        AllocConsole();
        Console.WriteLine("=== KeyStats Debug Console ===");
#endif
        base.OnStartup(e);

        // Global exception handlers
        AppDomain.CurrentDomain.UnhandledException += (s, args) =>
        {
            Console.WriteLine($"=== UNHANDLED EXCEPTION ===\n{args.ExceptionObject}");
        };
        DispatcherUnhandledException += (s, args) =>
        {
            Console.WriteLine($"=== DISPATCHER EXCEPTION ===\n{args.Exception}");
            args.Handled = true;
        };

        try
        {
            Console.WriteLine("KeyStats starting...");

            // Ensure single instance
            var mutex = new System.Threading.Mutex(true, "KeyStats_SingleInstance", out bool createdNew);
            if (!createdNew)
            {
                mutex.Dispose();
                MessageBox.Show("按键统计已在运行中。", "按键统计", MessageBoxButton.OK, MessageBoxImage.Information);
                Shutdown();
                return;
            }
            _singleInstanceMutex = mutex;

            EnsureStartMenuShortcut();

            Console.WriteLine("Applying theme...");
            ThemeManager.Instance.Initialize();

            Console.WriteLine("Initializing services...");
            // Initialize services
            var statsManager = StatsManager.Instance;
            StartupManager.Instance.SyncWithSettings();
            _appVersion = typeof(App).Assembly.GetName().Version?.ToString() ?? "0.0.0";
            InitializeAnalytics(statsManager);
            InputMonitorService.Instance.StartMonitoring();

            Console.WriteLine("Creating tray icon...");
            // Create tray icon
            _trayIconViewModel = new TrayIconViewModel();
            var contextMenu = CreateContextMenu();
            _trayContextMenuHost = new TrayContextMenuHost(contextMenu);
            _trayIcon = new Forms.NotifyIcon
            {
                Icon = _trayIconViewModel.TrayIcon,
                Text = _trayIconViewModel.TooltipText,
                Visible = true
            };
            _trayIcon.MouseClick += (s, e) =>
            {
                if (e.Button == Forms.MouseButtons.Right)
                {
                    Application.Current?.Dispatcher.BeginInvoke(new Action(() =>
                    {
                        _trayContextMenuHost?.ShowAtCursor();
                    }));
                    return;
                }

                if (e.Button != Forms.MouseButtons.Left)
                {
                    return;
                }

                Console.WriteLine("NotifyIcon left click fired - showing stats");
                Task.Run(() =>
                {
                    try
                    {
                        TrackClick("tray_icon");
                    }
                    catch
                    {
                        // Ignore analytics failures.
                    }
                });
                var anchorPoint = Forms.Control.MousePosition;
                Application.Current?.Dispatcher.BeginInvoke(new Action(() =>
                {
                    _trayIconViewModel?.ShowStats(anchorPoint);
                }));
            };

            Console.WriteLine("Tray icon created successfully!");
            Console.WriteLine("App is running. Look for the icon in the system tray.");

            // Bind icon and tooltip updates
            _trayIconViewModel.PropertyChanged += (s, ev) =>
            {
                if (ev.PropertyName == nameof(TrayIconViewModel.TrayIcon))
                {
                    _trayIcon.Icon = _trayIconViewModel.TrayIcon;
                }
                else if (ev.PropertyName == nameof(TrayIconViewModel.TooltipText))
                {
                    _trayIcon.Text = _trayIconViewModel.TooltipText;
                }
            };
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Error during startup: {ex}");
            MessageBox.Show($"启动错误: {ex.Message}", "按键统计错误", MessageBoxButton.OK, MessageBoxImage.Error);
            Shutdown();
        }
    }

    private System.Windows.Controls.ContextMenu CreateContextMenu()
    {
        var menu = new System.Windows.Controls.ContextMenu();

        var openMainWindowItem = new System.Windows.Controls.MenuItem { Header = "打开主界面" };
        openMainWindowItem.Click += (s, e) =>
        {
            TrackClick("context_menu_open_main_window");
            _trayIconViewModel?.ShowMainWindow();
        };
        menu.Items.Add(openMainWindowItem);

        var settingsItem = new System.Windows.Controls.MenuItem { Header = "设置" };
        settingsItem.Click += (s, e) =>
        {
            TrackClick("context_menu_settings");
            ShowSettingsWindow();
        };
        menu.Items.Add(settingsItem);

        var startupItem = new System.Windows.Controls.MenuItem
        {
            Header = "开机启动",
            IsCheckable = true,
            IsChecked = StartupManager.Instance.IsEnabled
        };
        startupItem.Click += (s, e) =>
        {
            var menuItem = (System.Windows.Controls.MenuItem)s!;
            TrackClick("context_menu_startup", new Dictionary<string, object?>
            {
                ["enabled"] = menuItem.IsChecked
            });
            try
            {
                StartupManager.Instance.SetEnabled(menuItem.IsChecked);
            }
            catch
            {
                // Revert checkbox if failed
                menuItem.IsChecked = !menuItem.IsChecked;
            }
        };
        menu.Items.Add(startupItem);

        var keyHistoryItem = new System.Windows.Controls.MenuItem { Header = "历史按键统计" };
        keyHistoryItem.Click += (s, e) =>
        {
            TrackClick("context_menu_key_history");
            ShowKeyHistoryWindow();
        };
        menu.Items.Add(keyHistoryItem);

        menu.Items.Add(new System.Windows.Controls.Separator());

        var quitItem = new System.Windows.Controls.MenuItem { Header = "退出" };
        quitItem.Click += (s, e) =>
        {
            TrackClick("context_menu_quit");
            _trayIconViewModel?.QuitCommand.Execute(null);
        };
        menu.Items.Add(quitItem);

        return menu;
    }

    public void ShowNotificationSettings()
    {
        if (_notificationSettingsWindow != null && _notificationSettingsWindow.IsVisible)
        {
            _notificationSettingsWindow.Activate();
            return;
        }

        _notificationSettingsWindow = new NotificationSettingsWindow();
        _notificationSettingsWindow.Closed += (_, _) => _notificationSettingsWindow = null;
        _notificationSettingsWindow.Show();
    }

    public void ShowMouseCalibration()
    {
        if (_mouseCalibrationWindow != null && _mouseCalibrationWindow.IsVisible)
        {
            _mouseCalibrationWindow.Activate();
            return;
        }

        _mouseCalibrationWindow = new MouseCalibrationWindow();
        _mouseCalibrationWindow.Closed += (_, _) => _mouseCalibrationWindow = null;
        _mouseCalibrationWindow.Show();
        _mouseCalibrationWindow.Activate();
    }

    public void ShowSettingsWindow()
    {
        if (_settingsWindow != null && _settingsWindow.IsVisible)
        {
            _settingsWindow.Activate();
            return;
        }

        _settingsWindow = new SettingsWindow();
        _settingsWindow.Closed += (_, _) => _settingsWindow = null;
        _settingsWindow.Show();
        _settingsWindow.Activate();
    }

    public void ShowStatsPanel()
    {
        _trayIconViewModel?.ShowStatsCommand.Execute(null);
    }

    public void ShowMainWindow()
    {
        _trayIconViewModel?.ShowMainWindow();
    }

    public void ShowAppStatsWindow()
    {
        if (_appStatsWindow != null && _appStatsWindow.IsVisible)
        {
            _appStatsWindow.Activate();
            return;
        }

        _appStatsWindow = new AppStatsWindow();
        _appStatsWindow.Closed += (_, _) => _appStatsWindow = null;
        _appStatsWindow.Show();
        _appStatsWindow.Activate();
    }

    public void ShowKeyboardHeatmapWindow()
    {
        if (_keyboardHeatmapWindow != null && _keyboardHeatmapWindow.IsVisible)
        {
            _keyboardHeatmapWindow.Activate();
            return;
        }

        _keyboardHeatmapWindow = new KeyboardHeatmapWindow();
        _keyboardHeatmapWindow.Closed += (_, _) => _keyboardHeatmapWindow = null;
        _keyboardHeatmapWindow.Show();
        _keyboardHeatmapWindow.Activate();
    }

    public void ShowKeyHistoryWindow()
    {
        if (_keyHistoryWindow != null && _keyHistoryWindow.IsVisible)
        {
            _keyHistoryWindow.Activate();
            return;
        }

        _keyHistoryWindow = new KeyHistoryWindow();
        _keyHistoryWindow.Closed += (_, _) => _keyHistoryWindow = null;
        _keyHistoryWindow.Show();
        _keyHistoryWindow.Activate();
    }

    public void ExportData()
    {
        // 确保在 UI 线程上执行
        if (!Dispatcher.CheckAccess())
        {
            Dispatcher.Invoke(ExportData);
            return;
        }

        try
        {
            var dialog = new SaveFileDialog
            {
                Title = "导出数据",
                Filter = "JSON 文件 (*.json)|*.json|所有文件 (*.*)|*.*",
                DefaultExt = ".json",
                AddExtension = true,
                FileName = MakeExportFileName()
            };

            // 创建一个隐藏窗口作为对话框的 owner，避免在无窗口应用中崩溃
            var hiddenWindow = new Window
            {
                Width = 0,
                Height = 0,
                WindowStyle = WindowStyle.None,
                ShowInTaskbar = false,
                ShowActivated = false,
                Visibility = Visibility.Hidden
            };
            hiddenWindow.Show();

            try
            {
                if (dialog.ShowDialog(hiddenWindow) != true || string.IsNullOrWhiteSpace(dialog.FileName))
                {
                    return;
                }

                var data = StatsManager.Instance.ExportStatsData();
                File.WriteAllBytes(dialog.FileName, data);

                // 使用 Toast 通知显示导出成功
                new ToastContentBuilder()
                    .AddText("导出成功")
                    .AddText($"数据已保存到 {Path.GetFileName(dialog.FileName)}")
                    .Show();
            }
            finally
            {
                hiddenWindow.Close();
            }
        }
        catch (Exception ex)
        {
            new ToastContentBuilder()
                .AddText("导出失败")
                .AddText($"无法导出数据：{ex.Message}")
                .Show();
        }
    }

    public void ImportData()
    {
        if (!Dispatcher.CheckAccess())
        {
            Dispatcher.Invoke(ImportData);
            return;
        }

        try
        {
            var dialog = new OpenFileDialog
            {
                Title = "导入数据",
                Filter = "JSON 文件 (*.json)|*.json|所有文件 (*.*)|*.*",
                DefaultExt = ".json",
                CheckFileExists = true,
                Multiselect = false
            };

            var hiddenWindow = new Window
            {
                Width = 0,
                Height = 0,
                WindowStyle = WindowStyle.None,
                ShowInTaskbar = false,
                ShowActivated = false,
                Visibility = Visibility.Hidden
            };
            hiddenWindow.Show();

            try
            {
                if (dialog.ShowDialog(hiddenWindow) != true || string.IsNullOrWhiteSpace(dialog.FileName))
                {
                    return;
                }

                var selectedFile = dialog.FileName;
                hiddenWindow.Close();

                // Show Win11-style import mode dialog
                var mode = ImportModeDialog.Show();
                if (mode == null)
                {
                    return;
                }

                var data = File.ReadAllBytes(selectedFile);
                StatsManager.Instance.ImportStatsData(data, mode.Value);

                var modeLabel = mode == StatsManager.ImportMode.Overwrite ? "覆盖" : "合并";
                new ToastContentBuilder()
                    .AddText("导入成功")
                    .AddText($"已{modeLabel}导入统计数据：{Path.GetFileName(selectedFile)}")
                    .Show();

                return;
            }
            finally
            {
                if (hiddenWindow.IsVisible)
                {
                    hiddenWindow.Close();
                }
            }
        }
        catch (Exception ex)
        {
            new ToastContentBuilder()
                .AddText("导入失败")
                .AddText($"无法导入数据：{ex.Message}")
                .Show();
        }
    }

    private static string MakeExportFileName()
    {
        var dateString = DateTime.Now.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
        return $"KeyStats-Export-{dateString}.json";
    }

    protected override void OnExit(ExitEventArgs e)
    {
        TrackAnalyticsExit();
        _trayIconViewModel?.Cleanup();
        _trayContextMenuHost?.Dispose();
        if (_trayIcon != null)
        {
            _trayIcon.Visible = false;
            _trayIcon.Dispose();
        }
        InputMonitorService.Instance.StopMonitoring();
        StatsManager.Instance.FlushPendingSave();
        ThemeManager.Instance.Dispose();
        _singleInstanceMutex?.ReleaseMutex();
        _singleInstanceMutex?.Dispose();
        base.OnExit(e);
    }

    private static void EnsureStartMenuShortcut()
    {
        try
        {
            var exePath = GetCurrentExecutablePath();
            if (string.IsNullOrWhiteSpace(exePath))
            {
                return;
            }

            var programsDir = Environment.GetFolderPath(Environment.SpecialFolder.Programs);
            if (string.IsNullOrWhiteSpace(programsDir))
            {
                return;
            }

            var shortcutPath = Path.Combine(programsDir, "KeyStats.lnk");
            var shellType = Type.GetTypeFromProgID("WScript.Shell");
            if (shellType == null)
            {
                return;
            }

            dynamic shell = Activator.CreateInstance(shellType)!;
            dynamic shortcut = shell.CreateShortcut(shortcutPath);
            var existingTargetPath = GetShortcutTargetPath(shortcut);
            if (PathsEqual(existingTargetPath, exePath))
            {
                return;
            }

            shortcut.TargetPath = exePath;
            shortcut.WorkingDirectory = Path.GetDirectoryName(exePath);
            shortcut.WindowStyle = 1;
            shortcut.Description = "KeyStats";
            shortcut.IconLocation = exePath;
            shortcut.Save();
        }
        catch
        {
            // Ignore failures; app should still run.
        }
    }

    private static string? GetCurrentExecutablePath()
    {
        try
        {
            var exePath = System.Diagnostics.Process.GetCurrentProcess().MainModule?.FileName;
            if (!string.IsNullOrWhiteSpace(exePath))
            {
                return Path.GetFullPath(exePath);
            }
        }
        catch
        {
        }

        try
        {
            var exePath = System.Reflection.Assembly.GetExecutingAssembly().Location;
            if (!string.IsNullOrWhiteSpace(exePath))
            {
                return Path.GetFullPath(exePath);
            }
        }
        catch
        {
        }

        return null;
    }

    private static string? GetShortcutTargetPath(dynamic shortcut)
    {
        try
        {
            var targetPath = shortcut.TargetPath as string;
            if (string.IsNullOrWhiteSpace(targetPath))
            {
                return null;
            }

            return Path.GetFullPath(targetPath);
        }
        catch
        {
            return null;
        }
    }

    private static bool PathsEqual(string? left, string? right)
    {
        if (string.IsNullOrWhiteSpace(left) || string.IsNullOrWhiteSpace(right))
        {
            return false;
        }

        return string.Equals(left, right, StringComparison.OrdinalIgnoreCase);
    }

#if DEBUG
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AllocConsole();
#endif

    private void InitializeAnalytics(StatsManager statsManager)
    {
        var settings = statsManager.Settings;
        if (!settings.AnalyticsEnabled)
        {
            return;
        }

        var apiKey = settings.AnalyticsApiKey;
        if (string.IsNullOrWhiteSpace(apiKey))
        {
            return;
        }

        var host = string.IsNullOrWhiteSpace(settings.AnalyticsHost)
            ? "https://app.posthog.com"
            : settings.AnalyticsHost!.TrimEnd('/');

        try
        {
            // 使用 DotPostHog 创建分析客户端
            // DotPostHog 支持 .NET Framework 4.8
            _postHogClient = PostHogAnalytics.Create(
                publicApiKey: apiKey,
                host: host
            );

            var updated = false;
            if (string.IsNullOrWhiteSpace(settings.AnalyticsDistinctId))
            {
                settings.AnalyticsDistinctId = Guid.NewGuid().ToString("N");
                updated = true;
            }

            if (settings.AnalyticsFirstOpenUtc == null)
            {
                settings.AnalyticsFirstOpenUtc = DateTime.UtcNow;
                updated = true;
            }

            if (updated)
            {
                statsManager.SaveSettings();
            }

            // 使用 Identify 设置 distinctId
            var distinctId = settings.AnalyticsDistinctId;
            if (!string.IsNullOrWhiteSpace(distinctId))
            {
                try
                {
                    _postHogClient.Identify(distinctId, null);
                }
                catch (Exception ex)
                {
                    Console.WriteLine($"Failed to identify user: {ex}");
                }
            }

            if (!settings.AnalyticsInstallTracked)
            {
                CaptureEvent("app_install", statsManager, new Dictionary<string, object?>
                {
                    ["install_utc"] = settings.AnalyticsFirstOpenUtc?.ToString("o")
                });
                settings.AnalyticsInstallTracked = true;
                statsManager.SaveSettings();
            }

            CaptureEvent("app_open", statsManager, null);
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Failed to initialize analytics: {ex}");
            // 分析初始化失败不应阻止应用启动
        }
    }

    private void CaptureEvent(string eventName, StatsManager statsManager, Dictionary<string, object?>? extraProperties)
    {
        if (_postHogClient == null)
        {
            return;
        }

        var distinctId = statsManager.Settings.AnalyticsDistinctId;
        if (string.IsNullOrWhiteSpace(distinctId))
        {
            return;
        }

        var baseProperties = BuildBaseProperties(statsManager.Settings);
        // 将 distinctId 加到属性中，因为 DotPostHog 的 Capture 可能不接受 distinctId 作为单独参数
        // distinctId 已经通过上面的检查确保不为空
        baseProperties["distinct_id"] = distinctId!;
        
        if (extraProperties != null)
        {
            foreach (var kvp in extraProperties)
            {
                if (kvp.Value != null)
                {
                    baseProperties[kvp.Key] = kvp.Value;
                }
            }
        }

        try
        {
            // 将 Dictionary 转换为 PostHogEventProperties
            var postHogProperties = new PostHogEventProperties();
            foreach (var kvp in baseProperties)
            {
                postHogProperties[kvp.Key] = kvp.Value;
            }

            // DotPostHog 的 Capture 方法可能只接受事件名和属性
            // distinctId 通过 Identify 方法设置，或作为属性传递
            _postHogClient.Capture(
                eventName,
                postHogProperties
            );
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Failed to capture event {eventName}: {ex}");
            // 事件发送失败不应影响应用运行
        }
    }

    private Dictionary<string, object> BuildBaseProperties(Models.AppSettings settings)
    {
        var appVersion = _appVersion ?? "0.0.0";
        var osVersion = Environment.OSVersion.Version;
        var (windowsName, windowsBuild) = GetWindowsVersionInfo(osVersion);
        var properties = new Dictionary<string, object>
        {
            ["app_name"] = "KeyStats",
            ["app_version"] = appVersion,
            ["app_build"] = appVersion,
            ["platform"] = "windows",
            ["os"] = "Windows",
            ["os_major_version"] = windowsName,
            ["os_version"] = $"{osVersion.Major}.{osVersion.Minor}.{osVersion.Build}",
            ["$app_name"] = "KeyStats",
            ["$app_version"] = appVersion,
            ["$os"] = "Windows",
            ["$os_version"] = windowsName,
            ["os_build"] = windowsBuild,
            ["dotnet_version"] = System.Environment.Version.ToString(),
            ["locale"] = CultureInfo.CurrentUICulture.Name
        };

        if (settings.AnalyticsFirstOpenUtc.HasValue)
        {
            properties["first_open_utc"] = settings.AnalyticsFirstOpenUtc.Value.ToString("o");
        }

        // DotPostHog 可能不支持 $set_once，但保留属性结构以便将来使用
        properties["$set_once"] = new Dictionary<string, object>
        {
            ["first_open_utc"] = settings.AnalyticsFirstOpenUtc?.ToString("o") ?? string.Empty,
            ["install_utc"] = settings.AnalyticsFirstOpenUtc?.ToString("o") ?? string.Empty
        };

        return properties;
    }

    private static (string Name, string Build) GetWindowsVersionInfo(Version version)
    {
        var build = version.Build;
        var buildString = build.ToString();

        // Windows 11: Build 22000+
        // Windows 10: Build 10240-21999
        // Windows 8.1: Build 9600
        // Windows 8: Build 9200
        // Windows 7: Build 7600/7601
        string name;
        if (build >= 22000)
        {
            name = "Windows 11";
        }
        else if (build >= 10240)
        {
            name = "Windows 10";
        }
        else if (build >= 9600)
        {
            name = "Windows 8.1";
        }
        else if (build >= 9200)
        {
            name = "Windows 8";
        }
        else if (build >= 7600)
        {
            name = "Windows 7";
        }
        else
        {
            name = $"Windows (Build {build})";
        }

        return (name, buildString);
    }

    private void TrackAnalyticsExit()
    {
        if (_postHogClient == null)
        {
            return;
        }

        try
        {
            var statsManager = StatsManager.Instance;
            CaptureEvent("app_exit", statsManager, null);

            // DotPostHog 需要调用 Flush() 确保所有事件都被发送
            _postHogClient.Flush();
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Failed to track exit analytics: {ex}");
        }
    }

    /// <summary>
    /// 追踪页面浏览事件
    /// </summary>
    public void TrackPageView(string pageName, Dictionary<string, object?>? extraProperties = null)
    {
        if (_postHogClient == null)
        {
            return;
        }

        var statsManager = StatsManager.Instance;
        var properties = new Dictionary<string, object?>
        {
            ["page_name"] = pageName
        };

        if (extraProperties != null)
        {
            foreach (var kvp in extraProperties)
            {
                if (kvp.Value != null)
                {
                    properties[kvp.Key] = kvp.Value;
                }
            }
        }

        CaptureEvent("pageview", statsManager, properties);
    }

    /// <summary>
    /// 追踪点击事件
    /// </summary>
    public void TrackClick(string elementName, Dictionary<string, object?>? extraProperties = null)
    {
        if (_postHogClient == null)
        {
            return;
        }

        var statsManager = StatsManager.Instance;
        var properties = new Dictionary<string, object?>
        {
            ["element_name"] = elementName
        };

        if (extraProperties != null)
        {
            foreach (var kvp in extraProperties)
            {
                if (kvp.Value != null)
                {
                    properties[kvp.Key] = kvp.Value;
                }
            }
        }

        CaptureEvent("click", statsManager, properties);
    }

    /// <summary>
    /// 获取 App 实例（用于其他类调用追踪方法）
    /// </summary>
    public static App? CurrentApp => Current as App;

    private sealed class TrayContextMenuHost : IDisposable
    {
        private readonly ContextMenu _menu;
        private HostWindow? _hostWindow;
        private bool _isClosingHostWindow;

        public TrayContextMenuHost(ContextMenu menu)
        {
            _menu = menu;
            _menu.Closed += OnMenuClosed;
        }

        public void ShowAtCursor()
        {
            EnsureHostWindow();

            if (_hostWindow == null)
            {
                return;
            }

            _isClosingHostWindow = false;
            var cursor = Forms.Control.MousePosition;

            // Show the host window first (at its off-screen default position)
            // so that PresentationSource becomes available for DPI queries.
            if (!_hostWindow.IsVisible)
            {
                _hostWindow.Show();
            }

            // Convert physical pixels to WPF device-independent pixels (DIPs).
            // Forms.Control.MousePosition returns physical pixels, but WPF
            // Window.Left/Top expect DIPs. Without this conversion the menu
            // lands at the wrong position on high-DPI displays.
            var source = PresentationSource.FromVisual(_hostWindow);
            var dpiScaleX = source?.CompositionTarget?.TransformToDevice.M11 ?? 1.0;
            var dpiScaleY = source?.CompositionTarget?.TransformToDevice.M22 ?? 1.0;
            _hostWindow.Left = cursor.X / dpiScaleX;
            _hostWindow.Top = cursor.Y / dpiScaleY;

            _hostWindow.Activate();
            _menu.PlacementTarget = _hostWindow.Anchor;
            _menu.Placement = PlacementMode.Bottom;
            _menu.HorizontalOffset = 0;
            _menu.VerticalOffset = 0;
            _menu.IsOpen = true;
        }

        public void Dispose()
        {
            _menu.Closed -= OnMenuClosed;
            CloseHostWindow();
        }

        private void EnsureHostWindow()
        {
            if (_hostWindow != null)
            {
                return;
            }

            _hostWindow = new HostWindow();
            _hostWindow.Deactivated += OnHostWindowDeactivated;
            _hostWindow.Closed += OnHostWindowClosed;
        }

        private void OnHostWindowDeactivated(object? sender, EventArgs e)
        {
            if (_menu.IsOpen)
            {
                _menu.IsOpen = false;
            }
            else
            {
                CloseHostWindow();
            }
        }

        private void OnMenuClosed(object? sender, RoutedEventArgs e)
        {
            CloseHostWindow();
        }

        private void OnHostWindowClosed(object? sender, EventArgs e)
        {
            if (_hostWindow == null)
            {
                return;
            }

            _hostWindow.Deactivated -= OnHostWindowDeactivated;
            _hostWindow.Closed -= OnHostWindowClosed;
            _hostWindow = null;
            _isClosingHostWindow = false;
        }

        private void CloseHostWindow()
        {
            if (_hostWindow == null || _isClosingHostWindow)
            {
                return;
            }

            _isClosingHostWindow = true;
            _hostWindow.Close();
        }

        private sealed class HostWindow : Window
        {
            public Border Anchor { get; }

            public HostWindow()
            {
                Width = 1;
                Height = 1;
                WindowStyle = WindowStyle.None;
                ResizeMode = ResizeMode.NoResize;
                ShowInTaskbar = false;
                ShowActivated = true;
                AllowsTransparency = true;
                Background = Brushes.Transparent;
                Opacity = 0.01;
                Topmost = true;
                Left = -10_000;
                Top = -10_000;

                Anchor = new Border
                {
                    Width = 1,
                    Height = 1,
                    Background = Brushes.Transparent,
                    Focusable = false
                };

                Content = Anchor;
            }
        }
    }
}
