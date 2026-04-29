using System.Diagnostics;
using System.Linq;
using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using KeyStats.Helpers;
using KeyStats.Services;

namespace KeyStats.Views;

public partial class SettingsWindow : Window
{
    private const string GitHubUrl = "https://github.com/debugtheworldbot/keyStats";

    public SettingsWindow()
    {
        InitializeComponent();
        VersionTextBlock.Text = string.Format(KeyStats.Properties.Strings.Settings_VersionFormat, GetDisplayVersion());
        Loaded += OnLoaded;
        Closed += OnClosed;
        ThemeManager.Instance.ThemeChanged += OnThemeChanged;
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        ApplyWindowBackdrop();
        App.CurrentApp?.TrackPageView("settings");
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

    private static string GetDisplayVersion()
    {
        var assembly = typeof(App).Assembly;
        var informationalVersion = assembly
            .GetCustomAttribute<AssemblyInformationalVersionAttribute>()
            ?.InformationalVersion;

        if (!string.IsNullOrWhiteSpace(informationalVersion))
        {
            var safeVersion = informationalVersion ?? string.Empty;
            var separatorIndex = safeVersion.IndexOf('+');
            return separatorIndex >= 0
                ? safeVersion.Substring(0, separatorIndex)
                : safeVersion;
        }

        return assembly.GetName().Version?.ToString() ?? "0.0.0";
    }

    private void OpenStats_Click(object sender, RoutedEventArgs e)
    {
        App.CurrentApp?.TrackClick("open_stats_popup");
        App.CurrentApp?.ShowStatsPanel();
    }

    private void ImportData_Click(object sender, RoutedEventArgs e)
    {
        App.CurrentApp?.TrackClick("import_data");
        App.CurrentApp?.ImportData();
    }

    private void ExportData_Click(object sender, RoutedEventArgs e)
    {
        App.CurrentApp?.TrackClick("export_data");
        App.CurrentApp?.ExportData();
    }

    private void NotificationSettings_Click(object sender, RoutedEventArgs e)
    {
        App.CurrentApp?.TrackClick("open_notification_settings");
        App.CurrentApp?.ShowNotificationSettings();
    }

    private void MouseCalibration_Click(object sender, RoutedEventArgs e)
    {
        App.CurrentApp?.TrackClick("open_mouse_calibration");
        App.CurrentApp?.ShowMouseCalibration();
    }

    private void OpenGitHub_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            Process.Start(new ProcessStartInfo(GitHubUrl)
            {
                UseShellExecute = true
            });
        }
        catch
        {
            MessageBox.Show(this, KeyStats.Properties.Strings.Settings_OpenGitHubFailedMessage, KeyStats.Properties.Strings.App_Name, MessageBoxButton.OK, MessageBoxImage.Information);
        }
    }

    private bool _isInitializingLanguage = true;

    private void LanguageComboBox_Loaded(object sender, RoutedEventArgs e)
    {
        var current = StatsManager.Instance.Settings.LanguagePreference ?? "system";
        LanguageComboBox.SelectedItem = LanguageComboBox.Items
            .Cast<ComboBoxItem>()
            .FirstOrDefault(i => (string)i.Tag == current)
            ?? LanguageComboBox.Items[0];
        _isInitializingLanguage = false;
    }

    private void LanguageComboBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_isInitializingLanguage) return;

        var newPref = (string?)((ComboBoxItem?)LanguageComboBox.SelectedItem)?.Tag;
        if (string.IsNullOrEmpty(newPref)) return;

        var oldPref = StatsManager.Instance.Settings.LanguagePreference ?? "system";
        if (newPref == oldPref) return;

        var result = MessageBox.Show(
            KeyStats.Properties.Strings.Language_RestartPromptMessage,
            KeyStats.Properties.Strings.Language_RestartPromptTitle,
            MessageBoxButton.OKCancel,
            MessageBoxImage.Information);

        if (result == MessageBoxResult.OK)
        {
            App.CurrentApp?.TrackClick("settings_language_change", new System.Collections.Generic.Dictionary<string, object?>
            {
                ["from"] = oldPref,
                ["to"] = newPref,
            });
            StatsManager.Instance.Settings.LanguagePreference = newPref!;
            // SaveSettings() is debounced (2s) — RestartApp would spawn the new
            // process before the disk write happens, so it would read the old
            // language. FlushPendingSave forces a synchronous write.
            StatsManager.Instance.FlushPendingSave();
            RestartApp();
        }
        else
        {
            App.CurrentApp?.TrackClick("settings_language_change_cancelled");
            // User cancelled — revert ComboBox to the previously persisted value.
            _isInitializingLanguage = true;
            LanguageComboBox.SelectedItem = LanguageComboBox.Items
                .Cast<ComboBoxItem>()
                .FirstOrDefault(i => (string)i.Tag == oldPref);
            _isInitializingLanguage = false;
        }
    }

    private static void RestartApp()
    {
        try
        {
            var exePath = Process.GetCurrentProcess().MainModule?.FileName;
            if (!string.IsNullOrEmpty(exePath))
            {
                Process.Start(exePath);
            }
        }
        catch (System.Exception ex)
        {
            // If relaunch fails, the user will have to start the app manually.
            // Log so the failure is recoverable from a bug report.
            System.Console.WriteLine($"RestartApp: relaunch failed: {ex}");
        }
        Application.Current.Shutdown();
    }
}
