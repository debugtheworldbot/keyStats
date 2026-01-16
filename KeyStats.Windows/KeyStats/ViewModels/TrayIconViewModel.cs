using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using KeyStats.Helpers;
using KeyStats.Services;
using KeyStats.Views;

namespace KeyStats.ViewModels;

public class TrayIconViewModel : ViewModelBase
{
    private ImageSource? _trayIcon;
    private string _tooltipText = "KeyStats";
    private StatsPopupWindow? _popupWindow;
    private SettingsWindow? _settingsWindow;

    public ImageSource? TrayIcon
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
        TrayIcon = IconGenerator.CreateTrayIconImageSource(color);
    }

    private void UpdateTooltip()
    {
        TooltipText = StatsManager.Instance.GetTooltipText();
    }

    private void TogglePopup()
    {
        if (_popupWindow != null && _popupWindow.IsVisible)
        {
            _popupWindow.Close();
            _popupWindow = null;
        }
        else
        {
            ShowStats();
        }
    }

    private void ShowStats()
    {
        if (_popupWindow != null)
        {
            _popupWindow.Activate();
            return;
        }

        _popupWindow = new StatsPopupWindow();
        _popupWindow.Closed += (_, _) => _popupWindow = null;
        _popupWindow.Show();
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
