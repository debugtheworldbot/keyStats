using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using KeyStats.Helpers;
using KeyStats.Services;
using KeyStats.Views;
using DrawingIcon = System.Drawing.Icon;

namespace KeyStats.ViewModels;

public class TrayIconViewModel : ViewModelBase
{
    private DrawingIcon? _trayIcon;
    private string _tooltipText = "KeyStats";
    private StatsPopupWindow? _popupWindow;
    private SettingsWindow? _settingsWindow;

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
    public ICommand ShowSettingsCommand { get; }
    public ICommand QuitCommand { get; }

    public TrayIconViewModel()
    {
        TogglePopupCommand = new RelayCommand(TogglePopup);
        ShowStatsCommand = new RelayCommand(ShowStats);
        ShowSettingsCommand = new RelayCommand(ShowSettings);
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
        var color = StatsManager.Instance.CurrentIconTintColor;
        var settings = StatsManager.Instance.Settings;
        var stats = StatsManager.Instance.CurrentStats;

        // Get text to display on icon
        string? keysText = null;
        string? clicksText = null;

        if (settings.ShowKeyPressesInTray)
        {
            keysText = stats.KeyPresses.ToString();
        }
        if (settings.ShowMouseClicksInTray)
        {
            clicksText = stats.TotalClicks.ToString();
        }

        TrayIcon = IconGenerator.CreateTrayIcon(color, keysText, clicksText);
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

    private void ShowStats()
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

    private void ShowSettings()
    {
        if (_settingsWindow != null)
        {
            _settingsWindow.Activate();
            return;
        }

        _settingsWindow = new SettingsWindow();
        _settingsWindow.Closed += (_, _) => _settingsWindow = null;
        _settingsWindow.Show();
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
