using System.Diagnostics;
using System.Globalization;
using System.Linq;
using System.Reflection;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using KeyStats.Helpers;
using KeyStats.Models;
using KeyStats.Services;

namespace KeyStats.Views;

public partial class SettingsWindow : Window
{
    private const string GitHubUrl = "https://github.com/debugtheworldbot/keyStats";
    private bool _isUpdatingSyncUi;

    public SettingsWindow()
    {
        InitializeComponent();
        VersionTextBlock.Text = string.Format(KeyStats.Properties.Strings.Settings_VersionFormat, GetDisplayVersion());
        Loaded += OnLoaded;
        Closed += OnClosed;
        ThemeManager.Instance.ThemeChanged += OnThemeChanged;
        CloudSyncManager.Instance.StateChanged += OnCloudSyncStateChanged;
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        ApplyWindowBackdrop();
        App.CurrentApp?.TrackPageView("settings");
        LoadCloudSyncFields();
        UpdateCloudSyncUi();
    }

    private void OnClosed(object? sender, System.EventArgs e)
    {
        ThemeManager.Instance.ThemeChanged -= OnThemeChanged;
        CloudSyncManager.Instance.StateChanged -= OnCloudSyncStateChanged;
    }

    private void OnCloudSyncStateChanged()
    {
        Dispatcher.BeginInvoke(new System.Action(UpdateCloudSyncUi));
    }

    private void LoadCloudSyncFields()
    {
        var sync = CloudSyncManager.Instance;
        SyncServerUrlTextBox.Text = sync.ServerURLString;
        SyncUsernameTextBox.Text = sync.SavedUsername;
        SyncPasswordBox.Password = "";
    }

    private void UpdateCloudSyncUi()
    {
        _isUpdatingSyncUi = true;
        try
        {
            var sync = CloudSyncManager.Instance;
            var authenticated = sync.IsAuthenticated;

            SyncAuthPanel.Visibility = authenticated ? Visibility.Collapsed : Visibility.Visible;
            SyncControlsPanel.Visibility = authenticated ? Visibility.Visible : Visibility.Collapsed;

            SyncEnabledCheckBox.IsChecked = sync.IsSyncEnabled;
            SyncEnabledCheckBox.IsEnabled = authenticated;
            SyncNowButton.IsEnabled = authenticated && sync.IsSyncEnabled;
            SyncLogoutButton.IsEnabled = authenticated;

            SyncStatusTextBlock.Text = FormatSyncStatus(sync.Status, authenticated);
        }
        finally
        {
            _isUpdatingSyncUi = false;
        }
    }

    private static string FormatSyncStatus(CloudSyncStatus status, bool authenticated)
    {
        if (!authenticated)
        {
            return KeyStats.Properties.Strings.Sync_StatusNotLoggedIn;
        }

        return status.Kind switch
        {
            CloudSyncStatusKind.Syncing => KeyStats.Properties.Strings.Sync_StatusSyncing,
            CloudSyncStatusKind.Success when status.SuccessAt.HasValue =>
                string.Format(
                    CultureInfo.CurrentCulture,
                    KeyStats.Properties.Strings.Sync_StatusSuccessFormat,
                    status.SuccessAt.Value.ToString("g", CultureInfo.CurrentCulture)),
            CloudSyncStatusKind.Failed =>
                string.Format(
                    CultureInfo.CurrentCulture,
                    KeyStats.Properties.Strings.Sync_StatusFailedFormat,
                    status.ErrorMessage ?? ""),
            _ => KeyStats.Properties.Strings.Sync_StatusReady
        };
    }

    private bool TryReadAuthInputs(out string username, out string password)
    {
        username = SyncUsernameTextBox.Text.Trim();
        password = SyncPasswordBox.Password;
        var serverUrl = SyncServerUrlTextBox.Text.Trim();

        if (string.IsNullOrWhiteSpace(serverUrl) ||
            string.IsNullOrWhiteSpace(username) ||
            string.IsNullOrWhiteSpace(password))
        {
            MessageBox.Show(
                this,
                KeyStats.Properties.Strings.Sync_Error_MissingFields,
                KeyStats.Properties.Strings.Settings_CloudSync,
                MessageBoxButton.OK,
                MessageBoxImage.Warning);
            return false;
        }

        CloudSyncManager.Instance.ServerURLString = serverUrl;
        return true;
    }

    private async void SyncLogin_Click(object sender, RoutedEventArgs e)
    {
        if (!TryReadAuthInputs(out var username, out var password)) return;

        App.CurrentApp?.TrackClick("sync_login");
        SetSyncButtonsEnabled(false);

        try
        {
            await CloudSyncManager.Instance.LoginAsync(username, password).ConfigureAwait(true);
            SyncPasswordBox.Password = "";
            UpdateCloudSyncUi();
        }
        catch (CloudSyncException ex)
        {
            MessageBox.Show(this, ex.Message, KeyStats.Properties.Strings.Settings_CloudSync, MessageBoxButton.OK, MessageBoxImage.Warning);
            UpdateCloudSyncUi();
        }
        finally
        {
            SetSyncButtonsEnabled(true);
        }
    }

    private async void SyncRegister_Click(object sender, RoutedEventArgs e)
    {
        if (!TryReadAuthInputs(out var username, out var password)) return;

        App.CurrentApp?.TrackClick("sync_register");
        SetSyncButtonsEnabled(false);

        try
        {
            await CloudSyncManager.Instance.RegisterAsync(username, password).ConfigureAwait(true);
            SyncPasswordBox.Password = "";
            UpdateCloudSyncUi();
        }
        catch (CloudSyncException ex)
        {
            MessageBox.Show(this, ex.Message, KeyStats.Properties.Strings.Settings_CloudSync, MessageBoxButton.OK, MessageBoxImage.Warning);
            UpdateCloudSyncUi();
        }
        finally
        {
            SetSyncButtonsEnabled(true);
        }
    }

    private async void SyncNow_Click(object sender, RoutedEventArgs e)
    {
        App.CurrentApp?.TrackClick("sync_now");
        SetSyncButtonsEnabled(false);
        try
        {
            await CloudSyncManager.Instance.SyncNowAsync().ConfigureAwait(true);
            UpdateCloudSyncUi();
        }
        finally
        {
            SetSyncButtonsEnabled(true);
        }
    }

    private void SyncLogout_Click(object sender, RoutedEventArgs e)
    {
        App.CurrentApp?.TrackClick("sync_logout");
        CloudSyncManager.Instance.Logout();
        SyncPasswordBox.Password = "";
        UpdateCloudSyncUi();
    }

    private void SyncEnabled_Changed(object sender, RoutedEventArgs e)
    {
        if (_isUpdatingSyncUi) return;
        if (!CloudSyncManager.Instance.IsAuthenticated) return;

        var enabled = SyncEnabledCheckBox.IsChecked == true;
        App.CurrentApp?.TrackClick("sync_enabled_toggle", new System.Collections.Generic.Dictionary<string, object?>
        {
            ["enabled"] = enabled
        });
        CloudSyncManager.Instance.IsSyncEnabled = enabled;
        UpdateCloudSyncUi();
    }

    private void SetSyncButtonsEnabled(bool enabled)
    {
        SyncLoginButton.IsEnabled = enabled;
        SyncRegisterButton.IsEnabled = enabled;
        SyncNowButton.IsEnabled = enabled && CloudSyncManager.Instance.IsAuthenticated && CloudSyncManager.Instance.IsSyncEnabled;
        SyncLogoutButton.IsEnabled = enabled && CloudSyncManager.Instance.IsAuthenticated;
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
            StatsManager.Instance.FlushPendingSave();
            RestartApp();
        }
        else
        {
            App.CurrentApp?.TrackClick("settings_language_change_cancelled");
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
            System.Console.WriteLine($"RestartApp: relaunch failed: {ex}");
        }
        Application.Current.Shutdown();
    }
}
