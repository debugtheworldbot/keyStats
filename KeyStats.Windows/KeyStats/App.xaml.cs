using System.Windows;
using Hardcodet.Wpf.TaskbarNotification;
using KeyStats.Services;
using KeyStats.ViewModels;

namespace KeyStats;

public partial class App : Application
{
    private TaskbarIcon? _trayIcon;
    private TrayIconViewModel? _trayIconViewModel;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        // Ensure single instance
        var mutex = new System.Threading.Mutex(true, "KeyStats_SingleInstance", out bool createdNew);
        if (!createdNew)
        {
            MessageBox.Show("KeyStats is already running.", "KeyStats", MessageBoxButton.OK, MessageBoxImage.Information);
            Shutdown();
            return;
        }

        // Initialize services
        _ = StatsManager.Instance;
        InputMonitorService.Instance.StartMonitoring();

        // Create tray icon
        _trayIconViewModel = new TrayIconViewModel();
        _trayIcon = new TaskbarIcon
        {
            IconSource = _trayIconViewModel.TrayIcon,
            ToolTipText = _trayIconViewModel.TooltipText,
            LeftClickCommand = _trayIconViewModel.TogglePopupCommand,
            ContextMenu = CreateContextMenu()
        };

        // Bind icon and tooltip updates
        _trayIconViewModel.PropertyChanged += (s, e) =>
        {
            if (e.PropertyName == nameof(TrayIconViewModel.TrayIcon))
            {
                _trayIcon.IconSource = _trayIconViewModel.TrayIcon;
            }
            else if (e.PropertyName == nameof(TrayIconViewModel.TooltipText))
            {
                _trayIcon.ToolTipText = _trayIconViewModel.TooltipText;
            }
        };
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
