using System;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Data;
using Hardcodet.Wpf.TaskbarNotification;
using KeyStats.Services;
using KeyStats.ViewModels;

namespace KeyStats;

public partial class App : System.Windows.Application
{
    private TaskbarIcon? _trayIcon;
    private TrayIconViewModel? _trayIconViewModel;
    private System.Threading.Mutex? _singleInstanceMutex;

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

            Console.WriteLine("Initializing services...");
            // Initialize services
            _ = StatsManager.Instance;
            InputMonitorService.Instance.StartMonitoring();

            Console.WriteLine("Creating tray icon...");
            // Create tray icon
            _trayIconViewModel = new TrayIconViewModel();
            _trayIcon = new TaskbarIcon
            {
                Icon = _trayIconViewModel.TrayIcon,
                ToolTipText = _trayIconViewModel.TooltipText,
                ContextMenu = CreateContextMenu()
            };
            
            // 使用 TrayLeftMouseDown 事件处理左键单击（按下时立即触发，不需要双击）
            _trayIcon.TrayLeftMouseDown += (s, e) =>
            {
                Console.WriteLine("TrayLeftMouseDown event fired - showing stats");
                Application.Current?.Dispatcher.Invoke(() =>
                {
                    _trayIconViewModel?.ShowStats();
                });
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
                    _trayIcon.ToolTipText = _trayIconViewModel.TooltipText;
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

        var showStatsItem = new System.Windows.Controls.MenuItem { Header = "显示统计" };
        showStatsItem.Click += (s, e) => _trayIconViewModel?.ShowStatsCommand.Execute(null);
        menu.Items.Add(showStatsItem);

        menu.Items.Add(new System.Windows.Controls.Separator());

        var quitItem = new System.Windows.Controls.MenuItem { Header = "退出" };
        quitItem.Click += (s, e) => _trayIconViewModel?.QuitCommand.Execute(null);
        menu.Items.Add(quitItem);

        return menu;
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _trayIconViewModel?.Cleanup();
        _trayIcon?.Dispose();
        InputMonitorService.Instance.StopMonitoring();
        StatsManager.Instance.FlushPendingSave();
        _singleInstanceMutex?.ReleaseMutex();
        _singleInstanceMutex?.Dispose();
        base.OnExit(e);
    }

#if DEBUG
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AllocConsole();
#endif
}
