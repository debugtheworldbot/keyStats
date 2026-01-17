using System.Windows;
using System.Windows.Input;
using KeyStats.Models;
using KeyStats.Services;

namespace KeyStats.ViewModels;

public class SettingsViewModel : ViewModelBase
{
    private bool _showKeyPresses;
    private bool _showMouseClicks;
    private bool _launchAtStartup;
    private bool _enableDynamicIconColor;
    private int _dynamicIconColorStyleIndex;
    private bool _notificationsEnabled;
    private int _keyPressThreshold;
    private int _clickThreshold;

    public bool ShowKeyPresses
    {
        get => _showKeyPresses;
        set
        {
            if (SetProperty(ref _showKeyPresses, value))
            {
                StatsManager.Instance.Settings.ShowKeyPressesInTray = value;
                StatsManager.Instance.SaveSettings();
                StatsManager.Instance.NotifyTrayUpdate();
            }
        }
    }

    public bool ShowMouseClicks
    {
        get => _showMouseClicks;
        set
        {
            if (SetProperty(ref _showMouseClicks, value))
            {
                StatsManager.Instance.Settings.ShowMouseClicksInTray = value;
                StatsManager.Instance.SaveSettings();
                StatsManager.Instance.NotifyTrayUpdate();
            }
        }
    }

    public bool LaunchAtStartup
    {
        get => _launchAtStartup;
        set
        {
            if (SetProperty(ref _launchAtStartup, value))
            {
                try
                {
                    StartupManager.Instance.SetEnabled(value);
                }
                catch (Exception ex)
                {
                    MessageBox.Show($"Failed to update startup setting: {ex.Message}",
                        "Error", MessageBoxButton.OK, MessageBoxImage.Warning);
                    SetProperty(ref _launchAtStartup, !value);
                }
            }
        }
    }

    public bool EnableDynamicIconColor
    {
        get => _enableDynamicIconColor;
        set
        {
            if (SetProperty(ref _enableDynamicIconColor, value))
            {
                StatsManager.Instance.SetEnableDynamicIconColor(value);
                OnPropertyChanged(nameof(ShowDynamicIconColorStyleOptions));
            }
        }
    }

    public int DynamicIconColorStyleIndex
    {
        get => _dynamicIconColorStyleIndex;
        set
        {
            if (SetProperty(ref _dynamicIconColorStyleIndex, value))
            {
                StatsManager.Instance.Settings.DynamicIconColorStyle = value == 0
                    ? DynamicIconColorStyle.Icon
                    : DynamicIconColorStyle.Dot;
                StatsManager.Instance.SaveSettings();
                StatsManager.Instance.NotifyTrayUpdate();
            }
        }
    }

    public bool ShowDynamicIconColorStyleOptions => EnableDynamicIconColor;

    public bool NotificationsEnabled
    {
        get => _notificationsEnabled;
        set
        {
            if (SetProperty(ref _notificationsEnabled, value))
            {
                StatsManager.Instance.Settings.NotificationsEnabled = value;
                StatsManager.Instance.SaveSettings();
                OnPropertyChanged(nameof(ShowThresholdOptions));
            }
        }
    }

    public bool ShowThresholdOptions => NotificationsEnabled;

    public int KeyPressThreshold
    {
        get => _keyPressThreshold;
        set
        {
            value = Math.Clamp(value, 0, 1_000_000);
            if (SetProperty(ref _keyPressThreshold, value))
            {
                StatsManager.Instance.Settings.KeyPressNotifyThreshold = value;
                StatsManager.Instance.SaveSettings();
            }
        }
    }

    public int ClickThreshold
    {
        get => _clickThreshold;
        set
        {
            value = Math.Clamp(value, 0, 1_000_000);
            if (SetProperty(ref _clickThreshold, value))
            {
                StatsManager.Instance.Settings.ClickNotifyThreshold = value;
                StatsManager.Instance.SaveSettings();
            }
        }
    }

    public ICommand ResetStatsCommand { get; }
    public ICommand IncrementKeyThresholdCommand { get; }
    public ICommand DecrementKeyThresholdCommand { get; }
    public ICommand IncrementClickThresholdCommand { get; }
    public ICommand DecrementClickThresholdCommand { get; }

    public SettingsViewModel()
    {
        LoadSettings();

        ResetStatsCommand = new RelayCommand(ResetStats);
        IncrementKeyThresholdCommand = new RelayCommand(() => KeyPressThreshold += 100);
        DecrementKeyThresholdCommand = new RelayCommand(() => KeyPressThreshold -= 100);
        IncrementClickThresholdCommand = new RelayCommand(() => ClickThreshold += 100);
        DecrementClickThresholdCommand = new RelayCommand(() => ClickThreshold -= 100);
    }

    private void LoadSettings()
    {
        var settings = StatsManager.Instance.Settings;
        _showKeyPresses = settings.ShowKeyPressesInTray;
        _showMouseClicks = settings.ShowMouseClicksInTray;
        _launchAtStartup = StartupManager.Instance.IsEnabled;
        _enableDynamicIconColor = settings.EnableDynamicIconColor;
        _dynamicIconColorStyleIndex = settings.DynamicIconColorStyle == DynamicIconColorStyle.Icon ? 0 : 1;
        _notificationsEnabled = settings.NotificationsEnabled;
        _keyPressThreshold = settings.KeyPressNotifyThreshold;
        _clickThreshold = settings.ClickNotifyThreshold;
    }

    private void ResetStats()
    {
        var result = MessageBox.Show(
            "Are you sure you want to reset today's statistics? This action cannot be undone.",
            "Reset Statistics",
            MessageBoxButton.YesNo,
            MessageBoxImage.Warning);

        if (result == MessageBoxResult.Yes)
        {
            StatsManager.Instance.ResetStats();
        }
    }
}
