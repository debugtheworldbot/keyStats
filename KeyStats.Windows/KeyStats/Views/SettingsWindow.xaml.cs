using System.Diagnostics;
using System.Linq;
using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using KeyStats.Helpers;
using KeyStats.Models;
using KeyStats.Services;
using KeyStats.ViewModels;
using Forms = System.Windows.Forms;

namespace KeyStats.Views;

public partial class SettingsWindow : Window
{
    private const string GitHubUrl = "https://github.com/debugtheworldbot/keyStats";
    private const double WindowEdgeMargin = 16;
    private bool _isLoadingFloatingStats = true;

    public SettingsWindow()
    {
        InitializeComponent();
        MaxHeight = System.Math.Max(1, SystemParameters.WorkArea.Height - WindowEdgeMargin * 2);
        VersionTextBlock.Text = string.Format(KeyStats.Properties.Strings.Settings_VersionFormat, GetDisplayVersion());
        Loaded += OnLoaded;
        Closed += OnClosed;
        LocationChanged += OnLocationChanged;
        ThemeManager.Instance.ThemeChanged += OnThemeChanged;
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        UpdateMaximumHeight();
        ApplyWindowBackdrop();
        LoadFloatingStatsControls();
        if (App.CurrentApp?.SyncCoordinator != null)
        {
            App.CurrentApp.SyncCoordinator.StatusChanged += OnSyncStatusChanged;
        }
        RefreshSyncStatus();
        App.CurrentApp?.TrackPageView("settings");
    }

    private void OnClosed(object? sender, System.EventArgs e)
    {
        ThemeManager.Instance.ThemeChanged -= OnThemeChanged;
        LocationChanged -= OnLocationChanged;
        if (App.CurrentApp?.SyncCoordinator != null)
        {
            App.CurrentApp.SyncCoordinator.StatusChanged -= OnSyncStatusChanged;
        }
    }

    private void OnThemeChanged()
    {
        Dispatcher.BeginInvoke(new System.Action(ApplyWindowBackdrop));
    }

    private void ApplyWindowBackdrop()
    {
        WindowBackdropHelper.Apply(this, NativeInterop.DwmSystemBackdropType.TransientWindow);
    }

    private void OnLocationChanged(object? sender, System.EventArgs e)
    {
        UpdateMaximumHeight();
    }

    private void UpdateMaximumHeight()
    {
        var handle = new WindowInteropHelper(this).Handle;
        if (handle == System.IntPtr.Zero)
        {
            return;
        }

        var source = PresentationSource.FromVisual(this);
        var fallbackTransform = source?.CompositionTarget?.TransformFromDevice ?? Matrix.Identity;
        var screen = Forms.Screen.FromHandle(handle);
        var workingArea = MonitorGeometryHelper.GetWorkingAreaInDips(screen, fallbackTransform);
        MaxHeight = System.Math.Max(1, workingArea.Height - WindowEdgeMargin * 2);
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

    private void SyncSettings_Click(object sender, RoutedEventArgs e)
    {
        App.CurrentApp?.TrackClick("open_sync_settings");
        App.CurrentApp?.ShowSyncSettingsWindow();
    }

    private void OnSyncStatusChanged()
    {
        Dispatcher.BeginInvoke(new System.Action(RefreshSyncStatus));
    }

    private void RefreshSyncStatus()
    {
        var status = App.CurrentApp?.SyncCoordinator?.GetStatus();
        if (status == null)
        {
            SyncStatusTextBlock.Text = KeyStats.Properties.Strings.Settings_SyncUnavailable;
            ImportDataButton.IsEnabled = true;
            return;
        }

        if (!status.IsServiceConfigured)
        {
            SyncStatusTextBlock.Text = KeyStats.Properties.Strings.Settings_SyncUnavailable;
            ImportDataButton.IsEnabled = !status.BlocksImport;
            ImportDataButton.ToolTip = status.BlocksImport
                ? KeyStats.Properties.Strings.Error_ImportDisabledWhileSyncing
                : null;
            return;
        }

        SyncStatusTextBlock.Text = status.NeedsRepair
            ? KeyStats.Properties.Strings.Sync_RepairRequired
            : status.SyncTotalDays.HasValue
            ? status.SyncTotalDays.Value > 0
                ? string.Format(
                    KeyStats.Properties.Strings.Sync_ProgressFormat,
                    status.SyncCompletedDays.GetValueOrDefault(),
                    status.SyncTotalDays.Value)
                : KeyStats.Properties.Strings.Sync_InProgressStatus
            : status.IsEnabled
            ? (status.ActiveDeviceCount < 2
                ? KeyStats.Properties.Strings.Sync_SingleDeviceStatus
                : string.Format(KeyStats.Properties.Strings.Sync_DeviceCountFormat, status.ActiveDeviceCount))
            : KeyStats.Properties.Strings.Settings_SyncDesc;
        ImportDataButton.IsEnabled = !status.BlocksImport;
        ImportDataButton.ToolTip = status.BlocksImport
            ? KeyStats.Properties.Strings.Error_ImportDisabledWhileSyncing
            : null;
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

    private void LoadFloatingStatsControls()
    {
        _isLoadingFloatingStats = true;
        var options = FloatingStatsViewModel.AvailableMetricIds
            .Select(metricId => new FloatingMetricOption(
                metricId,
                FloatingStatsViewModel.GetMetricLabel(metricId)))
            .ToList();
        FloatingPrimaryMetricComboBox.ItemsSource = options;
        FloatingSecondaryMetricComboBox.ItemsSource = options;
        FloatingFontSizeComboBox.ItemsSource = Enumerable.Range(
            AppSettings.MinimumFloatingStatsFontSize,
            AppSettings.MaximumFloatingStatsFontSize - AppSettings.MinimumFloatingStatsFontSize + 1);
        RefreshFloatingStatsControls();
        _isLoadingFloatingStats = false;
    }

    private void RefreshFloatingStatsControls()
    {
        var settings = StatsManager.Instance.Settings;
        FloatingPrimaryMetricComboBox.SelectedValue = settings.FloatingStatsPrimaryMetric;
        FloatingSecondaryMetricComboBox.SelectedValue = settings.FloatingStatsSecondaryMetric;
        var layoutMode = string.Equals(
            settings.FloatingStatsLayoutMode,
            AppSettings.FloatingStatsDoubleRowLayoutMode,
            System.StringComparison.Ordinal)
            ? AppSettings.FloatingStatsDoubleRowLayoutMode
            : AppSettings.FloatingStatsSingleRowLayoutMode;
        FloatingLayoutComboBox.SelectedItem = FloatingLayoutComboBox.Items
            .Cast<ComboBoxItem>()
            .FirstOrDefault(item => string.Equals(
                item.Tag as string,
                layoutMode,
                System.StringComparison.Ordinal))
            ?? FloatingLayoutComboBox.Items[0];
        FloatingTopmostCheckBox.IsChecked = settings.FloatingStatsTopmost;
        FloatingLockPositionCheckBox.IsChecked = settings.FloatingStatsPositionLocked;
        FloatingFontSizeComboBox.SelectedItem = settings.FloatingStatsFontSize;
    }

    private void FloatingMetric_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_isLoadingFloatingStats || sender is not ComboBox comboBox)
        {
            return;
        }

        var isPrimary = ReferenceEquals(comboBox, FloatingPrimaryMetricComboBox);
        if (comboBox.SelectedValue is not string metricId || string.IsNullOrWhiteSpace(metricId))
        {
            return;
        }

        if (!FloatingStatsViewModel.UpdateMetricSetting(isPrimary, metricId))
        {
            _isLoadingFloatingStats = true;
            RefreshFloatingStatsControls();
            _isLoadingFloatingStats = false;
            return;
        }

        App.CurrentApp?.TrackClick("settings_floating_stats_metric_change", new System.Collections.Generic.Dictionary<string, object?>
        {
            ["slot"] = isPrimary ? "primary" : "secondary",
            ["metric"] = metricId
        });
    }

    private void FloatingLayout_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_isLoadingFloatingStats || FloatingLayoutComboBox.SelectedItem is not ComboBoxItem selectedItem)
        {
            return;
        }

        if (selectedItem.Tag is not string layoutMode)
        {
            return;
        }

        if (!string.Equals(layoutMode, AppSettings.FloatingStatsSingleRowLayoutMode, System.StringComparison.Ordinal) &&
            !string.Equals(layoutMode, AppSettings.FloatingStatsDoubleRowLayoutMode, System.StringComparison.Ordinal))
        {
            return;
        }

        var settings = StatsManager.Instance.Settings;
        if (string.Equals(settings.FloatingStatsLayoutMode, layoutMode, System.StringComparison.Ordinal))
        {
            return;
        }

        settings.FloatingStatsLayoutMode = layoutMode;
        StatsManager.Instance.SaveSettings();
        App.CurrentApp?.ApplyFloatingStatsBehaviorSettings();
        App.CurrentApp?.TrackClick("settings_floating_stats_layout", new System.Collections.Generic.Dictionary<string, object?>
        {
            ["layout"] = layoutMode
        });
    }

    private void FloatingStatsBehavior_Changed(object sender, RoutedEventArgs e)
    {
        if (_isLoadingFloatingStats)
        {
            return;
        }

        var settings = StatsManager.Instance.Settings;
        settings.FloatingStatsTopmost = FloatingTopmostCheckBox.IsChecked == true;
        settings.FloatingStatsPositionLocked = FloatingLockPositionCheckBox.IsChecked == true;
        StatsManager.Instance.SaveSettings();
        App.CurrentApp?.ApplyFloatingStatsBehaviorSettings();

        var eventName = ReferenceEquals(sender, FloatingTopmostCheckBox)
            ? "settings_floating_stats_topmost"
            : "settings_floating_stats_position_lock";
        var enabled = sender is CheckBox checkBox && checkBox.IsChecked == true;
        App.CurrentApp?.TrackClick(eventName, new System.Collections.Generic.Dictionary<string, object?>
        {
            ["enabled"] = enabled
        });
    }

    private void FloatingFontSize_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_isLoadingFloatingStats || FloatingFontSizeComboBox.SelectedItem is not int fontSize)
        {
            return;
        }

        var settings = StatsManager.Instance.Settings;
        if (settings.FloatingStatsFontSize == fontSize)
        {
            return;
        }

        settings.FloatingStatsFontSize = fontSize;
        StatsManager.Instance.SaveSettings();
        App.CurrentApp?.ApplyFloatingStatsBehaviorSettings();
        App.CurrentApp?.TrackClick("settings_floating_stats_font_size", new System.Collections.Generic.Dictionary<string, object?>
        {
            ["font_size"] = fontSize
        });
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

    private sealed class FloatingMetricOption
    {
        public FloatingMetricOption(string id, string label)
        {
            Id = id;
            Label = label;
        }

        public string Id { get; }

        public string Label { get; }
    }
}
