using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using KeyStats.Models;

namespace KeyStats.Services;

public sealed class SyncCoordinator : IDisposable
{
    private static readonly TimeSpan[] PairingRefreshRetryDelays =
    {
        TimeSpan.FromSeconds(5),
        TimeSpan.FromSeconds(10),
        TimeSpan.FromSeconds(20),
        TimeSpan.FromSeconds(40),
        TimeSpan.FromSeconds(60)
    };
    private static readonly TimeSpan StateRefreshInterval = TimeSpan.FromHours(24);
#if DEBUG
    private const bool ManualSyncBypassesClientRateLimit = true;
#else
    private const bool ManualSyncBypassesClientRateLimit = false;
#endif

    private readonly StatsManager _statsManager;
    private readonly SyncStateStore _stateStore;
    private readonly SyncCredentialStore _credentialStore;
    private readonly SyncPendingSecretsStore _pendingSecretsStore;
    private readonly RemoteShardCache _remoteCache;
    private readonly DisplayStatsAggregator _displayAggregator;
    private readonly SyncCrypto _crypto;
    private readonly ISyncTransport? _transport;
    private readonly bool _ownsTransport;
    private readonly string _clientVersion;
    private readonly SemaphoreSlim _operationGate = new(1, 1);
    private readonly object _stateLock = new();
    private readonly CancellationTokenSource _lifetimeCancellation = new();
    private readonly JsonSerializerOptions _wireJsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true
    };
    private Timer? _automaticTimer;
    private Timer? _stateRefreshTimer;
    private SyncState _state;
    private bool _isBusy;
    private SyncProgress? _syncProgress;
    private string? _lastError;
    private bool _disposed;

    public event Action? StatusChanged;

    public bool IsEnabled
    {
        get { lock (_stateLock) return _state.IsEnabled && !_state.NeedsRepair; }
    }

    public bool BlocksImport
    {
        get
        {
            lock (_stateLock)
            {
                return _state.IsEnabled || _state.NeedsRepair ||
                       !string.IsNullOrWhiteSpace(_state.PendingProvisioningKind);
            }
        }
    }

    public bool IsServiceConfigured => _transport != null;

    public SyncCoordinator(
        StatsManager statsManager,
        string dataFolder,
        Uri? serviceBaseUri,
        string clientVersion,
        ISyncTransport? transport = null)
    {
        _statsManager = statsManager;
        _stateStore = new SyncStateStore(dataFolder);
        _credentialStore = new SyncCredentialStore(dataFolder);
        _pendingSecretsStore = new SyncPendingSecretsStore(dataFolder);
        _remoteCache = new RemoteShardCache(dataFolder);
        _crypto = new SyncCrypto();
        _clientVersion = clientVersion;
        _state = _stateStore.Load();
        if (string.IsNullOrWhiteSpace(_state.InstallationDeviceId))
        {
            _state.InstallationDeviceId = Guid.TryParse(_state.DeviceId, out _)
                ? _state.DeviceId
                : Guid.NewGuid().ToString("D");
            if (!_stateStore.NeedsRepair) _stateStore.Save(_state);
        }
        _transport = transport ?? (serviceBaseUri != null ? new CloudflareSyncTransport(serviceBaseUri) : null);
        _ownsTransport = transport == null && _transport != null;
        _displayAggregator = new DisplayStatsAggregator(_remoteCache, () =>
        {
            lock (_stateLock) return _state.DeviceId;
        });

        var credentialsNeedRepair = false;
        var hasPendingProvisioning = !string.IsNullOrWhiteSpace(_state.PendingProvisioningKind);
        if (string.Equals(_state.PendingProvisioningKind, "pairing", StringComparison.Ordinal) &&
            _pendingSecretsStore.Exists)
        {
            try
            {
                var pending = _pendingSecretsStore.Load();
                if (string.Equals(pending.Kind, "pairing-final", StringComparison.Ordinal) &&
                    string.Equals(pending.DeviceId, _state.InstallationDeviceId, StringComparison.Ordinal) &&
                    _state.PendingEncryptedDeviceProfile != null)
                {
                    // The final secret bundle is written before the non-secret state marker.
                    // Reconcile a crash in that narrow window so startup can replay the exact
                    // completion request without asking the user to pair again.
                    _state.PendingProvisioningKind = "pairing-final";
                    _stateStore.Save(_state);
                }
            }
            catch (CryptographicException)
            {
                credentialsNeedRepair = true;
            }
        }
        hasPendingProvisioning = !string.IsNullOrWhiteSpace(_state.PendingProvisioningKind);
        if (_state.IsEnabled)
        {
            if (!_credentialStore.Exists)
            {
                credentialsNeedRepair = !string.Equals(
                    _state.PendingProvisioningKind,
                    "recover",
                    StringComparison.Ordinal);
            }
            else
            {
                try { _credentialStore.Load(_state.VaultId, _state.DeviceId); }
                catch (CryptographicException) { credentialsNeedRepair = true; }
            }
        }
        else if (_credentialStore.Exists && !hasPendingProvisioning)
        {
            credentialsNeedRepair = true;
        }

        if (hasPendingProvisioning && !_pendingSecretsStore.Exists)
        {
            credentialsNeedRepair = true;
        }
        else if (!hasPendingProvisioning && _pendingSecretsStore.Exists)
        {
            var stalePendingRemoved = false;
            if (_state.IsEnabled && _credentialStore.Exists)
            {
                try
                {
                    var pending = _pendingSecretsStore.Load();
                    var active = _credentialStore.Load(_state.VaultId, _state.DeviceId);
                    stalePendingRemoved =
                        string.Equals(pending.VaultId, active.VaultId, StringComparison.Ordinal) &&
                        string.Equals(pending.DeviceId, active.DeviceId, StringComparison.Ordinal) &&
                        string.Equals(pending.DeviceToken, active.DeviceToken, StringComparison.Ordinal);
                    if (stalePendingRemoved) _pendingSecretsStore.Delete();
                }
                catch (CryptographicException)
                {
                }
            }
            if (!stalePendingRemoved) credentialsNeedRepair = true;
        }

        if (_stateStore.NeedsRepair || _state.NeedsRepair || credentialsNeedRepair)
        {
            _state.NeedsRepair = true;
            _lastError = "The local sync configuration needs repair.";
            if (credentialsNeedRepair && !_stateStore.NeedsRepair)
            {
                _stateStore.Save(_state);
            }
        }

        if (_remoteCache.RecoveredFromBackup && _state.IsEnabled && !_state.NeedsRepair)
        {
            _state.HistoryCursor = 0;
            _state.NeedsHistoryBootstrap = true;
            _stateStore.Save(_state);
        }

        if (_remoteCache.NeedsRepair && _state.IsEnabled && !_state.NeedsRepair)
        {
            _state.NeedsRepair = true;
            _state.NeedsBootstrap = false;
            _state.NeedsHistoryBootstrap = false;
            _lastError = "The local sync cache is damaged. Recover or pair this device again.";
            _stateStore.Save(_state);
        }

        _remoteCache.Changed += OnRemoteCacheChanged;
        _statsManager.LocalStatsReset += OnLocalStatsReset;
        _statsManager.ConfigureSyncDisplay(_displayAggregator, () => IsEnabled, () => BlocksImport);
    }

    public void Start()
    {
        var retryBootstrap = false;
        var retryProvisioning = false;
        var retryDeletion = false;
        lock (_stateLock)
        {
            if (_disposed || _transport == null) return;
            retryDeletion = _state.PendingVaultDeletion;
            retryProvisioning = IsRetryableProvisioningKind(_state.PendingProvisioningKind);
            if (!retryDeletion && !retryProvisioning &&
                (!_state.IsEnabled || _state.NeedsRepair))
            {
                return;
            }
            if (!retryDeletion && !retryProvisioning)
            {
                retryBootstrap = _state.NeedsBootstrap || _state.NeedsHistoryBootstrap ||
                                 _state.NeedsStateRefreshBeforeBootstrap;
                if (!retryBootstrap)
                {
                    if (_state.ActiveDeviceCount < 2)
                    {
                        ScheduleStateRefreshLocked(DateTime.UtcNow);
                        return;
                    }
                    EnsureAutomaticAttemptLocked(DateTime.UtcNow);
                    ScheduleAutomaticTimerLocked(DateTime.UtcNow);
                }
            }
        }
        RaiseStatusChanged();
        if (retryDeletion) RunVaultDeletionInBackground();
        else if (retryProvisioning) RunPendingProvisioningInBackground();
        else if (retryBootstrap) RunBootstrapInBackground();
    }

    public void HandleAppResume()
    {
        var shouldRun = false;
        var shouldRefreshState = false;
        lock (_stateLock)
        {
            if (_disposed || _transport == null || !_state.IsEnabled || _state.NeedsRepair ||
                _state.NeedsBootstrap || _state.NeedsHistoryBootstrap ||
                _state.NeedsStateRefreshBeforeBootstrap || _state.PendingVaultDeletion) return;
            if (_state.ActiveDeviceCount < 2)
            {
                var refreshBase = _state.LastStateRefreshAtUtc ??
                                  _state.LastSuccessfulSyncAtUtc ??
                                  DateTime.UtcNow;
                var dueAt = refreshBase + StateRefreshInterval;
                shouldRefreshState = dueAt <= DateTime.UtcNow;
                if (!shouldRefreshState) ScheduleStateRefreshLocked(DateTime.UtcNow);
            }
            else
            {
                EnsureAutomaticAttemptLocked(DateTime.UtcNow);
                shouldRun = _state.NextAutomaticSyncAtUtc.HasValue &&
                            _state.NextAutomaticSyncAtUtc.Value <= DateTime.UtcNow;
                if (!shouldRun) ScheduleAutomaticTimerLocked(DateTime.UtcNow);
            }
        }

        if (shouldRefreshState) RunStateRefreshInBackground();
        else if (shouldRun) RunAutomaticSyncInBackground();
    }

    private async Task RefreshStateAsync(
        bool rebuildOwnRevisionState,
        CancellationToken cancellationToken = default)
    {
        var transport = RequireTransport();
        await _operationGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        SetBusy(true);
        try
        {
            lock (_stateLock) EnsureEnabledLocked();
            var credentials = RequireCredentials();
            var response = await transport.GetStateAsync(credentials.DeviceToken, cancellationToken)
                .ConfigureAwait(false);
            if (response.ServerTime == default || response.ActiveDeviceCount < 1 ||
                response.ActiveDeviceCount > SyncProtocol.MaximumDevices ||
                response.Devices == null || response.CurrentSnapshots == null)
            {
                throw new InvalidDataException("Sync service returned invalid device state.");
            }
            var dataKey = _crypto.DeriveDataKey(credentials.VaultSeed);
            var indexKey = _crypto.DeriveIndexKey(credentials.VaultSeed);
            foreach (var record in response.CurrentSnapshots)
            {
                var decrypted = DecryptAndValidate(record, isCurrent: true, dataKey, indexKey);
                if (IsLocalDevice(record.DeviceId))
                {
                    if (rebuildOwnRevisionState)
                    {
                        lock (_stateLock) RestoreOwnDecryptedRecordLocked(record, decrypted, isCurrent: true);
                    }
                }
                else
                {
                    _remoteCache.Apply(decrypted);
                }
            }
            RefreshDevices(response.Devices, credentials);
            lock (_stateLock)
            {
                _state.ActiveDeviceCount = response.ActiveDeviceCount;
                _state.LastStateRefreshAtUtc = NormalizeUtc(response.ServerTime);
                _lastError = null;
                if (_state.NeedsStateRefreshBeforeBootstrap || _state.NeedsHistoryBootstrap ||
                    _state.NeedsBootstrap)
                {
                    _automaticTimer?.Change(Timeout.Infinite, Timeout.Infinite);
                    _stateRefreshTimer?.Change(Timeout.Infinite, Timeout.Infinite);
                }
                else if (_state.ActiveDeviceCount < 2)
                {
                    _state.NextAutomaticSyncAtUtc = null;
                    _automaticTimer?.Change(Timeout.Infinite, Timeout.Infinite);
                    ScheduleStateRefreshLocked(DateTime.UtcNow);
                }
                else
                {
                    _stateRefreshTimer?.Change(Timeout.Infinite, Timeout.Infinite);
                    EnsureAutomaticAttemptLocked(DateTime.UtcNow);
                    ScheduleAutomaticTimerLocked(DateTime.UtcNow);
                }
                _stateStore.Save(_state);
            }
            RaiseStatusChanged();
        }
        catch (Exception ex)
        {
            lock (_stateLock)
            {
                _lastError = SafeErrorMessage(ex);
                _state.LastStateRefreshAtUtc = DateTime.UtcNow;
                if (_state.ActiveDeviceCount < 2) ScheduleStateRefreshLocked(DateTime.UtcNow);
                _stateStore.Save(_state);
            }
            RaiseStatusChanged();
            throw;
        }
        finally
        {
            SetBusy(false);
            _operationGate.Release();
        }
    }

    public SyncStatusSnapshot GetStatus()
    {
        lock (_stateLock)
        {
            var now = DateTime.UtcNow;
            RefreshUtcDayWindowsLocked(now);
            var allowedAt = GetEffectiveAllowedAtLocked();
            var hasProvisioningWork = IsRetryableProvisioningKind(_state.PendingProvisioningKind);
            var hasPendingDeletion = _state.PendingVaultDeletion;
            var hasBootstrapWork = _state.NeedsBootstrap || _state.NeedsHistoryBootstrap ||
                                   _state.NeedsStateRefreshBeforeBootstrap || hasProvisioningWork ||
                                   hasPendingDeletion;
            var canSync = _state.IsEnabled && !_state.NeedsRepair && !hasBootstrapWork &&
                          _state.ActiveDeviceCount >= 2;
            var canRetryBootstrap = IsServiceConfigured && !_isBusy &&
                                    (hasProvisioningWork || hasPendingDeletion ||
                                     (_state.IsEnabled && !_state.NeedsRepair &&
                                      (_state.NeedsBootstrap || _state.NeedsHistoryBootstrap ||
                                       _state.NeedsStateRefreshBeforeBootstrap)));
            return new SyncStatusSnapshot
            {
                IsServiceConfigured = IsServiceConfigured,
                IsEnabled = _state.IsEnabled,
                NeedsRepair = _state.NeedsRepair,
                NeedsBootstrap = hasBootstrapWork,
                BlocksImport = _state.IsEnabled || _state.NeedsRepair ||
                               !string.IsNullOrWhiteSpace(_state.PendingProvisioningKind),
                IsBusy = _isBusy,
                CanSync = canSync,
                CanManualSync = IsServiceConfigured && canSync && !_isBusy &&
                                (ManualSyncBypassesClientRateLimit ||
                                 (_state.RemainingDailySyncs > 0 && now >= allowedAt)),
                CanRetryBootstrap = canRetryBootstrap,
                ActiveDeviceCount = _state.ActiveDeviceCount,
                LastSuccessfulSyncAtUtc = _state.LastSuccessfulSyncAtUtc,
                NextAllowedSyncAtUtc = allowedAt,
                RemainingDailySyncs = _state.RemainingDailySyncs,
                SyncCompletedDays = _syncProgress?.CompletedDays,
                SyncTotalDays = _syncProgress?.TotalDays,
                LastError = _lastError
            };
        }
    }

    public string GetRecoveryCode()
    {
        lock (_stateLock)
        {
            if (!_state.IsEnabled && !_state.NeedsRepair)
            {
                throw new InvalidOperationException("Sync is not configured on this device.");
            }
        }
        return _crypto.EncodeRecoveryCode(RequireCredentials().VaultSeed);
    }

    public string GetCurrentDeviceName()
    {
        lock (_stateLock) return _state.DeviceName;
    }

    public IReadOnlyList<SyncDeviceInfo> GetDevices()
    {
        lock (_stateLock)
        {
            return _state.Devices.Select(CloneDevice).ToList();
        }
    }

    public async Task<string> CreateVaultAsync(string displayName, CancellationToken cancellationToken = default)
    {
        var transport = RequireTransport();
        string recoveryCode;
        await _operationGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        SetBusy(true);
        try
        {
            PendingSyncSecrets pending;
            PairingEncryptedPayload profile;
            string effectiveDisplayName;
            lock (_stateLock)
            {
                if (!string.IsNullOrWhiteSpace(_state.PendingProvisioningKind) &&
                    !string.Equals(_state.PendingProvisioningKind, "create", StringComparison.Ordinal))
                {
                    throw new InvalidOperationException("Another sync setup operation is already pending.");
                }
            }
            if (_pendingSecretsStore.Exists)
            {
                pending = _pendingSecretsStore.Load();
                lock (_stateLock)
                {
                    if (!string.Equals(_state.PendingProvisioningKind, "create", StringComparison.Ordinal) ||
                        !string.Equals(pending.Kind, "create", StringComparison.Ordinal) ||
                        _state.PendingEncryptedDeviceProfile == null)
                    {
                        throw new CryptographicException("Pending vault creation state is inconsistent.");
                    }
                    profile = _state.PendingEncryptedDeviceProfile;
                    effectiveDisplayName = _state.PendingProvisioningDisplayName ?? displayName;
                }
            }
            else
            {
                EnsureCanCreate();
                var seed = _crypto.GenerateVaultSeed();
                var vaultId = Guid.NewGuid().ToString("D");
                string deviceId;
                lock (_stateLock) deviceId = _state.InstallationDeviceId;
                var deviceToken = deviceId + "." + _crypto.GenerateTokenSecret();
                profile = CreateEncryptedDeviceProfile(seed, vaultId, deviceId, displayName);
                pending = new PendingSyncSecrets
                {
                    Kind = "create",
                    VaultId = vaultId,
                    DeviceId = deviceId,
                    VaultSeed = seed,
                    DeviceToken = deviceToken
                };
                _pendingSecretsStore.Save(pending);
                lock (_stateLock)
                {
                    _state.PendingProvisioningKind = "create";
                    _state.PendingProvisioningDisplayName = NormalizeProfileValue(displayName, 128);
                    _state.PendingEncryptedDeviceProfile = profile;
                    _stateStore.Save(_state);
                    effectiveDisplayName = _state.PendingProvisioningDisplayName;
                }
            }

            var response = await transport.CreateVaultAsync(new CreateVaultRequest
            {
                VaultId = pending.VaultId,
                DeviceId = pending.DeviceId,
                DeviceToken = pending.DeviceToken,
                RecoveryAuthToken = SyncCrypto.Base64UrlEncode(_crypto.DeriveRecoveryAuth(pending.VaultSeed)),
                EncryptedDeviceProfile = profile
            }, cancellationToken).ConfigureAwait(false);

            if (!string.Equals(response.VaultId, pending.VaultId, StringComparison.Ordinal) ||
                !string.Equals(response.DeviceId, pending.DeviceId, StringComparison.Ordinal) ||
                !string.Equals(response.DeviceToken, pending.DeviceToken, StringComparison.Ordinal) ||
                response.ActiveDeviceCount < 1 || response.ActiveDeviceCount > SyncProtocol.MaximumDevices)
            {
                throw new InvalidDataException("Sync service returned inconsistent vault credentials.");
            }

            _credentialStore.Save(new SyncCredentials
            {
                VaultId = pending.VaultId,
                DeviceId = pending.DeviceId,
                VaultSeed = pending.VaultSeed,
                DeviceToken = pending.DeviceToken
            });
            lock (_stateLock)
            {
                _state = NewEnabledState(
                    pending.VaultId,
                    pending.DeviceId,
                    effectiveDisplayName,
                    response.ActiveDeviceCount);
                _lastError = null;
                _stateStore.Save(_state);
            }
            _pendingSecretsStore.Delete();
            _remoteCache.Clear();
            RaiseStatusChanged();
            recoveryCode = _crypto.EncodeRecoveryCode(pending.VaultSeed);
        }
        finally
        {
            SetBusy(false);
            _operationGate.Release();
        }

        try
        {
            await SyncCoreAsync("bootstrap", bypassClientRateLimit: true, cancellationToken).ConfigureAwait(false);
        }
        catch (Exception)
        {
            // The vault and its recovery credentials are already durable. Keep the
            // pending bootstrap state so startup or the explicit retry action can
            // resend the exact same encrypted envelopes.
        }
        return recoveryCode;
    }

    public async Task RecoverVaultAsync(
        string recoveryCode,
        string displayName,
        CancellationToken cancellationToken = default)
    {
        var transport = RequireTransport();
        if (!_crypto.TryDecodeRecoveryCode(recoveryCode, out var seed))
        {
            throw new ArgumentException("Recovery code is invalid.", nameof(recoveryCode));
        }

        await _operationGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        SetBusy(true);
        try
        {
            PrepareDamagedStateForSetup();
            PendingSyncSecrets pending;
            string? replaceDeviceId;
            string effectiveDisplayName;
            lock (_stateLock)
            {
                if (!string.IsNullOrWhiteSpace(_state.PendingProvisioningKind) &&
                    !string.Equals(_state.PendingProvisioningKind, "recover", StringComparison.Ordinal))
                {
                    throw new InvalidOperationException("Another sync setup operation is already pending.");
                }
            }
            if (_pendingSecretsStore.Exists)
            {
                pending = _pendingSecretsStore.Load();
                lock (_stateLock)
                {
                    if (!string.Equals(pending.Kind, "recover", StringComparison.Ordinal) ||
                        !string.Equals(_state.PendingProvisioningKind, "recover", StringComparison.Ordinal))
                    {
                        throw new CryptographicException("Pending recovery state is inconsistent.");
                    }
                    replaceDeviceId = pending.ReplaceDeviceId;
                    effectiveDisplayName = _state.PendingProvisioningDisplayName ?? displayName;
                }
                if (!pending.VaultSeed.SequenceEqual(seed))
                {
                    throw new CryptographicException("The recovery code does not match the pending recovery.");
                }
            }
            else
            {
                EnsureNotEnabled();
                string deviceId;
                string previousVaultId;
                lock (_stateLock)
                {
                    var replacementCandidate = Guid.TryParse(_state.ReplacementCandidateDeviceId, out _)
                        ? _state.ReplacementCandidateDeviceId
                        : null;
                    deviceId = replacementCandidate ?? _state.InstallationDeviceId;
                    previousVaultId = _state.VaultId;
                    replaceDeviceId = _state.IsEnabled && !string.IsNullOrWhiteSpace(_state.DeviceId)
                        ? _state.DeviceId
                        : replacementCandidate;
                }
                pending = new PendingSyncSecrets
                {
                    Kind = "recover",
                    VaultId = previousVaultId,
                    DeviceId = deviceId,
                    VaultSeed = seed,
                    DeviceToken = deviceId + "." + _crypto.GenerateTokenSecret(),
                    ReplaceDeviceId = replaceDeviceId
                };
                _pendingSecretsStore.Save(pending);
                lock (_stateLock)
                {
                    _state.PendingProvisioningKind = "recover";
                    _state.PendingProvisioningDisplayName = NormalizeProfileValue(displayName, 128);
                    _state.PendingProvisioningReplaceDeviceId = replaceDeviceId;
                    _stateStore.Save(_state);
                    effectiveDisplayName = _state.PendingProvisioningDisplayName;
                }
            }

            var recoveryAuthToken = SyncCrypto.Base64UrlEncode(
                _crypto.DeriveRecoveryAuth(pending.VaultSeed));
            RecoverVaultResponse response;
            try
            {
                response = await transport.RecoverVaultAsync(
                    CreateRecoverRequest(pending, replaceDeviceId, recoveryAuthToken),
                    cancellationToken).ConfigureAwait(false);
            }
            catch (SyncTransportException ex) when (
                replaceDeviceId != null &&
                ex.StatusCode == HttpStatusCode.Conflict &&
                string.Equals(ex.ErrorCode, "replace_device_not_found", StringComparison.Ordinal))
            {
                // A repair candidate can belong to an old or deleted vault. Only
                // this explicit response is safe to downgrade to a fresh shard;
                // generic conflicts may mean a concurrent recovery and must not
                // create a duplicate device.
                var freshDeviceId = Guid.NewGuid().ToString("D");
                pending.VaultId = string.Empty;
                pending.DeviceId = freshDeviceId;
                pending.DeviceToken = freshDeviceId + "." + _crypto.GenerateTokenSecret();
                pending.ReplaceDeviceId = null;
                _pendingSecretsStore.Save(pending);
                replaceDeviceId = null;
                lock (_stateLock)
                {
                    _state.InstallationDeviceId = freshDeviceId;
                    _state.ReplacementCandidateDeviceId = null;
                    _state.DeviceId = freshDeviceId;
                    _state.PendingProvisioningReplaceDeviceId = null;
                    _state.HistoryCursor = 0;
                    _state.LocalRecords.Clear();
                    _state.LastAcknowledgedCurrentSnapshot = null;
                    _state.PendingEncryptedDeviceProfile = null;
                    _stateStore.Save(_state);
                }
                response = await transport.RecoverVaultAsync(
                    CreateRecoverRequest(pending, replaceDeviceId, recoveryAuthToken),
                    cancellationToken).ConfigureAwait(false);
            }

            if (string.IsNullOrWhiteSpace(response.VaultId) ||
                !string.Equals(response.DeviceId, pending.DeviceId, StringComparison.Ordinal) ||
                !string.Equals(response.DeviceToken, pending.DeviceToken, StringComparison.Ordinal) ||
                response.ActiveDeviceCount < 1 || response.ActiveDeviceCount > SyncProtocol.MaximumDevices ||
                response.Cursor != 0)
            {
                throw new InvalidDataException("Sync service returned incomplete recovery credentials.");
            }

            pending.VaultId = response.VaultId;
            _pendingSecretsStore.Save(pending);
            var encryptedProfile = CreateEncryptedDeviceProfile(
                pending.VaultSeed,
                response.VaultId,
                pending.DeviceId,
                effectiveDisplayName);
            _credentialStore.Save(new SyncCredentials
            {
                VaultId = response.VaultId,
                DeviceId = pending.DeviceId,
                VaultSeed = pending.VaultSeed,
                DeviceToken = pending.DeviceToken
            });
            lock (_stateLock)
            {
                var canPreserveRevisionState =
                    string.Equals(_state.VaultId, response.VaultId, StringComparison.Ordinal) &&
                    string.Equals(_state.DeviceId, pending.DeviceId, StringComparison.Ordinal);
                var existingLocalRecords = canPreserveRevisionState
                    ? _state.LocalRecords
                    : new Dictionary<string, LocalSyncRecordState>(StringComparer.Ordinal);
                var existingCurrent = canPreserveRevisionState
                    ? _state.LastAcknowledgedCurrentSnapshot
                    : null;
                _state = NewEnabledState(
                    response.VaultId,
                    pending.DeviceId,
                    effectiveDisplayName,
                    response.ActiveDeviceCount);
                _state.LocalRecords = existingLocalRecords;
                _state.LastAcknowledgedCurrentSnapshot = existingCurrent;
                _state.HistoryCursor = 0;
                _state.PendingEncryptedDeviceProfile = encryptedProfile;
                _state.NeedsBootstrap = false;
                _state.NeedsHistoryBootstrap = true;
                _state.PendingBootstrapReason = "recovery";
                if (response.CurrentSnapshot != null)
                {
                    RestoreOwnRecordLocked(
                        response.CurrentSnapshot,
                        isCurrent: true,
                        pending.VaultSeed);
                }
                _stateStore.Save(_state);
            }
            _pendingSecretsStore.Delete();
            _remoteCache.ResetForBootstrap();
        }
        finally
        {
            SetBusy(false);
            _operationGate.Release();
        }

        await ContinueHistoryBootstrapAsync(cancellationToken).ConfigureAwait(false);
    }

    public IReadOnlyList<RecoveryReplacementOption> GetRecoveryReplacementOptions(
        SyncTransportException exception)
    {
        if (exception.StatusCode != HttpStatusCode.Conflict ||
            !string.Equals(exception.ErrorCode, "maximum_devices", StringComparison.Ordinal) ||
            !Guid.TryParse(exception.VaultId, out _) ||
            exception.Devices.Count != SyncProtocol.MaximumDevices)
        {
            throw new InvalidDataException("Sync service did not return a valid recovery device list.");
        }
        lock (_stateLock)
        {
            if (!string.Equals(_state.PendingProvisioningKind, "recover", StringComparison.Ordinal))
            {
                throw new InvalidOperationException("There is no pending recovery to continue.");
            }
        }
        var pending = _pendingSecretsStore.Load();
        if (!string.Equals(pending.Kind, "recover", StringComparison.Ordinal))
        {
            throw new CryptographicException("Pending recovery credentials are invalid.");
        }

        var dataKey = _crypto.DeriveDataKey(pending.VaultSeed);
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var options = new List<RecoveryReplacementOption>();
        foreach (var device in exception.Devices)
        {
            if (!Guid.TryParse(device.DeviceId, out _) || !seen.Add(device.DeviceId))
            {
                throw new InvalidDataException("Sync service returned an invalid recovery device list.");
            }
            DeviceProfileV1? profile = null;
            if (device.EncryptedDeviceProfile != null)
            {
                var profileBytes = _crypto.DecryptDeviceProfile(
                    dataKey,
                    exception.VaultId!,
                    device.DeviceId,
                    device.EncryptedDeviceProfile);
                profile = JsonSerializer.Deserialize<DeviceProfileV1>(profileBytes, _wireJsonOptions)
                          ?? throw new CryptographicException("Encrypted device profile is empty.");
                if (profile.SchemaVersion != SyncProtocol.SchemaVersion ||
                    Encoding.UTF8.GetByteCount(profile.DisplayName ?? string.Empty) > 128 ||
                    Encoding.UTF8.GetByteCount(profile.Platform ?? string.Empty) > 128)
                {
                    throw new CryptographicException("Encrypted device profile is invalid.");
                }
            }
            options.Add(new RecoveryReplacementOption
            {
                DeviceId = device.DeviceId,
                DisplayName = NonEmptyProfileValue(
                    profile?.DisplayName,
                    null,
                    "Device " + device.DeviceId.Substring(0, Math.Min(6, device.DeviceId.Length))),
                Platform = NonEmptyProfileValue(profile?.Platform, null, string.Empty)
            });
        }
        return options;
    }

    public async Task RetryRecoveryReplacingAsync(
        RecoveryReplacementOption option,
        string vaultId,
        CancellationToken cancellationToken = default)
    {
        if (option == null) throw new ArgumentNullException(nameof(option));
        if (!Guid.TryParse(vaultId, out _) || !Guid.TryParse(option.DeviceId, out _))
        {
            throw new ArgumentException("Recovery replacement metadata is invalid.");
        }
        PendingSyncSecrets pending;
        string displayName;
        lock (_stateLock)
        {
            if (!string.Equals(_state.PendingProvisioningKind, "recover", StringComparison.Ordinal))
            {
                throw new InvalidOperationException("There is no pending recovery to continue.");
            }
            displayName = _state.PendingProvisioningDisplayName ?? "Windows device";
        }
        pending = _pendingSecretsStore.Load();
        if (!string.Equals(pending.Kind, "recover", StringComparison.Ordinal))
        {
            throw new CryptographicException("Pending recovery credentials are invalid.");
        }

        pending.VaultId = vaultId;
        pending.DeviceId = option.DeviceId;
        pending.DeviceToken = option.DeviceId + "." + _crypto.GenerateTokenSecret();
        pending.ReplaceDeviceId = option.DeviceId;
        _pendingSecretsStore.Save(pending);
        lock (_stateLock)
        {
            _state.InstallationDeviceId = option.DeviceId;
            _state.DeviceId = option.DeviceId;
            _state.VaultId = vaultId;
            _state.PendingProvisioningReplaceDeviceId = option.DeviceId;
            _state.LocalRecords.Clear();
            _state.LastAcknowledgedCurrentSnapshot = null;
            _stateStore.Save(_state);
        }
        await RecoverVaultAsync(
            _crypto.EncodeRecoveryCode(pending.VaultSeed),
            displayName,
            cancellationToken).ConfigureAwait(false);
    }

    public async Task<PairingSessionContext> BeginPairingAsync(
        string displayName,
        CancellationToken cancellationToken = default)
    {
        var transport = RequireTransport();
        lock (_stateLock)
        {
            if (string.Equals(_state.PendingProvisioningKind, "pairing", StringComparison.Ordinal) &&
                _pendingSecretsStore.Exists)
            {
                return RestorePendingPairingContext(_pendingSecretsStore.Load());
            }
            if (!string.IsNullOrWhiteSpace(_state.PendingProvisioningKind))
            {
                throw new InvalidOperationException("Another sync setup operation is already pending.");
            }
        }
        EnsureNotEnabled();
        string installationDeviceId;
        lock (_stateLock) installationDeviceId = _state.InstallationDeviceId;
        var context = _crypto.CreatePairingContext(installationDeviceId);
        var response = await transport.CreatePairingSessionAsync(new CreatePairingSessionRequest
        {
            DeviceId = context.ProposedDeviceId,
            JoiningPublicKey = Convert.ToBase64String(context.PublicKey)
        }, cancellationToken).ConfigureAwait(false);
        context.SessionId = response.SessionId;
        context.Code = response.Code;
        context.CompletionToken = response.CompletionToken;
        context.ExpiresAt = response.ExpiresAt;
        PrepareDamagedStateForSetup();
        _pendingSecretsStore.Save(new PendingSyncSecrets
        {
            Kind = "pairing",
            DeviceId = context.ProposedDeviceId,
            PairingPrivateKey = context.PrivateKey,
            PairingPublicKey = context.PublicKey,
            PairingSessionId = context.SessionId,
            PairingCode = context.Code,
            PairingCompletionToken = context.CompletionToken,
            PairingExpiresAt = context.ExpiresAt
        });
        lock (_stateLock)
        {
            _state.PendingProvisioningKind = "pairing";
            _state.PendingProvisioningDisplayName = NormalizeProfileValue(displayName, 128);
            _stateStore.Save(_state);
        }
        RaiseStatusChanged();
        return context;
    }

    public PairingSessionContext? GetPendingPairingContext()
    {
        lock (_stateLock)
        {
            if (!string.Equals(_state.PendingProvisioningKind, "pairing", StringComparison.Ordinal) ||
                !_pendingSecretsStore.Exists)
            {
                return null;
            }
        }
        return RestorePendingPairingContext(_pendingSecretsStore.Load());
    }

    private static PairingSessionContext RestorePendingPairingContext(PendingSyncSecrets pending)
    {
        if (!string.Equals(pending.Kind, "pairing", StringComparison.Ordinal) ||
            !pending.PairingExpiresAt.HasValue)
        {
            throw new CryptographicException("Pending pairing state is invalid.");
        }
        return new PairingSessionContext
        {
            PrivateKey = pending.PairingPrivateKey,
            PublicKey = pending.PairingPublicKey,
            SessionId = pending.PairingSessionId,
            Code = pending.PairingCode,
            CompletionToken = pending.PairingCompletionToken,
            ProposedDeviceId = pending.DeviceId,
            ExpiresAt = pending.PairingExpiresAt.Value
        };
    }

    public async Task<PairingApprovalContext> JoinPairingAsync(
        string code,
        CancellationToken cancellationToken = default)
    {
        var transport = RequireTransport();
        var credentials = RequireCredentials();
        EnsureEnabled();
        var localKeys = _crypto.CreatePairingContext(string.Empty);
        var normalizedCode = new string((code ?? string.Empty).Where(char.IsDigit).ToArray());
        if (normalizedCode.Length != 6) throw new ArgumentException("Pairing code must contain six digits.", nameof(code));

        var response = await transport.JoinPairingSessionAsync(
            normalizedCode,
            new JoinPairingSessionRequest { ApprovingPublicKey = Convert.ToBase64String(localKeys.PublicKey) },
            credentials.DeviceToken,
            cancellationToken).ConfigureAwait(false);
        var expiresAt = NormalizeUtc(response.ExpiresAt);
        if (!expiresAt.HasValue || expiresAt.Value <= DateTime.UtcNow)
        {
            throw new InvalidDataException("Pairing session expiration is invalid.");
        }
        var peerKey = Convert.FromBase64String(response.JoiningPublicKey);
        return new PairingApprovalContext
        {
            PrivateKey = localKeys.PrivateKey,
            PublicKey = localKeys.PublicKey,
            PeerPublicKey = peerKey,
            SessionId = response.SessionId,
            NewDeviceId = response.JoiningDeviceId,
            SafetyCode = _crypto.CreatePairingSafetyCode(localKeys.PublicKey, peerKey, localKeys.PrivateKey),
            ExpiresAt = expiresAt.Value
        };
    }

    public async Task ApprovePairingAsync(
        PairingApprovalContext context,
        CancellationToken cancellationToken = default)
    {
        var transport = RequireTransport();
        var credentials = RequireCredentials();
        string vaultId;
        lock (_stateLock) vaultId = _state.VaultId;

        var newDeviceToken = context.NewDeviceId + "." + _crypto.GenerateTokenSecret();
        var grant = new PairingProvisioningPayload
        {
            VaultId = vaultId,
            DeviceToken = newDeviceToken,
            RecoverySeed = Convert.ToBase64String(credentials.VaultSeed)
        };
        var wrapKey = _crypto.DerivePairingWrapKey(context.PrivateKey, context.PeerPublicKey);
        var encryptedGrant = _crypto.EncryptPairingPayload(
            wrapKey,
            context.SessionId,
            SerializeCanonical(grant));
        await transport.ApprovePairingSessionAsync(
            context.SessionId,
            new ApprovePairingSessionRequest
            {
                ApprovingPublicKey = Convert.ToBase64String(context.PublicKey),
                EncryptedGrant = encryptedGrant,
                NewDeviceToken = newDeviceToken
            },
            credentials.DeviceToken,
            cancellationToken).ConfigureAwait(false);
        RunPairingRefreshInBackground(context.ExpiresAt);
    }

    public async Task<PairingCompletionPreview> PreviewPairingCompletionAsync(
        PairingSessionContext context,
        CancellationToken cancellationToken = default)
    {
        var transport = RequireTransport();
        var response = await transport.CompletePairingSessionAsync(
            context.SessionId,
            new CompletePairingSessionRequest { CompletionToken = context.CompletionToken },
            cancellationToken).ConfigureAwait(false);
        if (response.Pending)
        {
            throw new InvalidOperationException("Pairing approval is still pending.");
        }
        if (!response.RequiresProfile || string.IsNullOrWhiteSpace(response.ApprovingPublicKey) ||
            response.EncryptedGrant == null)
        {
            throw new InvalidDataException("Pairing completion response is incomplete.");
        }
        var peerKey = Convert.FromBase64String(response.ApprovingPublicKey);
        return new PairingCompletionPreview
        {
            Context = context,
            Response = response,
            SafetyCode = _crypto.CreatePairingSafetyCode(context.PublicKey, peerKey, context.PrivateKey)
        };
    }

    public async Task CompletePairingAsync(
        PairingCompletionPreview preview,
        string displayName,
        CancellationToken cancellationToken = default)
    {
        RequireTransport();
        EnsureNotEnabled();
        if (string.IsNullOrWhiteSpace(preview.Response.ApprovingPublicKey) ||
            preview.Response.EncryptedGrant == null)
        {
            throw new InvalidDataException("Pairing completion response is incomplete.");
        }
        var peerKey = Convert.FromBase64String(preview.Response.ApprovingPublicKey);
        var wrapKey = _crypto.DerivePairingWrapKey(preview.Context.PrivateKey, peerKey);
        var plaintext = _crypto.DecryptPairingPayload(
            wrapKey,
            preview.Context.SessionId,
            preview.Response.EncryptedGrant);
        var grant = JsonSerializer.Deserialize<PairingProvisioningPayload>(plaintext, _wireJsonOptions)
                    ?? throw new CryptographicException("Pairing grant is invalid.");
        var seed = Convert.FromBase64String(grant.RecoverySeed);
        var deviceToken = grant.DeviceToken;
        if (seed.Length != 16 ||
            string.IsNullOrWhiteSpace(grant.VaultId) ||
            deviceToken == null ||
            string.IsNullOrWhiteSpace(deviceToken) ||
            !deviceToken.StartsWith(preview.Context.ProposedDeviceId + ".", StringComparison.Ordinal))
        {
            throw new CryptographicException("Pairing grant does not match this device.");
        }

        PendingSyncSecrets existingPending;
        try
        {
            existingPending = _pendingSecretsStore.Load();
        }
        catch (CryptographicException)
        {
            throw new CryptographicException("The pending pairing credentials cannot be unlocked.");
        }
        if (!string.Equals(existingPending.Kind, "pairing", StringComparison.Ordinal) ||
            !PairingContextMatchesPending(preview.Context, existingPending))
        {
            throw new CryptographicException("Pairing completion does not match the pending session.");
        }

        var effectiveDisplayName = NormalizeProfileValue(displayName, 128);
        var profile = CreateEncryptedDeviceProfile(
            seed,
            grant.VaultId,
            preview.Context.ProposedDeviceId,
            effectiveDisplayName);
        lock (_stateLock)
        {
            if (!string.Equals(_state.PendingProvisioningKind, "pairing", StringComparison.Ordinal))
            {
                throw new InvalidOperationException("There is no pending pairing session to complete.");
            }
            // Persist the exact encrypted profile before replacing the pairing secret
            // bundle. If the process exits between these two durable writes, startup
            // can reconcile the pairing-final bundle with this exact request body.
            _state.PendingEncryptedDeviceProfile = profile;
            _state.PendingProvisioningDisplayName = effectiveDisplayName;
            _stateStore.Save(_state);
        }
        var pending = new PendingSyncSecrets
        {
            Kind = "pairing-final",
            VaultId = grant.VaultId,
            DeviceId = preview.Context.ProposedDeviceId,
            VaultSeed = seed,
            DeviceToken = deviceToken,
            PairingPrivateKey = preview.Context.PrivateKey,
            PairingPublicKey = preview.Context.PublicKey,
            PairingSessionId = preview.Context.SessionId,
            PairingCode = preview.Context.Code,
            PairingCompletionToken = preview.Context.CompletionToken,
            PairingExpiresAt = preview.Context.ExpiresAt
        };
        _pendingSecretsStore.Save(pending);
        lock (_stateLock)
        {
            _state.PendingProvisioningKind = "pairing-final";
            _stateStore.Save(_state);
        }
        RaiseStatusChanged();

        await RetryPairingFinalAsync(pending, effectiveDisplayName, cancellationToken)
            .ConfigureAwait(false);
    }

    private async Task RetryPairingFinalAsync(
        PendingSyncSecrets pending,
        string displayName,
        CancellationToken cancellationToken)
    {
        var transport = RequireTransport();
        await _operationGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        SetBusy(true);
        try
        {
            PairingEncryptedPayload profile;
            lock (_stateLock)
            {
                if (!string.Equals(_state.PendingProvisioningKind, "pairing-final", StringComparison.Ordinal) ||
                    _state.PendingEncryptedDeviceProfile == null ||
                    !string.Equals(_state.InstallationDeviceId, pending.DeviceId, StringComparison.Ordinal))
                {
                    throw new CryptographicException("Pending pairing completion state is inconsistent.");
                }
                profile = _state.PendingEncryptedDeviceProfile;
            }
            if (!string.Equals(pending.Kind, "pairing-final", StringComparison.Ordinal))
            {
                throw new CryptographicException("Pending pairing completion credentials are invalid.");
            }

            var completion = await transport.CompletePairingSessionAsync(
                pending.PairingSessionId,
                new CompletePairingSessionRequest
                {
                    CompletionToken = pending.PairingCompletionToken,
                    EncryptedDeviceProfile = profile
                },
                cancellationToken).ConfigureAwait(false);
            ValidateCompletedPairingResponse(completion, pending);

            _credentialStore.Save(new SyncCredentials
            {
                VaultId = pending.VaultId,
                DeviceId = pending.DeviceId,
                VaultSeed = pending.VaultSeed,
                DeviceToken = pending.DeviceToken
            });
            lock (_stateLock)
            {
                var canPreserveRevisionState =
                    string.Equals(_state.VaultId, pending.VaultId, StringComparison.Ordinal) &&
                    string.Equals(_state.DeviceId, pending.DeviceId, StringComparison.Ordinal);
                var existingLocalRecords = canPreserveRevisionState
                    ? _state.LocalRecords
                    : new Dictionary<string, LocalSyncRecordState>(StringComparer.Ordinal);
                var existingCurrent = canPreserveRevisionState
                    ? _state.LastAcknowledgedCurrentSnapshot
                    : null;
                _state = NewEnabledState(
                    pending.VaultId,
                    pending.DeviceId,
                    displayName,
                    completion.ActiveDeviceCount ?? 1);
                _state.LocalRecords = existingLocalRecords;
                _state.LastAcknowledgedCurrentSnapshot = existingCurrent;
                _state.HistoryCursor = 0;
                _state.NeedsBootstrap = false;
                _state.NeedsHistoryBootstrap = true;
                _state.NeedsStateRefreshBeforeBootstrap = true;
                _state.PendingBootstrapReason = "pairing";
                _state.PendingEncryptedDeviceProfile = null;
                _lastError = null;
                SaveRecoveredStateLocked();
            }
            _pendingSecretsStore.Delete();
            _remoteCache.ResetForBootstrap();
            RaiseStatusChanged();
        }
        catch (Exception ex)
        {
            lock (_stateLock) _lastError = SafeErrorMessage(ex);
            RaiseStatusChanged();
            throw;
        }
        finally
        {
            SetBusy(false);
            _operationGate.Release();
        }

        await ContinueRevisionRebuildAsync(cancellationToken).ConfigureAwait(false);
    }

    private void ValidateCompletedPairingResponse(
        CompletePairingSessionResponse completion,
        PendingSyncSecrets pending)
    {
        if (completion.Pending || completion.RequiresProfile ||
            completion.ActiveDeviceCount is < 1 or > SyncProtocol.MaximumDevices ||
            string.IsNullOrWhiteSpace(completion.ApprovingPublicKey) ||
            completion.EncryptedGrant == null)
        {
            throw new InvalidDataException("Pairing completion was not finalized by the sync service.");
        }
        var peerKey = Convert.FromBase64String(completion.ApprovingPublicKey);
        var wrapKey = _crypto.DerivePairingWrapKey(pending.PairingPrivateKey, peerKey);
        var plaintext = _crypto.DecryptPairingPayload(
            wrapKey,
            pending.PairingSessionId,
            completion.EncryptedGrant);
        var replayedGrant = JsonSerializer.Deserialize<PairingProvisioningPayload>(plaintext, _wireJsonOptions)
                            ?? throw new CryptographicException("Pairing grant is invalid.");
        byte[] replayedSeed;
        try
        {
            replayedSeed = Convert.FromBase64String(replayedGrant.RecoverySeed);
        }
        catch (FormatException ex)
        {
            throw new CryptographicException("Pairing grant is invalid.", ex);
        }
        if (!string.Equals(replayedGrant.VaultId, pending.VaultId, StringComparison.Ordinal) ||
            !string.Equals(replayedGrant.DeviceToken, pending.DeviceToken, StringComparison.Ordinal) ||
            !replayedSeed.SequenceEqual(pending.VaultSeed))
        {
            throw new CryptographicException("Replayed pairing grant does not match the pending credentials.");
        }
    }

    private static bool PairingContextMatchesPending(
        PairingSessionContext context,
        PendingSyncSecrets pending)
        => string.Equals(context.ProposedDeviceId, pending.DeviceId, StringComparison.Ordinal) &&
           string.Equals(context.SessionId, pending.PairingSessionId, StringComparison.Ordinal) &&
           string.Equals(context.Code, pending.PairingCode, StringComparison.Ordinal) &&
           string.Equals(context.CompletionToken, pending.PairingCompletionToken, StringComparison.Ordinal) &&
           context.PrivateKey.SequenceEqual(pending.PairingPrivateKey) &&
           context.PublicKey.SequenceEqual(pending.PairingPublicKey);

    public Task SyncNowAsync(CancellationToken cancellationToken = default)
        => SyncCoreAsync("manual", bypassClientRateLimit: false, cancellationToken);

    public Task RetryBootstrapAsync(CancellationToken cancellationToken = default)
    {
        string? provisioningKind;
        bool pendingDeletion;
        bool historyOnly;
        bool stateRefreshFirst;
        lock (_stateLock)
        {
            pendingDeletion = _state.PendingVaultDeletion;
            provisioningKind = _state.PendingProvisioningKind;
            if (pendingDeletion || IsRetryableProvisioningKind(provisioningKind))
            {
                historyOnly = false;
                stateRefreshFirst = false;
            }
            else
            {
                if (!_state.IsEnabled || _state.NeedsRepair ||
                    (!_state.NeedsBootstrap && !_state.NeedsHistoryBootstrap &&
                     !_state.NeedsStateRefreshBeforeBootstrap))
                {
                    throw new InvalidOperationException("There is no pending sync bootstrap to retry.");
                }
                stateRefreshFirst = _state.NeedsStateRefreshBeforeBootstrap;
                historyOnly = !_state.NeedsBootstrap && _state.NeedsHistoryBootstrap;
            }
        }
        if (pendingDeletion) return DeleteVaultAsync(cancellationToken);
        if (IsRetryableProvisioningKind(provisioningKind))
        {
            return RetryPendingProvisioningAsync(provisioningKind!, cancellationToken);
        }
        if (stateRefreshFirst) return ContinueRevisionRebuildAsync(cancellationToken);
        return historyOnly
            ? ContinueHistoryBootstrapAsync(cancellationToken)
            : SyncCoreAsync("bootstrap", bypassClientRateLimit: true, cancellationToken);
    }

    private Task RetryPendingProvisioningAsync(string kind, CancellationToken cancellationToken)
    {
        var pending = _pendingSecretsStore.Load();
        string displayName;
        lock (_stateLock) displayName = _state.PendingProvisioningDisplayName ?? "Windows device";
        return kind switch
        {
            "create" => RetryCreateProvisioningAsync(pending, displayName, cancellationToken),
            "recover" => RecoverVaultAsync(
                _crypto.EncodeRecoveryCode(pending.VaultSeed),
                displayName,
                cancellationToken),
            "pairing-final" => RetryPairingFinalAsync(pending, displayName, cancellationToken),
            _ => throw new InvalidOperationException("The pending sync setup cannot be retried automatically.")
        };
    }

    private async Task RetryCreateProvisioningAsync(
        PendingSyncSecrets pending,
        string displayName,
        CancellationToken cancellationToken)
    {
        _ = pending;
        await CreateVaultAsync(displayName, cancellationToken).ConfigureAwait(false);
    }

    private static bool IsRetryableProvisioningKind(string? kind)
        => string.Equals(kind, "create", StringComparison.Ordinal) ||
           string.Equals(kind, "recover", StringComparison.Ordinal) ||
           string.Equals(kind, "pairing-final", StringComparison.Ordinal);

    private async Task ContinueRevisionRebuildAsync(CancellationToken cancellationToken)
    {
        await RefreshStateAsync(rebuildOwnRevisionState: true, cancellationToken).ConfigureAwait(false);
        lock (_stateLock)
        {
            _state.NeedsStateRefreshBeforeBootstrap = false;
            _stateStore.Save(_state);
        }
        await ContinueHistoryBootstrapAsync(cancellationToken).ConfigureAwait(false);
    }

    private async Task ContinueHistoryBootstrapAsync(CancellationToken cancellationToken)
    {
        RequireTransport();
        string? followupReason = null;
        await _operationGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        SetBusy(true);
        try
        {
            lock (_stateLock)
            {
                EnsureEnabledLocked();
                if (!_state.NeedsHistoryBootstrap || _state.NeedsBootstrap ||
                    _state.NeedsStateRefreshBeforeBootstrap)
                {
                    throw new InvalidOperationException("History bootstrap is not ready to resume.");
                }
            }

            var credentials = RequireCredentials();
            var dataKey = _crypto.DeriveDataKey(credentials.VaultSeed);
            var indexKey = _crypto.DeriveIndexKey(credentials.VaultSeed);
            followupReason = await FinishHistoryBootstrapWithinGateAsync(
                credentials,
                dataKey,
                indexKey,
                cancellationToken).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            lock (_stateLock) _lastError = SafeErrorMessage(ex);
            RaiseStatusChanged();
            throw;
        }
        finally
        {
            SetBusy(false);
            _operationGate.Release();
        }
        var reason = followupReason;
        if (reason != null && !string.IsNullOrWhiteSpace(reason))
        {
            await SyncCoreAsync(reason, bypassClientRateLimit: true, cancellationToken)
                .ConfigureAwait(false);
        }
    }

    public async Task LeaveSyncAsync(CancellationToken cancellationToken = default)
    {
        await _operationGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        SetBusy(true);
        try
        {
            bool repairOnly;
            lock (_stateLock) repairOnly = _state.NeedsRepair;
            if (!repairOnly)
            {
                var transport = RequireTransport();
                var credentials = RequireCredentials();
                string deviceId;
                lock (_stateLock)
                {
                    EnsureEnabledLocked();
                    deviceId = _state.DeviceId;
                }
                await transport.RevokeDeviceAsync(deviceId, credentials.DeviceToken, cancellationToken)
                    .ConfigureAwait(false);
            }
            string? replacementCandidate;
            lock (_stateLock)
            {
                replacementCandidate = Guid.TryParse(_state.DeviceId, out _) ? _state.DeviceId : null;
            }
            DisableLocally(replacementCandidate);
        }
        finally
        {
            SetBusy(false);
            _operationGate.Release();
        }
    }

    public async Task RevokeDeviceAsync(string deviceId, CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(deviceId)) throw new ArgumentException("Device identifier is required.", nameof(deviceId));
        var transport = RequireTransport();
        await _operationGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        SetBusy(true);
        try
        {
            var credentials = RequireCredentials();
            lock (_stateLock)
            {
                EnsureEnabledLocked();
                if (string.Equals(deviceId, _state.DeviceId, StringComparison.Ordinal))
                {
                    throw new InvalidOperationException("Use leave sync to remove this device.");
                }
            }

            await transport.RevokeDeviceAsync(deviceId, credentials.DeviceToken, cancellationToken)
                .ConfigureAwait(false);
            lock (_stateLock)
            {
                _state.Devices.RemoveAll(item => string.Equals(item.DeviceId, deviceId, StringComparison.Ordinal));
                _state.ActiveDeviceCount = Math.Max(1, _state.ActiveDeviceCount - 1);
                ScheduleForDeviceCountLocked(DateTime.UtcNow);
                _stateStore.Save(_state);
                _lastError = null;
            }
            RaiseStatusChanged();
        }
        finally
        {
            SetBusy(false);
            _operationGate.Release();
        }
    }

    public async Task DeleteVaultAsync(CancellationToken cancellationToken = default)
    {
        var transport = RequireTransport();
        await _operationGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        SetBusy(true);
        try
        {
            lock (_stateLock) EnsureEnabledLocked();
            var credentials = RequireCredentials();
            lock (_stateLock)
            {
                // Persist the user's destructive intent before contacting the
                // service. DELETE /vault is replay-safe for this exact token, so
                // startup can finish a request whose successful response was lost.
                _state.PendingVaultDeletion = true;
                _state.NextAutomaticSyncAtUtc = null;
                _automaticTimer?.Change(Timeout.Infinite, Timeout.Infinite);
                _stateRefreshTimer?.Change(Timeout.Infinite, Timeout.Infinite);
                _stateStore.Save(_state);
            }
            await transport.DeleteVaultAsync(credentials.DeviceToken, cancellationToken).ConfigureAwait(false);
            DisableLocally(replacementCandidateDeviceId: null);
        }
        catch (Exception ex)
        {
            lock (_stateLock)
            {
                _lastError = SafeErrorMessage(ex);
                if (!_stateStore.NeedsRepair) _stateStore.Save(_state);
            }
            RaiseStatusChanged();
            throw;
        }
        finally
        {
            SetBusy(false);
            _operationGate.Release();
        }
    }

    public async Task ClearLocalSyncConfigurationAsync(
        CancellationToken cancellationToken = default)
    {
        await _operationGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        SetBusy(true);
        try
        {
            string? replacementCandidate;
            lock (_stateLock)
            {
                if (!_state.NeedsRepair && string.IsNullOrWhiteSpace(_state.PendingProvisioningKind))
                {
                    throw new InvalidOperationException(
                        "Only damaged or incomplete local sync setup can be cleared without contacting the service.");
                }
                replacementCandidate = _state.NeedsRepair &&
                                       string.IsNullOrWhiteSpace(_state.PendingProvisioningKind) &&
                                       Guid.TryParse(_state.DeviceId, out _)
                    ? _state.DeviceId
                    : null;
            }
            DisableLocally(replacementCandidate);
        }
        finally
        {
            SetBusy(false);
            _operationGate.Release();
        }
    }

    private async Task SyncCoreAsync(
        string reason,
        bool bypassClientRateLimit,
        CancellationToken cancellationToken,
        bool pairingRefreshOnly = false)
    {
        var transport = RequireTransport();
        await _operationGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        SetBusy(true);
        try
        {
            SyncCredentials credentials;
            lock (_stateLock)
            {
                EnsureEnabledLocked();
                if (_state.PendingVaultDeletion)
                {
                    throw new InvalidOperationException("Cloud sync deletion is pending.");
                }
                var bootstrapReason = SyncBatchPlanner.IsBootstrapReason(reason);
                if (bootstrapReason && !_state.NeedsBootstrap && !pairingRefreshOnly)
                {
                    throw new InvalidOperationException("There is no pending sync bootstrap to upload.");
                }
                if (pairingRefreshOnly &&
                    (!string.Equals(reason, "pairing", StringComparison.Ordinal) ||
                     _state.NeedsBootstrap || _state.NeedsHistoryBootstrap))
                {
                    throw new InvalidOperationException("The pairing refresh cannot run in the current sync phase.");
                }
                if (!bootstrapReason && (_state.NeedsBootstrap || _state.NeedsHistoryBootstrap ||
                                         _state.NeedsStateRefreshBeforeBootstrap))
                {
                    throw new InvalidOperationException("The pending sync bootstrap must finish first.");
                }
                RefreshUtcDayWindowsLocked(DateTime.UtcNow);
                if (_state.ActiveDeviceCount < 2 && !bypassClientRateLimit)
                {
                    throw new InvalidOperationException("Sync is available after a second device is connected.");
                }

                if (!bypassClientRateLimit)
                {
                    var now = DateTime.UtcNow;
                    var allowedAt = GetEffectiveAllowedAtLocked();
                    var bypassManualRateLimit = ManualSyncBypassesClientRateLimit &&
                                                string.Equals(reason, "manual", StringComparison.Ordinal);
                    if (!bypassManualRateLimit)
                    {
                        if (now < allowedAt) throw new SyncRateLimitedException(allowedAt);
                        if (_state.RemainingDailySyncs <= 0) throw new SyncRateLimitedException(NextUtcMidnight(now));
                    }
                }
            }
            credentials = RequireCredentials();

            var prepared = pairingRefreshOnly
                ? PreparePairingRefresh()
                : PrepareSync(credentials, reason);
            var batches = SyncBatchPlanner.CreateBatches(
                prepared.Request,
                prepared.LastAcknowledgedCurrentSnapshot);
            lock (_stateLock)
            {
                _syncProgress = new SyncProgress(
                    batches.Sum(batch => batch.Archives.Count) +
                    (batches.Count > 0 && batches[batches.Count - 1].CurrentSnapshot != null ? 1 : 0));
            }
            RaiseStatusChanged();
            SyncRequest? finalRequest = null;
            SyncResponse? finalResponse = null;
            foreach (var batch in batches)
            {
                SyncResponse response;
                try
                {
                    response = await transport.SyncAsync(
                        batch,
                        credentials.DeviceToken,
                        SyncCrypto.Sha256Base64Url(SerializeCanonical(batch)),
                        cancellationToken).ConfigureAwait(false);
                }
                catch (SyncTransportException ex) when (ex.StatusCode == (HttpStatusCode)429)
                {
                    lock (_stateLock)
                    {
                        var retryAt = DateTime.UtcNow + (ex.RetryAfter ?? SyncProtocol.ManualSyncInterval);
                        _state.NextAllowedSyncAtUtc = retryAt;
                        _stateStore.Save(_state);
                        ScheduleAutomaticTimerLocked(DateTime.UtcNow);
                    }
                    throw new SyncRateLimitedException(
                        GetStatus().NextAllowedSyncAtUtc ?? DateTime.UtcNow.AddHours(1),
                        ex);
                }
                catch (SyncTransportException ex) when (IsSingleDeviceSyncDisabled(ex))
                {
                    lock (_stateLock)
                    {
                        TransitionToSingleDeviceLocked();
                    }
                    RaiseStatusChanged();
                    return;
                }

                ValidateSyncResponse(response);
                if (!batch.BootstrapComplete)
                {
                    lock (_stateLock)
                    {
                        CompletePreparedUploadsLocked(batch);
                        _syncProgress?.Advance(batch.Archives.Count);
                        _stateStore.Save(_state);
                    }
                    RaiseStatusChanged();
                    continue;
                }

                finalRequest = batch;
                finalResponse = response;
            }

            if (finalRequest == null || finalResponse == null)
            {
                throw new InvalidDataException("Sync batching did not produce a final request.");
            }

            var dataKey = _crypto.DeriveDataKey(credentials.VaultSeed);
            var indexKey = _crypto.DeriveIndexKey(credentials.VaultSeed);
            ApplyCurrentSnapshots(finalResponse.CurrentSnapshots, dataKey, indexKey);
            ApplyHistoryChanges(finalResponse.HistoryChanges, dataKey, indexKey);
            RefreshDevices(finalResponse.Devices, credentials);

            var requiresHistoryBootstrap = finalResponse.HistoryHasMore;

            lock (_stateLock)
            {
                CompletePreparedUploadsLocked(finalRequest);
                _syncProgress?.Advance(
                    finalRequest.Archives.Count + (finalRequest.CurrentSnapshot != null ? 1 : 0));
                _state.LastSuccessfulSyncAtUtc = NormalizeUtc(finalResponse.ServerTime);
                _state.NextAllowedSyncAtUtc = NormalizeUtc(finalResponse.NextAllowedSyncAt);
                _state.RemainingDailySyncs = Math.Max(0, finalResponse.RemainingDailySyncs);
                _state.QuotaUtcDay = UtcDay(finalResponse.ServerTime);
                _state.ActiveDeviceCount = Math.Max(1, finalResponse.ActiveDeviceCount);
                _state.HistoryCursor = finalResponse.Cursor;
                _state.NeedsBootstrap = false;
                _state.NeedsHistoryBootstrap = requiresHistoryBootstrap;
                _state.PendingBootstrapReason = null;
                if (finalRequest.EncryptedDeviceProfile != null)
                {
                    _state.PendingEncryptedDeviceProfile = null;
                }
                _lastError = null;
                _state.AutomaticFailureCount = 0;
                _state.AutomaticFailureUtcDay = UtcDay(finalResponse.ServerTime);
                if (!requiresHistoryBootstrap)
                {
                    ScheduleNextSuccessfulAutomaticSyncLocked();
                }
                else
                {
                    _state.NextAutomaticSyncAtUtc = null;
                    _automaticTimer?.Change(Timeout.Infinite, Timeout.Infinite);
                }
                _stateStore.Save(_state);
            }
            RaiseStatusChanged();

            if (requiresHistoryBootstrap)
            {
                await FinishHistoryBootstrapWithinGateAsync(
                    credentials,
                    dataKey,
                    indexKey,
                    cancellationToken).ConfigureAwait(false);
            }
        }
        catch (Exception ex)
        {
            var expectedPairingConflict = pairingRefreshOnly &&
                                          ex is SyncTransportException pairingError &&
                                          pairingError.StatusCode == HttpStatusCode.Conflict;
            lock (_stateLock)
            {
                if (!expectedPairingConflict) _lastError = SafeErrorMessage(ex);
                if (string.Equals(reason, "automatic", StringComparison.Ordinal))
                {
                    if (ex is SyncRateLimitedException { InnerException: SyncTransportException transportError } &&
                        transportError.StatusCode == (HttpStatusCode)429)
                    {
                        _state.NextAutomaticSyncAtUtc = _state.NextAllowedSyncAtUtc ?? DateTime.UtcNow.AddHours(1);
                        ScheduleAutomaticTimerLocked(DateTime.UtcNow);
                    }
                    else
                    {
                        RecordAutomaticFailureLocked();
                    }
                    _stateStore.Save(_state);
                }
                else if (string.Equals(reason, "manual", StringComparison.Ordinal) &&
                         IsManualTransportFailure(ex, cancellationToken))
                {
                    RecordManualFailureLocked();
                    _stateStore.Save(_state);
                }
            }
            RaiseStatusChanged();
            throw;
        }
        finally
        {
            lock (_stateLock) _syncProgress = null;
            SetBusy(false);
            _operationGate.Release();
        }
    }

    private PreparedSync PrepareSync(SyncCredentials credentials, string reason)
    {
        var localHistory = _statsManager.GetLocalHistorySnapshot();
        var dataKey = _crypto.DeriveDataKey(credentials.VaultSeed);
        var indexKey = _crypto.DeriveIndexKey(credentials.VaultSeed);
        var today = DateTime.Today.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
        var request = new SyncRequest { Reason = reason };
        EncryptedSyncRecord? lastAcknowledgedCurrentSnapshot;

        lock (_stateLock)
        {
            if (_state.LastAcknowledgedCurrentSnapshot == null)
            {
                var inferredCurrent = _state.LocalRecords.Values
                    .Where(record => !record.IsPending && !record.UploadedAsArchive &&
                                     record.Envelope != null &&
                                     !string.IsNullOrWhiteSpace(record.Envelope.RecordId))
                    .OrderByDescending(record => record.LocalDay, StringComparer.Ordinal)
                    .FirstOrDefault();
                if (inferredCurrent != null)
                {
                    _state.LastAcknowledgedCurrentSnapshot = CloneEncryptedRecord(inferredCurrent.Envelope);
                }
            }
            lastAcknowledgedCurrentSnapshot = _state.LastAcknowledgedCurrentSnapshot == null
                ? null
                : CloneEncryptedRecord(_state.LastAcknowledgedCurrentSnapshot);
            request.HistoryCursor = _state.HistoryCursor;
            request.EncryptedDeviceProfile = _state.PendingEncryptedDeviceProfile;
            foreach (var pair in localHistory.OrderBy(pair => pair.Key, StringComparer.Ordinal))
            {
                var localDay = pair.Key;
                var contentSnapshot = CreateCoreSnapshot(_state.DeviceId, localDay, pair.Value, revision: 0);
                var contentBytes = SerializeCanonical(contentSnapshot);
                var contentHash = SyncCrypto.Sha256Base64Url(contentBytes);
                _state.LocalRecords.TryGetValue(localDay, out var recordState);

                var hasReusablePendingEnvelope = recordState != null &&
                                                 recordState.IsPending &&
                                                 recordState.Envelope != null &&
                                                 !string.IsNullOrWhiteSpace(recordState.Envelope.Ciphertext);
                if (!hasReusablePendingEnvelope &&
                    (recordState == null ||
                     !string.Equals(recordState.ContentHash, contentHash, StringComparison.Ordinal) ||
                     recordState.Envelope == null ||
                     string.IsNullOrWhiteSpace(recordState.Envelope.Ciphertext)))
                {
                    var revision = checked((recordState?.Revision ?? 0) + 1);
                    var snapshot = CreateCoreSnapshot(_state.DeviceId, localDay, pair.Value, revision);
                    var recordId = _crypto.CreateRecordId(indexKey, _state.DeviceId, localDay);
                    recordState = new LocalSyncRecordState
                    {
                        LocalDay = localDay,
                        ContentHash = contentHash,
                        Revision = revision,
                        IsPending = true,
                        UploadedAsArchive = false,
                        Envelope = _crypto.EncryptRecord(
                            dataKey,
                            _state.VaultId,
                            _state.DeviceId,
                            recordId,
                            revision,
                            SerializeCanonical(snapshot))
                    };
                    _state.LocalRecords[localDay] = recordState;
                }

                if (recordState == null)
                {
                    throw new InvalidDataException("Local sync record state is incomplete.");
                }

                var isArchive = !string.Equals(localDay, today, StringComparison.Ordinal);
                if (isArchive && !recordState.UploadedAsArchive)
                {
                    recordState.IsPending = true;
                }

                if (!recordState.IsPending) continue;
                var envelope = recordState.Envelope
                               ?? throw new InvalidDataException("Local sync record envelope is incomplete.");
                if (isArchive) request.Archives.Add(envelope);
                else request.CurrentSnapshot = envelope;
            }

            _stateStore.Save(_state);
        }

        return new PreparedSync
        {
            Request = request,
            LastAcknowledgedCurrentSnapshot = lastAcknowledgedCurrentSnapshot
        };
    }

    private PreparedSync PreparePairingRefresh()
    {
        lock (_stateLock)
        {
            return new PreparedSync
            {
                Request = new SyncRequest
                {
                    Reason = "pairing",
                    HistoryCursor = _state.HistoryCursor,
                    BootstrapComplete = true
                }
            };
        }
    }

    private void ApplyCurrentSnapshots(
        IEnumerable<EncryptedSyncRecord> records,
        byte[] dataKey,
        byte[] indexKey)
    {
        foreach (var record in records ?? Enumerable.Empty<EncryptedSyncRecord>())
        {
            if (IsLocalDevice(record.DeviceId)) continue;
            _remoteCache.Apply(DecryptAndValidate(record, isCurrent: true, dataKey, indexKey));
        }
    }

    private void ApplyHistoryChanges(
        IEnumerable<SyncHistoryChange> changes,
        byte[] dataKey,
        byte[] indexKey,
        bool rebuildLocalRevisionState = false)
    {
        foreach (var change in changes ?? Enumerable.Empty<SyncHistoryChange>())
        {
            if (change.Cursor < 0 || string.IsNullOrWhiteSpace(change.RecordId))
            {
                throw new InvalidDataException("History change metadata is invalid.");
            }
            if (change.Tombstone)
            {
                if (rebuildLocalRevisionState)
                {
                    lock (_stateLock)
                    {
                        var local = _state.LocalRecords.FirstOrDefault(pair =>
                            string.Equals(pair.Value.Envelope.RecordId, change.RecordId, StringComparison.Ordinal));
                        if (!string.IsNullOrWhiteSpace(local.Key)) _state.LocalRecords.Remove(local.Key);
                    }
                }
                _remoteCache.ApplyTombstone(change.RecordId, Math.Max(1, change.Cursor));
                continue;
            }
            if (change.Record == null) throw new InvalidDataException("History change is missing its encrypted record.");
            if (!string.Equals(change.Record.RecordId, change.RecordId, StringComparison.Ordinal))
            {
                throw new InvalidDataException("History change record identifier is inconsistent.");
            }
            var decrypted = DecryptAndValidate(change.Record, isCurrent: false, dataKey, indexKey);
            if (IsLocalDevice(change.Record.DeviceId))
            {
                if (rebuildLocalRevisionState)
                {
                    lock (_stateLock) RestoreOwnDecryptedRecordLocked(change.Record, decrypted, isCurrent: false);
                }
                continue;
            }
            _remoteCache.Apply(decrypted);
        }
    }

    private CachedRemoteRecord DecryptAndValidate(
        EncryptedSyncRecord record,
        bool isCurrent,
        byte[] dataKey,
        byte[] indexKey)
    {
        var plaintextBytes = _crypto.DecryptRecord(dataKey, GetVaultId(), record);
        var snapshot = JsonSerializer.Deserialize<CoreDaySnapshotV1>(plaintextBytes, _wireJsonOptions)
                       ?? throw new InvalidDataException("Encrypted snapshot is empty.");
        if (snapshot.SchemaVersion != SyncProtocol.SchemaVersion ||
            snapshot.Revision != record.Revision ||
            !string.Equals(snapshot.DeviceId, record.DeviceId, StringComparison.Ordinal) ||
            !DateTime.TryParseExact(snapshot.LocalDay, "yyyy-MM-dd", CultureInfo.InvariantCulture,
                DateTimeStyles.None, out _) ||
            !string.Equals(
                _crypto.CreateRecordId(indexKey, record.DeviceId, snapshot.LocalDay),
                record.RecordId,
                StringComparison.Ordinal))
        {
            throw new CryptographicException("Encrypted snapshot metadata is inconsistent.");
        }

        ValidateCoreSnapshot(snapshot);
        return new CachedRemoteRecord
        {
            DeviceId = record.DeviceId,
            RecordId = record.RecordId,
            Revision = record.Revision,
            CiphertextHash = record.CiphertextHash,
            IsCurrent = isCurrent,
            Plaintext = snapshot
        };
    }

    private void RestoreOwnRecordLocked(
        EncryptedSyncRecord record,
        bool isCurrent,
        byte[] vaultSeed)
    {
        var dataKey = _crypto.DeriveDataKey(vaultSeed);
        var indexKey = _crypto.DeriveIndexKey(vaultSeed);
        var decrypted = DecryptAndValidate(record, isCurrent, dataKey, indexKey);
        RestoreOwnDecryptedRecordLocked(record, decrypted, isCurrent);
    }

    private void RestoreOwnDecryptedRecordLocked(
        EncryptedSyncRecord record,
        CachedRemoteRecord decrypted,
        bool isCurrent)
    {
        if (!string.Equals(record.DeviceId, _state.DeviceId, StringComparison.Ordinal) ||
            !string.Equals(decrypted.DeviceId, _state.DeviceId, StringComparison.Ordinal))
        {
            throw new CryptographicException("Recovered revision state belongs to a different device.");
        }

        var snapshot = decrypted.Plaintext;
        var originalRevision = snapshot.Revision;
        snapshot.Revision = 0;
        var contentHash = SyncCrypto.Sha256Base64Url(SerializeCanonical(snapshot));
        snapshot.Revision = originalRevision;

        _state.LocalRecords.TryGetValue(snapshot.LocalDay, out var existing);
        if (existing == null || existing.Revision <= record.Revision)
        {
            if (existing != null && existing.Revision == record.Revision &&
                !string.Equals(existing.Envelope.CiphertextHash, record.CiphertextHash, StringComparison.Ordinal))
            {
                throw new CryptographicException("Recovered revision state conflicts with local metadata.");
            }
            _state.LocalRecords[snapshot.LocalDay] = new LocalSyncRecordState
            {
                LocalDay = snapshot.LocalDay,
                ContentHash = contentHash,
                Revision = record.Revision,
                IsPending = false,
                UploadedAsArchive = !isCurrent,
                Envelope = CloneEncryptedRecord(record)
            };
        }
        if (isCurrent)
        {
            _state.LastAcknowledgedCurrentSnapshot = CloneEncryptedRecord(record);
        }
    }

    private async Task<long> FetchRemainingHistoryAsync(
        long cursor,
        SyncCredentials credentials,
        byte[] dataKey,
        byte[] indexKey,
        CancellationToken cancellationToken)
    {
        if (_transport == null) return cursor;
        for (var page = 0; page < SyncProtocol.MaximumHistoryPagesPerAttempt; page++)
        {
            var previousCursor = cursor;
            var response = await _transport.GetHistoryAsync(cursor, credentials.DeviceToken, cancellationToken)
                .ConfigureAwait(false);
            if (response.Cursor < previousCursor || (response.HasMore && response.Cursor == previousCursor))
            {
                throw new InvalidDataException("History response cursor is invalid.");
            }
            bool rebuildLocalRevisionState;
            lock (_stateLock)
            {
                rebuildLocalRevisionState =
                    string.Equals(_state.PendingBootstrapReason, "recovery", StringComparison.Ordinal) ||
                    string.Equals(_state.PendingBootstrapReason, "pairing", StringComparison.Ordinal);
            }
            ApplyHistoryChanges(response.Changes, dataKey, indexKey, rebuildLocalRevisionState);
            cursor = response.Cursor;
            lock (_stateLock)
            {
                if (_state.NeedsBootstrap || !_state.NeedsHistoryBootstrap)
                {
                    throw new InvalidOperationException("History bootstrap is no longer pending.");
                }
                _state.HistoryCursor = cursor;
                _stateStore.Save(_state);
            }
            if (!response.HasMore) return cursor;
        }
        throw new InvalidDataException("History bootstrap exceeded the page limit.");
    }

    private async Task<string?> FinishHistoryBootstrapWithinGateAsync(
        SyncCredentials credentials,
        byte[] dataKey,
        byte[] indexKey,
        CancellationToken cancellationToken)
    {
        long cursor;
        lock (_stateLock)
        {
            EnsureEnabledLocked();
            if (_state.NeedsBootstrap || !_state.NeedsHistoryBootstrap)
            {
                throw new InvalidOperationException("History bootstrap is not ready to continue.");
            }
            cursor = _state.HistoryCursor;
        }

        cursor = await FetchRemainingHistoryAsync(
            cursor,
            credentials,
            dataKey,
            indexKey,
            cancellationToken).ConfigureAwait(false);

        string? followupReason;
        lock (_stateLock)
        {
            _state.HistoryCursor = cursor;
            _state.NeedsHistoryBootstrap = false;
            _lastError = null;
            followupReason = _state.PendingBootstrapReason;
            if (!string.IsNullOrWhiteSpace(followupReason))
            {
                _state.NeedsBootstrap = true;
            }
            else
            {
                ScheduleNextSuccessfulAutomaticSyncLocked();
            }
            _stateStore.Save(_state);
        }
        RaiseStatusChanged();
        return followupReason;
    }

    private static void ValidateSyncResponse(SyncResponse response)
    {
        if (response.ServerTime == default || response.NextAllowedSyncAt == default || response.Cursor < 0 ||
            response.ActiveDeviceCount < 1 || response.ActiveDeviceCount > SyncProtocol.MaximumDevices ||
            response.RemainingDailySyncs < 0 || response.RemainingDailySyncs > 8 ||
            response.CurrentSnapshots == null || response.HistoryChanges == null || response.Devices == null)
        {
            throw new InvalidDataException("Sync service returned an invalid response.");
        }
    }

    private void RefreshDevices(
        IReadOnlyList<DeviceSummary>? encryptedDevices,
        SyncCredentials credentials)
    {
        var devices = encryptedDevices ?? Array.Empty<DeviceSummary>();
        if (devices.Count > SyncProtocol.MaximumDevices)
        {
            throw new InvalidDataException("Sync service returned too many devices.");
        }

        string vaultId;
        string currentDeviceId;
        SyncDeviceInfo currentDevice;
        Dictionary<string, SyncDeviceInfo> existing;
        lock (_stateLock)
        {
            vaultId = _state.VaultId;
            currentDeviceId = _state.DeviceId;
            var found = _state.Devices.FirstOrDefault(item =>
                string.Equals(item.DeviceId, currentDeviceId, StringComparison.Ordinal));
            currentDevice = found != null ? CloneDevice(found) : CreateCurrentDeviceInfo(_state);
            existing = _state.Devices
                .Where(item => !string.IsNullOrWhiteSpace(item.DeviceId))
                .GroupBy(item => item.DeviceId, StringComparer.Ordinal)
                .ToDictionary(group => group.Key, group => CloneDevice(group.Last()), StringComparer.Ordinal);
        }

        var dataKey = _crypto.DeriveDataKey(credentials.VaultSeed);
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var refreshed = new List<SyncDeviceInfo>();
        foreach (var encrypted in devices)
        {
            if (string.IsNullOrWhiteSpace(encrypted.DeviceId) || !seen.Add(encrypted.DeviceId))
            {
                throw new InvalidDataException("Sync service returned an invalid device list.");
            }

            existing.TryGetValue(encrypted.DeviceId, out var previous);
            DeviceProfileV1? profile = null;
            if (encrypted.EncryptedDeviceProfile != null)
            {
                var profileBytes = _crypto.DecryptDeviceProfile(
                    dataKey,
                    vaultId,
                    encrypted.DeviceId,
                    encrypted.EncryptedDeviceProfile);
                profile = JsonSerializer.Deserialize<DeviceProfileV1>(profileBytes, _wireJsonOptions)
                          ?? throw new CryptographicException("Encrypted device profile is empty.");
                if (profile.SchemaVersion != SyncProtocol.SchemaVersion ||
                    Encoding.UTF8.GetByteCount(profile.DisplayName ?? string.Empty) > 128 ||
                    Encoding.UTF8.GetByteCount(profile.Platform ?? string.Empty) > 128)
                {
                    throw new CryptographicException("Encrypted device profile is invalid.");
                }
            }

            refreshed.Add(new SyncDeviceInfo
            {
                DeviceId = encrypted.DeviceId,
                DisplayName = NonEmptyProfileValue(
                    profile?.DisplayName,
                    previous?.DisplayName,
                    "Device " + encrypted.DeviceId.Substring(0, Math.Min(6, encrypted.DeviceId.Length))),
                Platform = NonEmptyProfileValue(profile?.Platform, previous?.Platform, string.Empty),
                LastSyncAt = NormalizeUtc(encrypted.LastSyncAt),
                IsCurrent = string.Equals(encrypted.DeviceId, currentDeviceId, StringComparison.Ordinal),
                IsRevoked = encrypted.Revoked
            });
        }

        if (!seen.Contains(currentDeviceId)) refreshed.Add(currentDevice);
        lock (_stateLock) _state.Devices = refreshed;
    }

    private PairingEncryptedPayload CreateEncryptedDeviceProfile(
        byte[] seed,
        string vaultId,
        string deviceId,
        string displayName)
    {
        var profile = new DeviceProfileV1
        {
            DisplayName = NormalizeProfileValue(displayName, 128),
            Platform = "windows"
        };
        var bytes = SerializeCanonical(profile);
        return _crypto.EncryptDeviceProfile(_crypto.DeriveDataKey(seed), vaultId, deviceId, bytes);
    }

    private CoreDaySnapshotV1 CreateCoreSnapshot(
        string deviceId,
        string localDay,
        DailyStats source,
        long revision)
    {
        var keyCounts = new Dictionary<string, long>(StringComparer.Ordinal);
        foreach (var pair in source.KeyPressCounts.OrderBy(pair => pair.Key, StringComparer.Ordinal))
        {
            if (!string.IsNullOrWhiteSpace(pair.Key) && pair.Value > 0)
            {
                var key = SyncKeyCanonicalizer.Canonicalize(pair.Key, "windows");
                if (key.Length == 0) continue;
                keyCounts[key] = SaturatingAdd(
                    keyCounts.TryGetValue(key, out var existing) ? existing : 0,
                    pair.Value);
            }
        }

        var snapshot = new CoreDaySnapshotV1
        {
            DeviceId = deviceId,
            LocalDay = localDay,
            Revision = revision,
            KeyPresses = Math.Max(0, source.KeyPresses),
            KeyPressCounts = keyCounts,
            Clicks = new CoreClickSnapshotV1
            {
                Left = Math.Max(0, source.LeftClicks),
                Right = Math.Max(0, source.RightClicks),
                Middle = Math.Max(0, source.MiddleClicks),
                SideBack = Math.Max(0, source.SideBackClicks),
                SideForward = Math.Max(0, source.SideForwardClicks)
            }
        };
        ValidateCoreSnapshot(snapshot);
        return snapshot;
    }

    private static byte[] SerializeCanonical(CoreDaySnapshotV1 snapshot)
    {
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream, new JsonWriterOptions
               {
                   Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping
               }))
        {
            writer.WriteStartObject();
            writer.WritePropertyName("clicks");
            writer.WriteStartObject();
            writer.WriteNumber("left", snapshot.Clicks.Left);
            writer.WriteNumber("middle", snapshot.Clicks.Middle);
            writer.WriteNumber("right", snapshot.Clicks.Right);
            writer.WriteNumber("sideBack", snapshot.Clicks.SideBack);
            writer.WriteNumber("sideForward", snapshot.Clicks.SideForward);
            writer.WriteEndObject();
            writer.WriteString("deviceId", snapshot.DeviceId);
            writer.WritePropertyName("keyPressCounts");
            writer.WriteStartObject();
            foreach (var pair in snapshot.KeyPressCounts.OrderBy(pair => pair.Key, StringComparer.Ordinal))
            {
                writer.WriteNumber(pair.Key, pair.Value);
            }
            writer.WriteEndObject();
            writer.WriteNumber("keyPresses", snapshot.KeyPresses);
            writer.WriteString("localDay", snapshot.LocalDay);
            writer.WriteNumber("revision", snapshot.Revision);
            writer.WriteNumber("schemaVersion", snapshot.SchemaVersion);
            writer.WriteEndObject();
            writer.Flush();
        }
        return stream.ToArray();
    }

    private static byte[] SerializeCanonical(SyncRequest request)
    {
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream, new JsonWriterOptions
               {
                   Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping
               }))
        {
            writer.WriteStartObject();
            writer.WritePropertyName("archives");
            writer.WriteStartArray();
            foreach (var archive in request.Archives) WriteEncryptedRecord(writer, archive);
            writer.WriteEndArray();
            writer.WriteBoolean("bootstrapComplete", request.BootstrapComplete);
            if (request.CurrentSnapshot != null)
            {
                writer.WritePropertyName("currentSnapshot");
                WriteEncryptedRecord(writer, request.CurrentSnapshot);
            }
            if (request.EncryptedDeviceProfile != null)
            {
                writer.WritePropertyName("encryptedDeviceProfile");
                WriteEncryptedPayload(writer, request.EncryptedDeviceProfile);
            }
            writer.WriteNumber("historyCursor", request.HistoryCursor);
            writer.WriteString("reason", request.Reason);
            writer.WriteEndObject();
            writer.Flush();
        }
        return stream.ToArray();
    }

    private static byte[] SerializeCanonical(PairingProvisioningPayload grant)
    {
        using var stream = new MemoryStream();
        using (var writer = CreateCanonicalWriter(stream))
        {
            writer.WriteStartObject();
            if (grant.DeviceToken != null) writer.WriteString("deviceToken", grant.DeviceToken);
            writer.WriteString("recoverySeed", grant.RecoverySeed);
            writer.WriteString("vaultId", grant.VaultId);
            writer.WriteEndObject();
            writer.Flush();
        }
        return stream.ToArray();
    }

    private static byte[] SerializeCanonical(DeviceProfileV1 profile)
    {
        using var stream = new MemoryStream();
        using (var writer = CreateCanonicalWriter(stream))
        {
            writer.WriteStartObject();
            writer.WriteString("displayName", profile.DisplayName);
            writer.WriteString("platform", profile.Platform);
            writer.WriteNumber("schemaVersion", profile.SchemaVersion);
            writer.WriteEndObject();
            writer.Flush();
        }
        return stream.ToArray();
    }

    private static Utf8JsonWriter CreateCanonicalWriter(Stream stream)
    {
        return new Utf8JsonWriter(stream, new JsonWriterOptions
        {
            Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping
        });
    }

    private static void WriteEncryptedRecord(Utf8JsonWriter writer, EncryptedSyncRecord record)
    {
        writer.WriteStartObject();
        writer.WriteString("ciphertext", record.Ciphertext);
        writer.WriteString("ciphertextHash", record.CiphertextHash);
        writer.WriteString("deviceId", record.DeviceId);
        writer.WriteString("nonce", record.Nonce);
        writer.WriteString("recordId", record.RecordId);
        writer.WriteNumber("revision", record.Revision);
        writer.WriteNumber("schemaVersion", record.SchemaVersion);
        writer.WriteString("tag", record.Tag);
        writer.WriteEndObject();
    }

    private static void WriteEncryptedPayload(Utf8JsonWriter writer, PairingEncryptedPayload payload)
    {
        writer.WriteStartObject();
        writer.WriteString("ciphertext", payload.Ciphertext);
        writer.WriteString("nonce", payload.Nonce);
        writer.WriteString("tag", payload.Tag);
        writer.WriteEndObject();
    }

    private static void ValidateCoreSnapshot(CoreDaySnapshotV1 snapshot)
    {
        if (snapshot.SchemaVersion != SyncProtocol.SchemaVersion ||
            string.IsNullOrWhiteSpace(snapshot.DeviceId) ||
            snapshot.Revision < 0 || snapshot.KeyPresses < 0 || snapshot.Clicks == null ||
            snapshot.Clicks.Left < 0 || snapshot.Clicks.Right < 0 || snapshot.Clicks.Middle < 0 ||
            snapshot.Clicks.SideBack < 0 || snapshot.Clicks.SideForward < 0 ||
            snapshot.KeyPressCounts == null || snapshot.KeyPressCounts.Count > SyncProtocol.MaximumKeyEntries ||
            !DateTime.TryParseExact(snapshot.LocalDay, "yyyy-MM-dd", CultureInfo.InvariantCulture,
                DateTimeStyles.None, out var parsedDay) ||
            !string.Equals(parsedDay.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture), snapshot.LocalDay,
                StringComparison.Ordinal))
        {
            throw new InvalidDataException("Encrypted snapshot contains invalid counters.");
        }

        var normalized = new Dictionary<string, long>(StringComparer.Ordinal);
        foreach (var pair in snapshot.KeyPressCounts.OrderBy(pair => pair.Key, StringComparer.Ordinal))
        {
            if (pair.Value < 0)
            {
                throw new InvalidDataException("Encrypted snapshot contains an invalid key counter.");
            }
            var key = SyncKeyCanonicalizer.Canonicalize(pair.Key, "windows");
            if (string.IsNullOrWhiteSpace(key) ||
                Encoding.UTF8.GetByteCount(key) > SyncProtocol.MaximumKeyNameBytes)
            {
                throw new InvalidDataException("Encrypted snapshot contains an invalid key counter.");
            }
            normalized[key] = SaturatingAdd(
                normalized.TryGetValue(key, out var existing) ? existing : 0,
                pair.Value);
        }
        if (normalized.Count > SyncProtocol.MaximumKeyEntries)
        {
            throw new InvalidDataException("Encrypted snapshot contains too many key counters.");
        }
        snapshot.KeyPressCounts = normalized;
        if (SerializeCanonical(snapshot).Length > SyncProtocol.MaximumSnapshotBytes)
        {
            throw new InvalidDataException("Encrypted snapshot exceeds the size limit.");
        }
    }

    private static long SaturatingAdd(long left, long right)
    {
        if (left < 0 || right <= 0) return Math.Max(0, left);
        return left > long.MaxValue - right ? long.MaxValue : left + right;
    }

    private void CompletePreparedUploadsLocked(SyncRequest request)
    {
        foreach (var archive in request.Archives)
        {
            CompleteRecordLocked(archive, uploadedAsArchive: true);
        }
        if (request.CurrentSnapshot != null)
        {
            CompleteRecordLocked(request.CurrentSnapshot, uploadedAsArchive: false);
        }
    }

    private void CompleteRecordLocked(EncryptedSyncRecord record, bool uploadedAsArchive)
    {
        if (uploadedAsArchive)
        {
            if (string.Equals(
                    _state.LastAcknowledgedCurrentSnapshot?.RecordId,
                    record.RecordId,
                    StringComparison.Ordinal))
            {
                _state.LastAcknowledgedCurrentSnapshot = null;
            }
        }
        else
        {
            _state.LastAcknowledgedCurrentSnapshot = CloneEncryptedRecord(record);
        }

        var state = _state.LocalRecords.Values.FirstOrDefault(item =>
            item.Revision == record.Revision &&
            string.Equals(item.Envelope.RecordId, record.RecordId, StringComparison.Ordinal) &&
            string.Equals(item.Envelope.CiphertextHash, record.CiphertextHash, StringComparison.Ordinal));
        if (state == null) return;
        state.IsPending = false;
        state.UploadedAsArchive = uploadedAsArchive;
    }

    private static EncryptedSyncRecord CloneEncryptedRecord(EncryptedSyncRecord record)
    {
        return new EncryptedSyncRecord
        {
            SchemaVersion = record.SchemaVersion,
            RecordId = record.RecordId,
            DeviceId = record.DeviceId,
            Revision = record.Revision,
            Nonce = record.Nonce,
            Ciphertext = record.Ciphertext,
            Tag = record.Tag,
            CiphertextHash = record.CiphertextHash
        };
    }

    private void ScheduleForDeviceCountLocked(DateTime now)
    {
        if (_state.ActiveDeviceCount < 2)
        {
            _state.NextAutomaticSyncAtUtc = null;
            _automaticTimer?.Change(Timeout.Infinite, Timeout.Infinite);
            ScheduleStateRefreshLocked(now);
            return;
        }
        _stateRefreshTimer?.Change(Timeout.Infinite, Timeout.Infinite);
        EnsureAutomaticAttemptLocked(now);
        ScheduleAutomaticTimerLocked(now);
    }

    private void EnsureAutomaticAttemptLocked(DateTime now)
    {
        if (_state.NextAutomaticSyncAtUtc.HasValue) return;
        if (_state.LastSuccessfulSyncAtUtc.HasValue)
        {
            var baseDue = _state.LastSuccessfulSyncAtUtc.Value + SyncProtocol.AutomaticSyncInterval;
            _state.NextAutomaticSyncAtUtc = baseDue + GetDeterministicJitter(baseDue);
        }
        else
        {
            _state.NextAutomaticSyncAtUtc = now + GetDeterministicJitter(now.Date);
        }
        _stateStore.Save(_state);
    }

    private void ScheduleNextSuccessfulAutomaticSyncLocked()
    {
        if (_state.ActiveDeviceCount < 2)
        {
            _state.NextAutomaticSyncAtUtc = null;
            _automaticTimer?.Change(Timeout.Infinite, Timeout.Infinite);
            ScheduleStateRefreshLocked(DateTime.UtcNow);
            return;
        }
        var lastSuccess = _state.LastSuccessfulSyncAtUtc ?? DateTime.UtcNow;
        var baseDue = lastSuccess + SyncProtocol.AutomaticSyncInterval;
        _state.NextAutomaticSyncAtUtc = baseDue + GetDeterministicJitter(baseDue);
        ScheduleAutomaticTimerLocked(DateTime.UtcNow);
    }

    private void RecordAutomaticFailureLocked(DateTime? currentTimeUtc = null)
    {
        if (_state.ActiveDeviceCount < 2) return;
        var now = (currentTimeUtc ?? DateTime.UtcNow).ToUniversalTime();
        var utcDay = UtcDay(now);
        if (!string.Equals(_state.AutomaticFailureUtcDay, utcDay, StringComparison.Ordinal))
        {
            _state.AutomaticFailureUtcDay = utcDay;
            _state.AutomaticFailureCount = 0;
        }
        _state.AutomaticFailureCount = Math.Min(
            SyncProtocol.MaximumAutomaticFailuresPerUtcDay,
            _state.AutomaticFailureCount + 1);

        var retryAt = _state.AutomaticFailureCount >= SyncProtocol.MaximumAutomaticFailuresPerUtcDay
            ? NextUtcMidnight(now) + GetDeterministicJitter(NextUtcMidnight(now))
            : _state.AutomaticFailureCount == 1
                ? now.AddHours(1)
                : now.AddHours(6);
        if (_state.NextAllowedSyncAtUtc.HasValue && _state.NextAllowedSyncAtUtc.Value > retryAt)
        {
            retryAt = _state.NextAllowedSyncAtUtc.Value;
        }
        _state.NextAutomaticSyncAtUtc = retryAt;
        ScheduleAutomaticTimerLocked(now);
    }

    private void RecordManualFailureLocked()
    {
        var now = DateTime.UtcNow;
        var retryAt = now.AddMinutes(1);
        if (!_state.NextAllowedSyncAtUtc.HasValue || _state.NextAllowedSyncAtUtc.Value < retryAt)
        {
            _state.NextAllowedSyncAtUtc = retryAt;
        }
        ScheduleAutomaticTimerLocked(now);
    }

    private void TransitionToSingleDeviceLocked()
    {
        _state.ActiveDeviceCount = 1;
        _state.NextAutomaticSyncAtUtc = null;
        _automaticTimer?.Change(Timeout.Infinite, Timeout.Infinite);
        ScheduleStateRefreshLocked(DateTime.UtcNow);
        _lastError = null;
        _stateStore.Save(_state);
    }

    private void ScheduleStateRefreshLocked(DateTime now)
    {
        if (_transport == null || !_state.IsEnabled || _state.NeedsRepair ||
            _state.NeedsBootstrap || _state.NeedsHistoryBootstrap ||
            _state.NeedsStateRefreshBeforeBootstrap || _state.PendingVaultDeletion ||
            _state.ActiveDeviceCount >= 2)
        {
            _stateRefreshTimer?.Change(Timeout.Infinite, Timeout.Infinite);
            return;
        }
        var refreshBase = _state.LastStateRefreshAtUtc ?? _state.LastSuccessfulSyncAtUtc ?? now;
        var dueAt = refreshBase + StateRefreshInterval;
        var due = dueAt <= now ? TimeSpan.Zero : dueAt - now;
        if (due > TimeSpan.FromMilliseconds(int.MaxValue)) due = TimeSpan.FromMilliseconds(int.MaxValue);
        _stateRefreshTimer ??= new Timer(_ => RunStateRefreshInBackground(), null, Timeout.Infinite, Timeout.Infinite);
        _stateRefreshTimer.Change(due, Timeout.InfiniteTimeSpan);
    }

    private void RunStateRefreshInBackground()
    {
        _ = Task.Run(async () =>
        {
            try
            {
                await RefreshStateAsync(false, _lifetimeCancellation.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (_lifetimeCancellation.IsCancellationRequested)
            {
            }
            catch (Exception ex)
            {
                System.Diagnostics.Debug.WriteLine($"Sync state refresh failed: {SafeErrorMessage(ex)}");
            }
        });
    }

    private static bool IsSingleDeviceSyncDisabled(SyncTransportException exception)
    {
        return exception.StatusCode == HttpStatusCode.Conflict &&
               string.Equals(exception.ErrorCode, "single_device_sync_disabled", StringComparison.Ordinal) &&
               exception.ActiveDeviceCount == 1;
    }

    private static bool IsManualTransportFailure(
        Exception exception,
        CancellationToken cancellationToken)
    {
        return exception is SyncTransportException ||
               exception is HttpRequestException ||
               exception is IOException ||
               (exception is TaskCanceledException && !cancellationToken.IsCancellationRequested);
    }

    private void ScheduleAutomaticTimerLocked(DateTime now)
    {
        if (_transport == null || _state.PendingVaultDeletion || _state.ActiveDeviceCount < 2 ||
            !_state.NextAutomaticSyncAtUtc.HasValue)
        {
            _automaticTimer?.Change(Timeout.Infinite, Timeout.Infinite);
            return;
        }
        var dueAt = _state.NextAutomaticSyncAtUtc.Value;
        RefreshUtcDayWindowsLocked(now);
        if (_state.RemainingDailySyncs <= 0)
        {
            var nextQuotaWindow = NextUtcMidnight(now) + GetDeterministicJitter(NextUtcMidnight(now));
            if (nextQuotaWindow > dueAt) dueAt = nextQuotaWindow;
        }
        var allowedAt = GetEffectiveAllowedAtLocked();
        if (allowedAt > dueAt) dueAt = allowedAt;
        var due = dueAt <= now ? TimeSpan.Zero : dueAt - now;
        if (due > TimeSpan.FromMilliseconds(int.MaxValue)) due = TimeSpan.FromMilliseconds(int.MaxValue);
        _automaticTimer ??= new Timer(_ => RunAutomaticSyncInBackground(), null, Timeout.Infinite, Timeout.Infinite);
        _automaticTimer.Change(due, Timeout.InfiniteTimeSpan);
    }

    private void RunAutomaticSyncInBackground()
    {
        _ = Task.Run(async () =>
        {
            try
            {
                await SyncCoreAsync("automatic", bypassClientRateLimit: false, _lifetimeCancellation.Token)
                    .ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (_lifetimeCancellation.IsCancellationRequested)
            {
            }
            catch (Exception ex)
            {
                System.Diagnostics.Debug.WriteLine($"Automatic sync failed: {SafeErrorMessage(ex)}");
            }
        });
    }

    private void RunBootstrapInBackground()
    {
        _ = Task.Run(async () =>
        {
            try
            {
                await RetryBootstrapAsync(_lifetimeCancellation.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (_lifetimeCancellation.IsCancellationRequested)
            {
            }
            catch (Exception ex)
            {
                System.Diagnostics.Debug.WriteLine($"Sync bootstrap failed: {SafeErrorMessage(ex)}");
            }
        });
    }

    private void RunPendingProvisioningInBackground() => RunBootstrapInBackground();

    private void RunVaultDeletionInBackground()
    {
        _ = Task.Run(async () =>
        {
            try
            {
                await DeleteVaultAsync(_lifetimeCancellation.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (_lifetimeCancellation.IsCancellationRequested)
            {
            }
            catch (Exception ex)
            {
                System.Diagnostics.Debug.WriteLine(
                    $"Sync vault deletion retry failed: {SafeErrorMessage(ex)}");
            }
        });
    }

    private void RunPairingRefreshInBackground(DateTime expiresAtUtc)
    {
        _ = Task.Run(async () =>
        {
            var delayIndex = 0;
            while (!_lifetimeCancellation.IsCancellationRequested)
            {
                var delay = PairingRefreshRetryDelays[Math.Min(
                    delayIndex,
                    PairingRefreshRetryDelays.Length - 1)];
                if (DateTime.UtcNow + delay >= expiresAtUtc) return;

                try
                {
                    await Task.Delay(delay, _lifetimeCancellation.Token).ConfigureAwait(false);
                    await SyncCoreAsync(
                        "pairing",
                        bypassClientRateLimit: true,
                        cancellationToken: _lifetimeCancellation.Token,
                        pairingRefreshOnly: true).ConfigureAwait(false);
                    return;
                }
                catch (OperationCanceledException) when (_lifetimeCancellation.IsCancellationRequested)
                {
                    return;
                }
                catch (SyncTransportException ex) when (ex.StatusCode == HttpStatusCode.Conflict)
                {
                    delayIndex++;
                }
                catch (Exception ex)
                {
                    System.Diagnostics.Debug.WriteLine(
                        $"Pairing refresh failed: {SafeErrorMessage(ex)}");
                    return;
                }
            }
        });
    }

    private TimeSpan GetDeterministicJitter(DateTime cycle)
    {
        string deviceId;
        lock (_stateLock) deviceId = _state.DeviceId;
        using var sha = SHA256.Create();
        var digest = sha.ComputeHash(Encoding.UTF8.GetBytes(
            deviceId + "\n" + UtcDay(cycle)));
        var value = ((int)digest[0] << 8) | digest[1];
        return TimeSpan.FromSeconds(value % 3601);
    }

    private DateTime GetEffectiveAllowedAtLocked()
    {
        var allowedAt = _state.NextAllowedSyncAtUtc ?? DateTime.MinValue;
        if (_state.LastSuccessfulSyncAtUtc.HasValue)
        {
            var localLimit = _state.LastSuccessfulSyncAtUtc.Value + SyncProtocol.ManualSyncInterval;
            if (localLimit > allowedAt) allowedAt = localLimit;
        }
        return allowedAt;
    }

    private void RefreshUtcDayWindowsLocked(DateTime now)
    {
        var utcDay = UtcDay(now);
        if (!string.Equals(_state.QuotaUtcDay, utcDay, StringComparison.Ordinal))
        {
            _state.QuotaUtcDay = utcDay;
            _state.RemainingDailySyncs = 8;
        }
        if (!string.Equals(_state.AutomaticFailureUtcDay, utcDay, StringComparison.Ordinal))
        {
            _state.AutomaticFailureUtcDay = utcDay;
            _state.AutomaticFailureCount = 0;
        }
    }

    private static string UtcDay(DateTime value)
        => value.ToUniversalTime().ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);

    private static DateTime NextUtcMidnight(DateTime value)
        => value.ToUniversalTime().Date.AddDays(1);

    private static DateTime? NormalizeUtc(DateTime? value)
    {
        if (!value.HasValue) return null;
        return value.Value.Kind == DateTimeKind.Utc ? value : value.Value.ToUniversalTime();
    }

    private static string? ValidateReplacementDeviceId(string deviceId, string? replaceDeviceId)
    {
        if (string.IsNullOrWhiteSpace(replaceDeviceId)) return null;
        if (!string.Equals(deviceId, replaceDeviceId, StringComparison.Ordinal))
        {
            throw new CryptographicException(
                "Recovery can only replace this installation's existing device identity.");
        }
        return replaceDeviceId;
    }

    private static RecoverVaultRequest CreateRecoverRequest(
        PendingSyncSecrets pending,
        string? replaceDeviceId,
        string recoveryAuthToken)
        => new()
        {
            DeviceId = pending.DeviceId,
            DeviceToken = pending.DeviceToken,
            ReplaceDeviceId = ValidateReplacementDeviceId(pending.DeviceId, replaceDeviceId),
            RecoveryAuthToken = recoveryAuthToken
        };

    private static string NormalizeProfileValue(string value, int maximumUtf8Bytes)
    {
        var normalized = (value ?? string.Empty).Trim();
        while (normalized.Length > 0 && Encoding.UTF8.GetByteCount(normalized) > maximumUtf8Bytes)
        {
            var charactersToRemove = normalized.Length >= 2 &&
                                     char.IsLowSurrogate(normalized[normalized.Length - 1]) &&
                                     char.IsHighSurrogate(normalized[normalized.Length - 2])
                ? 2
                : 1;
            normalized = normalized.Substring(0, normalized.Length - charactersToRemove);
        }
        return string.IsNullOrWhiteSpace(normalized) ? "Windows device" : normalized;
    }

    private SyncState NewEnabledState(string vaultId, string deviceId, string displayName, int activeDeviceCount)
    {
        var state = new SyncState
        {
            IsEnabled = true,
            NeedsRepair = false,
            NeedsBootstrap = true,
            NeedsHistoryBootstrap = false,
            VaultId = vaultId,
            DeviceId = deviceId,
            DeviceName = NormalizeProfileValue(displayName, 128),
            InstallationDeviceId = deviceId,
            Platform = "windows",
            ActiveDeviceCount = Math.Max(1, activeDeviceCount),
            RemainingDailySyncs = 8,
            LocalRecords = new Dictionary<string, LocalSyncRecordState>(StringComparer.Ordinal)
        };
        state.Devices.Add(CreateCurrentDeviceInfo(state));
        return state;
    }

    private static SyncDeviceInfo CreateCurrentDeviceInfo(SyncState state)
    {
        return new SyncDeviceInfo
        {
            DeviceId = state.DeviceId,
            DisplayName = state.DeviceName,
            Platform = state.Platform,
            LastSyncAt = state.LastSuccessfulSyncAtUtc,
            IsCurrent = true,
            IsRevoked = false
        };
    }

    private static SyncDeviceInfo CloneDevice(SyncDeviceInfo value)
    {
        return new SyncDeviceInfo
        {
            DeviceId = value.DeviceId,
            DisplayName = value.DisplayName,
            Platform = value.Platform,
            LastSyncAt = value.LastSyncAt,
            IsCurrent = value.IsCurrent,
            IsRevoked = value.IsRevoked
        };
    }

    private static string NonEmptyProfileValue(string? preferred, string? fallback, string defaultValue)
    {
        var value = (preferred ?? string.Empty).Trim();
        if (value.Length > 0) return value;
        value = (fallback ?? string.Empty).Trim();
        return value.Length > 0 ? value : defaultValue;
    }

    private void PrepareDamagedStateForSetup()
    {
        lock (_stateLock)
        {
            if (!_stateStore.NeedsRepair) return;
            var installationDeviceId = string.IsNullOrWhiteSpace(_state.InstallationDeviceId)
                ? Guid.NewGuid().ToString("D")
                : _state.InstallationDeviceId;
            _stateStore.Delete();
            _state = new SyncState { InstallationDeviceId = installationDeviceId };
            _stateStore.Save(_state);
            _lastError = null;
        }
    }

    private void DisableLocally(string? replacementCandidateDeviceId)
    {
        lock (_stateLock)
        {
            _automaticTimer?.Change(Timeout.Infinite, Timeout.Infinite);
            _stateRefreshTimer?.Change(Timeout.Infinite, Timeout.Infinite);
            _state = new SyncState
            {
                InstallationDeviceId = Guid.NewGuid().ToString("D"),
                ReplacementCandidateDeviceId = Guid.TryParse(replacementCandidateDeviceId, out _)
                    ? replacementCandidateDeviceId
                    : null
            };
            _lastError = null;
            _stateStore.Delete();
            _credentialStore.Delete();
            _pendingSecretsStore.Delete();
            _stateStore.Save(_state);
        }
        _remoteCache.Clear();
        RaiseStatusChanged();
    }

    private ISyncTransport RequireTransport()
        => _transport ?? throw new InvalidOperationException("Sync service is not configured in this build.");

    private SyncCredentials RequireCredentials()
    {
        string vaultId;
        string deviceId;
        lock (_stateLock)
        {
            vaultId = _state.VaultId;
            deviceId = _state.DeviceId;
        }
        try
        {
            return _credentialStore.Load(vaultId, deviceId);
        }
        catch (CryptographicException)
        {
            lock (_stateLock)
            {
                _state.NeedsRepair = true;
                _lastError = "The local sync configuration needs repair.";
                if (!_stateStore.NeedsRepair) _stateStore.Save(_state);
            }
            RaiseStatusChanged();
            throw;
        }
    }

    private void EnsureEnabled()
    {
        lock (_stateLock) EnsureEnabledLocked();
    }

    private void EnsureEnabledLocked()
    {
        if (!_state.IsEnabled) throw new InvalidOperationException("Sync is not enabled on this device.");
        if (_state.NeedsRepair) throw new InvalidOperationException("The local sync configuration needs repair.");
    }

    private void EnsureNotEnabled()
    {
        lock (_stateLock)
        {
            if (_state.IsEnabled && !_state.NeedsRepair)
            {
                throw new InvalidOperationException("Sync is already enabled on this device.");
            }
        }
    }

    private void EnsureCanCreate()
    {
        lock (_stateLock)
        {
            if (_state.IsEnabled || _state.NeedsRepair || _credentialStore.Exists)
            {
                throw new InvalidOperationException("Repair or clear the existing sync configuration first.");
            }
        }
    }

    private void SaveRecoveredStateLocked()
    {
        if (_stateStore.NeedsRepair) _stateStore.ReplaceAfterRepair(_state);
        else _stateStore.Save(_state);
    }

    private bool IsLocalDevice(string deviceId)
    {
        lock (_stateLock) return string.Equals(deviceId, _state.DeviceId, StringComparison.Ordinal);
    }

    private string GetVaultId()
    {
        lock (_stateLock) return _state.VaultId;
    }

    private void OnRemoteCacheChanged() => _statsManager.NotifyRemoteStatsChanged();

    private void OnLocalStatsReset()
    {
        lock (_stateLock)
        {
            foreach (var record in _state.LocalRecords.Values) record.ContentHash = string.Empty;
            if (_state.IsEnabled && !_state.NeedsRepair) _stateStore.Save(_state);
        }
    }

    private void SetBusy(bool value)
    {
        lock (_stateLock) _isBusy = value;
        RaiseStatusChanged();
    }

    private void RaiseStatusChanged()
    {
        try { StatusChanged?.Invoke(); }
        catch (Exception ex) { System.Diagnostics.Debug.WriteLine($"Sync status observer failed: {ex.Message}"); }
    }

    private static string SafeErrorMessage(Exception exception)
    {
        return exception switch
        {
            SyncRateLimitedException => exception.Message,
            SyncTransportException => exception.Message,
            CryptographicException => "Encrypted sync data could not be verified.",
            _ => "Sync could not be completed. Please try again later."
        };
    }

    public void Dispose()
    {
        lock (_stateLock)
        {
            if (_disposed) return;
            _disposed = true;
        }
        _lifetimeCancellation.Cancel();
        _automaticTimer?.Dispose();
        _stateRefreshTimer?.Dispose();
        _remoteCache.Changed -= OnRemoteCacheChanged;
        _statsManager.LocalStatsReset -= OnLocalStatsReset;
        if (_ownsTransport) _transport?.Dispose();
        _lifetimeCancellation.Dispose();
        _operationGate.Dispose();
    }

    private sealed class PreparedSync
    {
        public SyncRequest Request { get; set; } = new();
        public EncryptedSyncRecord? LastAcknowledgedCurrentSnapshot { get; set; }
    }
}

public sealed class SyncRateLimitedException : Exception
{
    public DateTime AllowedAtUtc { get; }

    public SyncRateLimitedException(DateTime allowedAtUtc, Exception? innerException = null)
        : base("Sync is temporarily limited. Try again after " +
               allowedAtUtc.ToLocalTime().ToString("g", CultureInfo.CurrentCulture) + ".", innerException)
    {
        AllowedAtUtc = allowedAtUtc;
    }
}
