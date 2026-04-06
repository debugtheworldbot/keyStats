using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Input;
using KeyStats.Helpers;
using KeyStats.Services;

namespace KeyStats.Views;

public partial class NotificationSettingsWindow : Window
{
    private bool _isLoading = true;

    public NotificationSettingsWindow()
    {
        InitializeComponent();
        LoadSettings();
        _isLoading = false;
        Loaded += OnLoaded;
        Closed += OnClosed;
        ThemeManager.Instance.ThemeChanged += OnThemeChanged;
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        ApplyWindowBackdrop();
        App.CurrentApp?.TrackPageView("notification_settings");
    }

    private void OnClosed(object? sender, System.EventArgs e)
    {
        ThemeManager.Instance.ThemeChanged -= OnThemeChanged;
    }

    private void OnThemeChanged()
    {
        Dispatcher.BeginInvoke(new System.Action(ApplyWindowBackdrop));
    }

    private void ApplyWindowBackdrop()
    {
        WindowBackdropHelper.Apply(this, NativeInterop.DwmSystemBackdropType.TransientWindow);
    }

    private void LoadSettings()
    {
        var settings = StatsManager.Instance.Settings;
        EnableCheckBox.IsChecked = settings.NotificationsEnabled;
        KeyPressThresholdBox.Text = settings.KeyPressNotifyThreshold.ToString();
        ClickThresholdBox.Text = settings.ClickNotifyThreshold.ToString();
        UpdateFieldsEnabled();
    }

    private void UpdateFieldsEnabled()
    {
        var enabled = EnableCheckBox.IsChecked == true;
        KeyPressThresholdBox.IsEnabled = enabled;
        ClickThresholdBox.IsEnabled = enabled;
    }

    private void OnSettingChanged(object sender, RoutedEventArgs e)
    {
        if (_isLoading) return;
        UpdateFieldsEnabled();
        SaveSettings();
    }

    private void OnThresholdTextChanged(object sender, System.Windows.Controls.TextChangedEventArgs e)
    {
        if (_isLoading) return;
        SaveSettings();
    }

    private void NumericOnly_PreviewTextInput(object sender, TextCompositionEventArgs e)
    {
        e.Handled = !Regex.IsMatch(e.Text, @"^[0-9]+$");
    }

    private void SaveSettings()
    {
        var settings = StatsManager.Instance.Settings;
        settings.NotificationsEnabled = EnableCheckBox.IsChecked == true;

        if (int.TryParse(KeyPressThresholdBox.Text, out var keyThreshold) && keyThreshold > 0)
        {
            settings.KeyPressNotifyThreshold = keyThreshold;
        }

        if (int.TryParse(ClickThresholdBox.Text, out var clickThreshold) && clickThreshold > 0)
        {
            settings.ClickNotifyThreshold = clickThreshold;
        }

        StatsManager.Instance.SaveSettings();
    }
}
