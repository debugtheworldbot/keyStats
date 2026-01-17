using System.Windows;
using Hardcodet.Wpf.TaskbarNotification;
using KeyStats.Services;
using KeyStats.ViewModels;

namespace KeyStats;

public partial class App : System.Windows.Application
{
    private TaskbarIcon? _trayIcon;
    private TrayIconViewModel? _trayIconViewModel;

    protected override void OnStartup(StartupEventArgs e)
    {
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
                MessageBox.Show("KeyStats is already running.", "KeyStats", MessageBoxButton.OK, MessageBoxImage.Information);
                Shutdown();
                return;
            }

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
                LeftClickCommand = _trayIconViewModel.TogglePopupCommand,
                ContextMenu = CreateContextMenu()
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
            MessageBox.Show($"Startup error: {ex.Message}", "KeyStats Error", MessageBoxButton.OK, MessageBoxImage.Error);
            Shutdown();
        }
    }

    private System.Windows.Controls.ContextMenu CreateContextMenu()
    {
        var menu = new System.Windows.Controls.ContextMenu();

        var showStatsItem = new System.Windows.Controls.MenuItem { Header = "Show Statistics" };
        showStatsItem.Click += (s, e) => _trayIconViewModel?.ShowStatsCommand.Execute(null);
        menu.Items.Add(showStatsItem);

        var settingsItem = new System.Windows.Controls.MenuItem { Header = "Settings" };
        settingsItem.Click += (s, e) => _trayIconViewModel?.ShowSettingsCommand.Execute(null);
        menu.Items.Add(settingsItem);

        menu.Items.Add(new System.Windows.Controls.Separator());

        var quitItem = new System.Windows.Controls.MenuItem { Header = "Quit" };
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
        base.OnExit(e);
    }
}
