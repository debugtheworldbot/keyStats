using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Shapes;
using KeyStats.Helpers;
using KeyStats.Models;
using KeyStats.Services;

namespace KeyStats.Views;

public partial class SyncSettingsWindow : Window
{
    private PairingSessionContext? _pairingContext;
    private bool _uiActionInFlight;
    private SyncCoordinator? Coordinator => App.CurrentApp?.SyncCoordinator;

    public SyncSettingsWindow()
    {
        InitializeComponent();
        SetupDeviceNameTextBox.Text = Environment.MachineName;
        Loaded += OnLoaded;
        Closed += OnClosed;
        ThemeManager.Instance.ThemeChanged += OnThemeChanged;
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        ApplyWindowBackdrop();
        if (Coordinator != null) Coordinator.StatusChanged += OnCoordinatorStatusChanged;
        RestorePendingPairingContext();
        App.CurrentApp?.TrackPageView("sync_settings");
        RefreshStatus();
    }

    private void OnClosed(object? sender, EventArgs e)
    {
        if (Coordinator != null) Coordinator.StatusChanged -= OnCoordinatorStatusChanged;
        ThemeManager.Instance.ThemeChanged -= OnThemeChanged;
    }

    private void OnThemeChanged() => Dispatcher.BeginInvoke(new Action(ApplyWindowBackdrop));

    private void ApplyWindowBackdrop()
        => WindowBackdropHelper.Apply(this, NativeInterop.DwmSystemBackdropType.TransientWindow);

    private void OnCoordinatorStatusChanged()
        => Dispatcher.BeginInvoke(new Action(RefreshStatus));

    private void RefreshStatus()
    {
        var coordinator = Coordinator;
        if (coordinator == null)
        {
            SetupPanel.Visibility = Visibility.Collapsed;
            EnabledPanel.Visibility = Visibility.Collapsed;
            RepairActionCard.Visibility = Visibility.Collapsed;
            SyncNowButton.Visibility = Visibility.Collapsed;
            SetStatus(
                "StatusNeutralBrush",
                KeyStats.Properties.Strings.Sync_StatusServiceNotConfigured,
                KeyStats.Properties.Strings.Sync_StatusServiceNotConfiguredDetail);
            return;
        }

        var status = coordinator.GetStatus();
        var pendingSetup = status.NeedsBootstrap && (!status.IsEnabled || status.NeedsRepair);
        IsEnabled = !_uiActionInFlight && !status.IsBusy;
        RefreshStatusCard(status);
        RepairActionCard.Visibility = status.IsServiceConfigured && (status.NeedsRepair || pendingSetup)
            ? Visibility.Visible
            : Visibility.Collapsed;
        SetupPanel.Visibility = status.IsServiceConfigured && (!status.IsEnabled || status.NeedsRepair) &&
                                !pendingSetup
            ? Visibility.Visible
            : Visibility.Collapsed;
        CreateVaultCard.Visibility = status.NeedsRepair ? Visibility.Collapsed : Visibility.Visible;
        EnabledPanel.Visibility = status.IsEnabled && !status.NeedsRepair
            ? Visibility.Visible
            : Visibility.Collapsed;

        if (status.IsEnabled && !status.NeedsRepair)
        {
            RebuildDeviceList(coordinator);
        }

        ErrorTextBlock.Text = status.LastError ?? string.Empty;
    }

    private void RefreshStatusCard(SyncStatusSnapshot status)
    {
        if (!status.IsServiceConfigured)
        {
            SetStatus(
                "StatusNeutralBrush",
                KeyStats.Properties.Strings.Sync_StatusServiceNotConfigured,
                KeyStats.Properties.Strings.Sync_StatusServiceNotConfiguredDetail);
        }
        else if (status.NeedsRepair)
        {
            SetStatus(
                "DangerBrush",
                KeyStats.Properties.Strings.Sync_StatusNeedsRepair,
                KeyStats.Properties.Strings.Sync_StatusNeedsRepairDetail);
        }
        else if (status.IsBusy)
        {
            SetStatus(
                "WarningBrush",
                KeyStats.Properties.Strings.Sync_InProgressStatus,
                BuildSyncingDetail(status));
        }
        else if (!string.IsNullOrWhiteSpace(status.LastError) &&
                 (status.CanRetryBootstrap || status.ActiveDeviceCount >= 2))
        {
            SetStatus(
                "DangerBrush",
                KeyStats.Properties.Strings.Sync_StatusFailed,
                status.LastError ?? string.Empty);
        }
        else if (!status.IsEnabled)
        {
            SetStatus(
                "StatusNeutralBrush",
                KeyStats.Properties.Strings.Sync_StatusOff,
                KeyStats.Properties.Strings.Sync_StatusOffDetail);
        }
        else if (status.ActiveDeviceCount < 2)
        {
            SetStatus(
                "StatusNeutralBrush",
                KeyStats.Properties.Strings.Sync_StatusSingleDevice,
                KeyStats.Properties.Strings.Sync_StatusSingleDeviceDetail);
        }
        else if (status.LastSuccessfulSyncAtUtc.HasValue)
        {
            SetStatus(
                "SuccessBrush",
                KeyStats.Properties.Strings.Sync_StatusOn,
                string.Format(
                    KeyStats.Properties.Strings.Sync_StatusLastSyncFormat,
                    status.LastSuccessfulSyncAtUtc.Value.ToLocalTime().ToString("g", CultureInfo.CurrentCulture)));
        }
        else
        {
            SetStatus(
                "StatusNeutralBrush",
                KeyStats.Properties.Strings.Sync_StatusOn,
                KeyStats.Properties.Strings.Sync_StatusNotYetSynced);
        }

        RefreshManualSyncButton(status);
    }

    private void SetStatus(string indicatorBrushKey, string heading, string detail)
    {
        StatusIndicatorEllipse.SetResourceReference(Ellipse.FillProperty, indicatorBrushKey);
        StatusHeadingTextBlock.Text = heading;
        StatusDetailTextBlock.Text = detail;
    }

    private static string BuildSyncingDetail(SyncStatusSnapshot status)
    {
        if (status.SyncTotalDays.GetValueOrDefault() > 0)
        {
            return string.Format(
                KeyStats.Properties.Strings.Sync_ProgressFormat,
                status.SyncCompletedDays.GetValueOrDefault(),
                status.SyncTotalDays.GetValueOrDefault());
        }

        return KeyStats.Properties.Strings.Sync_StatusSyncingDetail;
    }

    private void RefreshManualSyncButton(SyncStatusSnapshot status)
    {
        var shouldShow = status.IsServiceConfigured &&
                         ((status.IsEnabled && !status.NeedsRepair) || status.CanRetryBootstrap);
        SyncNowButton.Visibility = shouldShow ? Visibility.Visible : Visibility.Collapsed;
        SyncNowButton.IsEnabled = !_uiActionInFlight &&
                                  !status.IsBusy &&
                                  (status.CanManualSync || status.CanRetryBootstrap);

        if (status.CanRetryBootstrap)
        {
            SyncNowButton.Content = KeyStats.Properties.Strings.Sync_RetryBootstrapButton;
        }
        else if (status.CanSync &&
                 !status.CanManualSync &&
                 status.NextAllowedSyncAtUtc.HasValue &&
                 status.NextAllowedSyncAtUtc.Value > DateTime.UtcNow)
        {
            var remaining = status.NextAllowedSyncAtUtc.Value - DateTime.UtcNow;
            SyncNowButton.Content = string.Format(
                KeyStats.Properties.Strings.Sync_CooldownFormat,
                Math.Max(0, (int)Math.Ceiling(remaining.TotalMinutes)));
        }
        else
        {
            SyncNowButton.Content = KeyStats.Properties.Strings.Sync_NowButton;
        }
    }

    private void RestorePendingPairingContext()
    {
        try
        {
            _pairingContext = Coordinator?.GetPendingPairingContext();
            if (_pairingContext == null) return;
            PairingCodeTextBlock.Text = _pairingContext.Code;
            PairingCodeTextBlock.Visibility = Visibility.Visible;
            CompletePairingButton.Visibility = Visibility.Visible;
            CancelPairingButton.Visibility = Visibility.Visible;
        }
        catch (Exception ex)
        {
            ShowSafeError(ex);
        }
    }

    private void RebuildDeviceList(SyncCoordinator coordinator)
    {
        DevicesStackPanel.Children.Clear();
        foreach (var device in coordinator.GetDevices())
        {
            if (device.IsRevoked) continue;
            var row = new Grid { Margin = new Thickness(0, 2, 0, 2) };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var title = device.DisplayName;
            if (device.IsCurrent) title += " · " + KeyStats.Properties.Strings.Sync_ThisDevice;
            var label = new TextBlock
            {
                Text = title,
                VerticalAlignment = VerticalAlignment.Center,
                TextTrimming = TextTrimming.CharacterEllipsis
            };
            label.SetResourceReference(TextBlock.ForegroundProperty, "TextPrimaryBrush");
            row.Children.Add(label);
            if (!device.IsCurrent)
            {
                var revokeButton = new Button
                {
                    Content = KeyStats.Properties.Strings.Sync_RevokeButton,
                    Tag = device.DeviceId,
                    Margin = new Thickness(8, 0, 0, 0),
                    MinWidth = 68
                };
                revokeButton.Style = TryFindResource("DangerGhostButton") as Style;
                revokeButton.Click += RevokeDevice_Click;
                Grid.SetColumn(revokeButton, 1);
                row.Children.Add(revokeButton);
            }
            DevicesStackPanel.Children.Add(row);
        }
    }

    private async void CreateVault_Click(object sender, RoutedEventArgs e)
    {
        App.CurrentApp?.TrackClick("sync_create");
        await RunUiAction(async coordinator =>
        {
            var recoveryCode = await coordinator.CreateVaultAsync(SetupDeviceNameTextBox.Text);
            RecoveryCodeDisplayTextBox.Text = recoveryCode;
            RecoveryCodeDisplayTextBox.Visibility = Visibility.Visible;
            MessageBox.Show(this, recoveryCode, KeyStats.Properties.Strings.Sync_RecoveryCodeTitle,
                MessageBoxButton.OK, MessageBoxImage.Information);
        });
    }

    private async void Recover_Click(object sender, RoutedEventArgs e)
    {
        App.CurrentApp?.TrackClick("sync_recover");
        await RunUiAction(async coordinator =>
        {
            try
            {
                await coordinator.RecoverVaultAsync(
                    RecoveryCodeTextBox.Text,
                    SetupDeviceNameTextBox.Text);
            }
            catch (SyncTransportException ex) when (IsMaximumDevices(ex))
            {
                await CompleteCapacityLimitedRecoveryAsync(coordinator, ex);
            }
        });
    }

    private async void BeginPairing_Click(object sender, RoutedEventArgs e)
    {
        App.CurrentApp?.TrackClick("sync_pair_start");
        await RunUiAction(async coordinator =>
        {
            _pairingContext = await coordinator.BeginPairingAsync(SetupDeviceNameTextBox.Text);
            PairingCodeTextBlock.Text = _pairingContext.Code;
            PairingCodeTextBlock.Visibility = Visibility.Visible;
            CompletePairingButton.Visibility = Visibility.Visible;
            CancelPairingButton.Visibility = Visibility.Visible;
        });
    }

    private async void CompletePairing_Click(object sender, RoutedEventArgs e)
    {
        if (_pairingContext == null) return;
        App.CurrentApp?.TrackClick("sync_pair_complete");
        await RunUiAction(async coordinator =>
        {
            var preview = await coordinator.PreviewPairingCompletionAsync(_pairingContext);
            var confirmed = MessageBox.Show(
                this,
                string.Format(KeyStats.Properties.Strings.Sync_SafetyCodeConfirmFormat, preview.SafetyCode),
                KeyStats.Properties.Strings.Sync_SafetyCodeTitle,
                MessageBoxButton.OKCancel,
                MessageBoxImage.Information);
            if (confirmed != MessageBoxResult.OK) return;
            await coordinator.CompletePairingAsync(preview, SetupDeviceNameTextBox.Text);
            _pairingContext = null;
            CancelPairingButton.Visibility = Visibility.Collapsed;
        });
    }

    private async void ApprovePairing_Click(object sender, RoutedEventArgs e)
    {
        App.CurrentApp?.TrackClick("sync_pair_approve");
        await RunUiAction(async coordinator =>
        {
            var approval = await coordinator.JoinPairingAsync(ApproveCodeTextBox.Text);
            var confirmed = MessageBox.Show(
                this,
                string.Format(KeyStats.Properties.Strings.Sync_SafetyCodeConfirmFormat, approval.SafetyCode),
                KeyStats.Properties.Strings.Sync_SafetyCodeTitle,
                MessageBoxButton.OKCancel,
                MessageBoxImage.Information);
            if (confirmed == MessageBoxResult.OK)
            {
                await coordinator.ApprovePairingAsync(approval);
                MessageBox.Show(this, KeyStats.Properties.Strings.Sync_ApprovalComplete,
                    KeyStats.Properties.Strings.Sync_WindowTitle, MessageBoxButton.OK, MessageBoxImage.Information);
            }
        });
    }

    private async void SyncNow_Click(object sender, RoutedEventArgs e)
    {
        var retryBootstrap = Coordinator?.GetStatus().CanRetryBootstrap == true;
        App.CurrentApp?.TrackClick(retryBootstrap ? "sync_bootstrap_retry" : "sync_manual");
        await RunUiAction(async coordinator =>
        {
            try
            {
                if (retryBootstrap) await coordinator.RetryBootstrapAsync();
                else await coordinator.SyncNowAsync();
            }
            catch (SyncTransportException ex) when (IsMaximumDevices(ex))
            {
                await CompleteCapacityLimitedRecoveryAsync(coordinator, ex);
            }
        });
    }

    private void ShowRecoveryCode_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            RecoveryCodeDisplayTextBox.Text = Coordinator?.GetRecoveryCode() ?? string.Empty;
            RecoveryCodeDisplayTextBox.Visibility = Visibility.Visible;
        }
        catch (Exception ex)
        {
            ShowSafeError(ex);
        }
    }

    private async void LeaveSync_Click(object sender, RoutedEventArgs e)
    {
        var confirmed = MessageBox.Show(this, KeyStats.Properties.Strings.Sync_LeaveConfirm,
            KeyStats.Properties.Strings.Sync_WindowTitle, MessageBoxButton.OKCancel, MessageBoxImage.Warning);
        if (confirmed != MessageBoxResult.OK) return;
        App.CurrentApp?.TrackClick("sync_leave");
        await RunUiAction(coordinator => coordinator.LeaveSyncAsync());
    }

    private async void ClearRepair_Click(object sender, RoutedEventArgs e)
    {
        var confirmed = MessageBox.Show(this, KeyStats.Properties.Strings.Sync_ClearRepairConfirm,
            KeyStats.Properties.Strings.Sync_WindowTitle, MessageBoxButton.OKCancel, MessageBoxImage.Warning);
        if (confirmed != MessageBoxResult.OK) return;
        App.CurrentApp?.TrackClick("sync_forget_local");
        await RunUiAction(async coordinator =>
        {
            await coordinator.ClearLocalSyncConfigurationAsync();
            _pairingContext = null;
            PairingCodeTextBlock.Visibility = Visibility.Collapsed;
            CompletePairingButton.Visibility = Visibility.Collapsed;
            CancelPairingButton.Visibility = Visibility.Collapsed;
        });
    }

    private async void DeleteVault_Click(object sender, RoutedEventArgs e)
    {
        var confirmed = MessageBox.Show(this, KeyStats.Properties.Strings.Sync_DeleteVaultConfirm,
            KeyStats.Properties.Strings.Sync_WindowTitle, MessageBoxButton.OKCancel, MessageBoxImage.Warning);
        if (confirmed != MessageBoxResult.OK) return;
        App.CurrentApp?.TrackClick("sync_delete");
        await RunUiAction(coordinator => coordinator.DeleteVaultAsync());
    }

    private async void RevokeDevice_Click(object sender, RoutedEventArgs e)
    {
        if ((sender as Button)?.Tag is not string deviceId || string.IsNullOrWhiteSpace(deviceId)) return;
        var device = Coordinator?.GetDevices().FirstOrDefault(item =>
            string.Equals(item.DeviceId, deviceId, StringComparison.Ordinal));
        var confirmed = MessageBox.Show(
            this,
            string.Format(KeyStats.Properties.Strings.Sync_RevokeConfirmFormat, device?.DisplayName ?? deviceId),
            KeyStats.Properties.Strings.Sync_WindowTitle,
            MessageBoxButton.OKCancel,
            MessageBoxImage.Warning);
        if (confirmed != MessageBoxResult.OK) return;
        App.CurrentApp?.TrackClick("sync_revoke");
        await RunUiAction(coordinator => coordinator.RevokeDeviceAsync(deviceId));
    }

    private async Task RunUiAction(Func<SyncCoordinator, Task> action)
    {
        var coordinator = Coordinator;
        if (coordinator == null || _uiActionInFlight) return;
        _uiActionInFlight = true;
        IsEnabled = false;
        ErrorTextBlock.Text = string.Empty;
        try
        {
            await action(coordinator);
        }
        catch (Exception ex)
        {
            ShowSafeError(ex);
        }
        finally
        {
            _uiActionInFlight = false;
            RefreshStatus();
        }
    }

    private async Task CompleteCapacityLimitedRecoveryAsync(
        SyncCoordinator coordinator,
        SyncTransportException exception)
    {
        var options = coordinator.GetRecoveryReplacementOptions(exception);
        var selected = PromptForRecoveryReplacement(options);
        if (selected == null) return;
        await coordinator.RetryRecoveryReplacingAsync(selected, exception.VaultId!);
    }

    private RecoveryReplacementOption? PromptForRecoveryReplacement(
        IReadOnlyList<RecoveryReplacementOption> options)
    {
        if (options.Count == 0) return null;
        var selector = new ComboBox { MinWidth = 360, Margin = new Thickness(0, 12, 0, 16) };
        foreach (var option in options)
        {
            var suffix = string.IsNullOrWhiteSpace(option.Platform)
                ? string.Empty
                : " · " + option.Platform;
            selector.Items.Add(new ComboBoxItem
            {
                Content = option.DisplayName + suffix,
                Tag = option
            });
        }
        selector.SelectedIndex = 0;

        var confirmButton = new Button
        {
            Content = KeyStats.Properties.Strings.Sync_RecoveryReplaceConfirm,
            MinWidth = 100,
            Margin = new Thickness(0, 0, 8, 0)
        };
        var cancelButton = new Button
        {
            Content = KeyStats.Properties.Strings.Common_Cancel,
            MinWidth = 80
        };
        var buttons = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Right
        };
        buttons.Children.Add(confirmButton);
        buttons.Children.Add(cancelButton);
        var content = new StackPanel { Margin = new Thickness(20) };
        content.Children.Add(new TextBlock
        {
            Text = KeyStats.Properties.Strings.Sync_RecoveryReplaceMessage,
            TextWrapping = TextWrapping.Wrap,
            MaxWidth = 420
        });
        content.Children.Add(selector);
        content.Children.Add(buttons);

        var dialog = new Window
        {
            Owner = this,
            Title = KeyStats.Properties.Strings.Sync_RecoveryReplaceTitle,
            Content = content,
            SizeToContent = SizeToContent.WidthAndHeight,
            MinWidth = 440,
            ResizeMode = ResizeMode.NoResize,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
            ShowInTaskbar = false,
            Background = TryFindResource("WindowSurfaceBrush") as System.Windows.Media.Brush
                         ?? this.Background
        };
        confirmButton.Click += (_, _) => dialog.DialogResult = true;
        cancelButton.Click += (_, _) => dialog.DialogResult = false;
        var accepted = dialog.ShowDialog() == true;
        return accepted && selector.SelectedItem is ComboBoxItem { Tag: RecoveryReplacementOption selected }
            ? selected
            : null;
    }

    private static bool IsMaximumDevices(SyncTransportException exception)
        => exception.StatusCode == System.Net.HttpStatusCode.Conflict &&
           string.Equals(exception.ErrorCode, "maximum_devices", StringComparison.Ordinal);

    private void ShowSafeError(Exception exception)
    {
        var message = exception is SyncRateLimitedException
            ? exception.Message
            : KeyStats.Properties.Strings.Sync_GenericError;
        ErrorTextBlock.Text = message;
        MessageBox.Show(this, message, KeyStats.Properties.Strings.Sync_WindowTitle,
            MessageBoxButton.OK, MessageBoxImage.Warning);
    }
}
