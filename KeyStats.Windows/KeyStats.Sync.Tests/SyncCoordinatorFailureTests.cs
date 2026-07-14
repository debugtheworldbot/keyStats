using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Reflection;
using System.Runtime.Serialization;
using System.Threading;
using System.Threading.Tasks;
using KeyStats.Models;
using KeyStats.Services;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KeyStats.Sync.Tests;

[TestClass]
public sealed class SyncCoordinatorFailureTests
{
    [TestMethod]
    public async Task SingleDeviceConflict_PersistsGateAndStopsOrdinaryScheduling()
    {
        TestPlatform.RequireWindows();
        using var directory = new TestDirectory();
        SaveEnabledState(directory.Path);
        SaveCredentials(directory.Path);
        var failure = new SyncTransportException(
            HttpStatusCode.Conflict,
            "Single-device sync is disabled.",
            null,
            errorCode: "single_device_sync_disabled",
            activeDeviceCount: 1);
        using var transport = new FailureTransport(failure);
        using var coordinator = CreateCoordinator(directory.Path, transport);
        coordinator.Start();

        await coordinator.SyncNowAsync().ConfigureAwait(false);

        var persisted = new SyncStateStore(directory.Path).Load();
        var status = coordinator.GetStatus();
        Assert.AreEqual(1, transport.SyncCallCount);
        Assert.AreEqual(1, persisted.ActiveDeviceCount);
        Assert.IsNull(persisted.NextAutomaticSyncAtUtc);
        Assert.AreEqual(1, status.ActiveDeviceCount);
        Assert.IsFalse(status.CanSync);
        Assert.IsFalse(status.CanManualSync);
        Assert.IsNull(status.LastError);
    }

    [TestMethod]
    public async Task SingleDeviceCodeWithoutAuthoritativeCount_RemainsAConflict()
    {
        TestPlatform.RequireWindows();
        using var directory = new TestDirectory();
        SaveEnabledState(directory.Path);
        SaveCredentials(directory.Path);
        using var transport = new FailureTransport(new SyncTransportException(
            HttpStatusCode.Conflict,
            "Untrusted single-device detail.",
            null,
            errorCode: "single_device_sync_disabled"));
        using var coordinator = CreateCoordinator(directory.Path, transport);

        await Assert.ThrowsExactlyAsync<SyncTransportException>(
            () => coordinator.SyncNowAsync()).ConfigureAwait(false);

        Assert.AreEqual(2, new SyncStateStore(directory.Path).Load().ActiveDeviceCount);
        Assert.IsFalse(coordinator.GetStatus().CanManualSync);
        Assert.IsNotNull(coordinator.GetStatus().LastError);
    }

    [TestMethod]
    public async Task ManualTransportFailure_AddsSixtySecondRetryDelay()
    {
        TestPlatform.RequireWindows();
        using var directory = new TestDirectory();
        SaveEnabledState(directory.Path);
        SaveCredentials(directory.Path);
        using var transport = new FailureTransport(new SyncTransportException(
            HttpStatusCode.ServiceUnavailable,
            "Service unavailable.",
            null,
            errorCode: "temporarily_unavailable"));
        using var coordinator = CreateCoordinator(directory.Path, transport);
        var before = DateTime.UtcNow;

        await Assert.ThrowsExactlyAsync<SyncTransportException>(
            () => coordinator.SyncNowAsync()).ConfigureAwait(false);

        var after = DateTime.UtcNow;
        var retryAt = new SyncStateStore(directory.Path).Load().NextAllowedSyncAtUtc;
        Assert.IsTrue(retryAt.HasValue);
        Assert.IsTrue(retryAt.Value >= before.AddSeconds(55));
        Assert.IsTrue(retryAt.Value <= after.AddSeconds(65));
        Assert.IsFalse(coordinator.GetStatus().CanManualSync);
    }

    [TestMethod]
    public void AutomaticFailures_RetryAfterOneHourThenSixHoursAndStopForUtcDay()
    {
        TestPlatform.RequireWindows();
        using var directory = new TestDirectory();
        SaveEnabledState(directory.Path);
        SaveCredentials(directory.Path);
        using var coordinator = new SyncCoordinator(
            CreateStatsManager(),
            directory.Path,
            null,
            "test");
        var method = typeof(SyncCoordinator).GetMethod(
            "RecordAutomaticFailureLocked",
            BindingFlags.Instance | BindingFlags.NonPublic);
        var stateField = typeof(SyncCoordinator).GetField(
            "_state",
            BindingFlags.Instance | BindingFlags.NonPublic);
        Assert.IsNotNull(method);
        Assert.IsNotNull(stateField);

        var firstStart = new DateTime(2026, 7, 14, 12, 0, 0, DateTimeKind.Utc);
        method!.Invoke(coordinator, new object?[] { firstStart });
        var state = (SyncState)stateField!.GetValue(coordinator)!;
        Assert.AreEqual(1, state.AutomaticFailureCount);
        Assert.IsTrue(state.NextAutomaticSyncAtUtc.HasValue);
        Assert.IsTrue(state.NextAutomaticSyncAtUtc.Value >= firstStart.AddMinutes(59));
        Assert.IsTrue(state.NextAutomaticSyncAtUtc.Value <= firstStart.AddMinutes(61));

        var secondStart = firstStart.AddSeconds(1);
        method.Invoke(coordinator, new object?[] { secondStart });
        Assert.AreEqual(2, state.AutomaticFailureCount);
        Assert.IsTrue(state.NextAutomaticSyncAtUtc.HasValue);
        Assert.IsTrue(state.NextAutomaticSyncAtUtc.Value >= secondStart.AddHours(6).AddMinutes(-1));
        Assert.IsTrue(state.NextAutomaticSyncAtUtc.Value <= secondStart.AddHours(6).AddMinutes(1));

        var thirdStart = secondStart.AddSeconds(1);
        var nextUtcMidnight = thirdStart.Date.AddDays(1);
        method.Invoke(coordinator, new object?[] { thirdStart });
        Assert.AreEqual(SyncProtocol.MaximumAutomaticFailuresPerUtcDay, state.AutomaticFailureCount);
        Assert.IsTrue(state.NextAutomaticSyncAtUtc.HasValue);
        Assert.IsTrue(state.NextAutomaticSyncAtUtc.Value >= nextUtcMidnight);
        Assert.IsTrue(state.NextAutomaticSyncAtUtc.Value <= nextUtcMidnight.AddHours(1));
    }

    [TestMethod]
    public async Task Transport_PreservesValidatedSingleDeviceConflictDetails()
    {
        using var transport = new CloudflareSyncTransport(
            new Uri("https://unit-tests.workers.dev/"),
            new StaticResponseHandler(new HttpResponseMessage(HttpStatusCode.Conflict)
            {
                Content = new StringContent(
                    "{\"code\":\"single_device_sync_disabled\",\"activeDeviceCount\":1," +
                    "\"requestId\":\"not-exposed\"}")
            }));

        var exception = await Assert.ThrowsExactlyAsync<SyncTransportException>(() =>
            transport.SyncAsync(
                new SyncRequest { Reason = "manual" },
                "device.test-token",
                "idempotency-key",
                CancellationToken.None)).ConfigureAwait(false);

        Assert.AreEqual(HttpStatusCode.Conflict, exception.StatusCode);
        Assert.AreEqual("single_device_sync_disabled", exception.ErrorCode);
        Assert.AreEqual(1, exception.ActiveDeviceCount!.Value);
        Assert.AreEqual(-1, exception.Message.IndexOf("not-exposed", StringComparison.Ordinal));
    }

    [TestMethod]
    public async Task Transport_PreservesEncryptedMaximumDeviceRecoveryOptions()
    {
        var vaultId = "11111111-1111-4111-8111-111111111111";
        var deviceIds = new[]
        {
            "22222222-2222-4222-8222-222222222222",
            "33333333-3333-4333-8333-333333333333",
            "44444444-4444-4444-8444-444444444444",
            "55555555-5555-4555-8555-555555555555",
            "66666666-6666-4666-8666-666666666666"
        };
        var body = "{\"code\":\"maximum_devices\",\"vaultId\":\"" + vaultId +
                   "\",\"devices\":[" + string.Join(",", deviceIds.Select(id =>
                       "{\"deviceId\":\"" + id +
                       "\",\"encryptedDeviceProfile\":null,\"revoked\":false}")) + "]}";
        using var transport = new CloudflareSyncTransport(
            new Uri("https://unit-tests.workers.dev/"),
            new StaticResponseHandler(new HttpResponseMessage(HttpStatusCode.Conflict)
            {
                Content = new StringContent(body)
            }));

        var exception = await Assert.ThrowsExactlyAsync<SyncTransportException>(() =>
            transport.RecoverVaultAsync(
                new RecoverVaultRequest(),
                CancellationToken.None)).ConfigureAwait(false);

        Assert.AreEqual("maximum_devices", exception.ErrorCode);
        Assert.AreEqual(vaultId, exception.VaultId);
        Assert.AreEqual(SyncProtocol.MaximumDevices, exception.Devices.Count);
        CollectionAssert.AreEqual(
            deviceIds,
            exception.Devices.Select(device => device.DeviceId).ToArray());
    }

    [TestMethod]
    public async Task StartupWithCredentialBackupForAnotherDevice_BlocksVaultDeletion()
    {
        TestPlatform.RequireWindows();
        using var directory = new TestDirectory();
        SaveEnabledState(directory.Path);
        var credentialStore = new SyncCredentialStore(directory.Path);
        credentialStore.Save(new SyncCredentials
        {
            VaultSeed = new byte[16],
            DeviceToken = "old-device.old-token"
        });
        credentialStore.Save(new SyncCredentials
        {
            VaultSeed = new byte[16],
            DeviceToken = "device-id.current-token"
        });
        File.WriteAllBytes(
            Path.Combine(directory.Path, "sync_credentials.bin"),
            new byte[] { 1, 2, 3 });
        using var transport = new FailureTransport(new InvalidOperationException("Not used."));
        using var coordinator = CreateCoordinator(directory.Path, transport);

        Assert.IsTrue(coordinator.GetStatus().NeedsRepair);
        await Assert.ThrowsExactlyAsync<InvalidOperationException>(
            () => coordinator.DeleteVaultAsync()).ConfigureAwait(false);
        Assert.AreEqual(0, transport.DeleteVaultCallCount);
    }

    [TestMethod]
    public async Task CredentialSwapAfterStartup_BlocksVaultDeletionAndPersistsRepairState()
    {
        TestPlatform.RequireWindows();
        using var directory = new TestDirectory();
        SaveEnabledState(directory.Path);
        SaveCredentials(directory.Path);
        using var transport = new FailureTransport(new InvalidOperationException("Not used."));
        using var coordinator = CreateCoordinator(directory.Path, transport);
        new SyncCredentialStore(directory.Path).Save(new SyncCredentials
        {
            VaultSeed = new byte[16],
            DeviceToken = "other-device.other-token"
        });

        await Assert.ThrowsExactlyAsync<System.Security.Cryptography.CryptographicException>(
            () => coordinator.DeleteVaultAsync()).ConfigureAwait(false);

        Assert.AreEqual(0, transport.DeleteVaultCallCount);
        Assert.IsTrue(coordinator.GetStatus().NeedsRepair);
        Assert.IsTrue(new SyncStateStore(directory.Path).Load().NeedsRepair);
    }

    [TestMethod]
    public async Task SingleDeviceStateRefresh_UsesReadOnlyEndpointAndNeverPostsSync()
    {
        TestPlatform.RequireWindows();
        using var directory = new TestDirectory();
        var now = DateTime.UtcNow;
        new SyncStateStore(directory.Path).Save(new SyncState
        {
            IsEnabled = true,
            VaultId = "vault-id",
            DeviceId = "device-id",
            DeviceName = "Test device",
            ActiveDeviceCount = 1,
            RemainingDailySyncs = 8,
            LastSuccessfulSyncAtUtc = now,
            LastStateRefreshAtUtc = now.AddHours(-25)
        });
        SaveCredentials(directory.Path);
        using var transport = new FailureTransport(new InvalidOperationException("Not used."))
        {
            StateResponse = new SyncStateResponse
            {
                ServerTime = now,
                ActiveDeviceCount = 1,
                Devices = new List<DeviceSummary>
                {
                    new() { DeviceId = "device-id" }
                }
            }
        };
        using var coordinator = CreateCoordinator(directory.Path, transport);
        var refresh = typeof(SyncCoordinator).GetMethod(
            "RefreshStateAsync",
            BindingFlags.Instance | BindingFlags.NonPublic);
        Assert.IsNotNull(refresh);

        var task = (Task)refresh!.Invoke(
            coordinator,
            new object?[] { false, CancellationToken.None })!;
        await task.ConfigureAwait(false);

        Assert.AreEqual(1, transport.StateCallCount);
        Assert.AreEqual(0, transport.SyncCallCount);
        Assert.AreEqual(1, coordinator.GetStatus().ActiveDeviceCount);
        Assert.IsFalse(coordinator.GetStatus().CanManualSync);
        Assert.IsTrue(new SyncStateStore(directory.Path).Load().LastStateRefreshAtUtc.HasValue);
    }

    [TestMethod]
    public async Task FailedVaultDeletion_PersistsIntentAndReplaysSameBoundToken()
    {
        TestPlatform.RequireWindows();
        using var directory = new TestDirectory();
        SaveEnabledState(directory.Path);
        SaveCredentials(directory.Path);
        using (var failingTransport = new FailureTransport(new SyncTransportException(
                   HttpStatusCode.ServiceUnavailable,
                   "Service unavailable.",
                   null,
                   errorCode: "temporarily_unavailable"))
               { DeleteFailuresRemaining = 1 })
        using (var coordinator = CreateCoordinator(directory.Path, failingTransport))
        {
            await Assert.ThrowsExactlyAsync<SyncTransportException>(
                () => coordinator.DeleteVaultAsync()).ConfigureAwait(false);
            Assert.AreEqual(1, failingTransport.DeleteVaultCallCount);
            Assert.AreEqual("device-id.test-token", failingTransport.LastDeleteToken);
            Assert.IsTrue(new SyncStateStore(directory.Path).Load().PendingVaultDeletion);
            Assert.AreEqual(0, failingTransport.SyncCallCount);
        }

        using var replayTransport = new FailureTransport(new InvalidOperationException("Not used."));
        using var restarted = CreateCoordinator(directory.Path, replayTransport);
        Assert.IsTrue(restarted.GetStatus().CanRetryBootstrap);
        await restarted.RetryBootstrapAsync().ConfigureAwait(false);

        Assert.AreEqual(1, replayTransport.DeleteVaultCallCount);
        Assert.AreEqual("device-id.test-token", replayTransport.LastDeleteToken);
        Assert.AreEqual(0, replayTransport.SyncCallCount);
        var cleared = new SyncStateStore(directory.Path).Load();
        Assert.IsFalse(cleared.IsEnabled);
        Assert.IsFalse(cleared.PendingVaultDeletion);
        Assert.AreNotEqual("device-id", cleared.InstallationDeviceId);
    }

    [TestMethod]
    public async Task UnauthorizedRecovery_CanClearOnlyLocalSetupAndRetainsTakeoverIdentity()
    {
        TestPlatform.RequireWindows();
        using var directory = new TestDirectory();
        var installationId = "77777777-7777-4777-8777-777777777777";
        new SyncStateStore(directory.Path).Save(new SyncState
        {
            InstallationDeviceId = installationId
        });
        using var transport = new FailureTransport(new InvalidOperationException("Not used."))
        {
            RecoverFailure = new SyncTransportException(
                HttpStatusCode.Unauthorized,
                "Unauthorized.",
                null,
                errorCode: "unauthorized")
        };
        using var coordinator = CreateCoordinator(directory.Path, transport);
        var recoveryCode = new SyncCrypto().EncodeRecoveryCode(new byte[16]);

        await Assert.ThrowsExactlyAsync<SyncTransportException>(() =>
            coordinator.RecoverVaultAsync(recoveryCode, "Test device")).ConfigureAwait(false);

        var pending = new SyncStateStore(directory.Path).Load();
        Assert.AreEqual("recover", pending.PendingProvisioningKind);
        Assert.IsTrue(coordinator.BlocksImport);
        await coordinator.ClearLocalSyncConfigurationAsync().ConfigureAwait(false);

        var cleared = new SyncStateStore(directory.Path).Load();
        Assert.IsFalse(cleared.IsEnabled);
        Assert.IsNull(cleared.PendingProvisioningKind);
        Assert.AreNotEqual(installationId, cleared.InstallationDeviceId);
        Assert.IsNull(cleared.ReplacementCandidateDeviceId);
        Assert.IsFalse(coordinator.BlocksImport);
    }

    [TestMethod]
    public async Task ClearingRepair_RotatesInstallationAndRetainsOldDeviceAsTakeoverCandidate()
    {
        TestPlatform.RequireWindows();
        using var directory = new TestDirectory();
        var oldDeviceId = "88888888-8888-4888-8888-888888888888";
        new SyncStateStore(directory.Path).Save(new SyncState
        {
            IsEnabled = true,
            NeedsRepair = true,
            VaultId = "vault-id",
            DeviceId = oldDeviceId,
            InstallationDeviceId = oldDeviceId,
            DeviceName = "Broken device",
            ActiveDeviceCount = 2
        });
        using var transport = new FailureTransport(new InvalidOperationException("Not used."));
        using var coordinator = CreateCoordinator(directory.Path, transport);

        await coordinator.ClearLocalSyncConfigurationAsync().ConfigureAwait(false);

        var cleared = new SyncStateStore(directory.Path).Load();
        Assert.AreNotEqual(oldDeviceId, cleared.InstallationDeviceId);
        Assert.AreEqual(oldDeviceId, cleared.ReplacementCandidateDeviceId);
        Assert.IsFalse(coordinator.BlocksImport);

        transport.RecoverFailure = new SyncTransportException(
            HttpStatusCode.Unauthorized,
            "Unauthorized.",
            null,
            errorCode: "recovery_failed");
        var recoveryCode = new SyncCrypto().EncodeRecoveryCode(new byte[16]);
        await Assert.ThrowsExactlyAsync<SyncTransportException>(() =>
            coordinator.RecoverVaultAsync(recoveryCode, "Recovered device")).ConfigureAwait(false);
        Assert.IsNotNull(transport.LastRecoverRequest);
        Assert.AreEqual(oldDeviceId, transport.LastRecoverRequest!.DeviceId);
        Assert.AreEqual(oldDeviceId, transport.LastRecoverRequest.ReplaceDeviceId);
    }

    [TestMethod]
    public async Task MissingRecoveryReplacement_FallsBackOnceToFreshDeviceIdentity()
    {
        TestPlatform.RequireWindows();
        using var directory = new TestDirectory();
        var oldDeviceId = "99999999-9999-4999-8999-999999999999";
        new SyncStateStore(directory.Path).Save(new SyncState
        {
            InstallationDeviceId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            ReplacementCandidateDeviceId = oldDeviceId,
            LocalRecords = new Dictionary<string, LocalSyncRecordState>
            {
                ["2026-07-14"] = new() { LocalDay = "2026-07-14", Revision = 7 }
            }
        });
        using var transport = new FailureTransport(new InvalidOperationException("Not used."));
        transport.RecoverFailures.Enqueue(new SyncTransportException(
            HttpStatusCode.Conflict,
            "Replacement is not in this vault.",
            null,
            errorCode: "replace_device_not_found"));
        transport.RecoverFailures.Enqueue(new SyncTransportException(
            HttpStatusCode.ServiceUnavailable,
            "Service unavailable.",
            null,
            errorCode: "temporarily_unavailable"));
        using var coordinator = CreateCoordinator(directory.Path, transport);
        var recoveryCode = new SyncCrypto().EncodeRecoveryCode(new byte[16]);

        await Assert.ThrowsExactlyAsync<SyncTransportException>(() =>
            coordinator.RecoverVaultAsync(recoveryCode, "Recovered device")).ConfigureAwait(false);

        Assert.AreEqual(2, transport.RecoverRequests.Count);
        Assert.AreEqual(oldDeviceId, transport.RecoverRequests[0].DeviceId);
        Assert.AreEqual(oldDeviceId, transport.RecoverRequests[0].ReplaceDeviceId);
        Assert.AreNotEqual(oldDeviceId, transport.RecoverRequests[1].DeviceId);
        Assert.IsNull(transport.RecoverRequests[1].ReplaceDeviceId);
        Assert.IsTrue(transport.RecoverRequests[1].DeviceToken.StartsWith(
            transport.RecoverRequests[1].DeviceId + ".",
            StringComparison.Ordinal));
        var pendingState = new SyncStateStore(directory.Path).Load();
        Assert.IsNull(pendingState.ReplacementCandidateDeviceId);
        Assert.IsNull(pendingState.PendingProvisioningReplaceDeviceId);
        Assert.AreEqual(0, pendingState.LocalRecords.Count);
    }

    private static SyncCoordinator CreateCoordinator(string dataFolder, ISyncTransport transport)
        => new(CreateStatsManager(), dataFolder, null, "test", transport);

    private static StatsManager CreateStatsManager()
    {
        var manager = (StatsManager)FormatterServices.GetUninitializedObject(typeof(StatsManager));
        SetField(manager, "_lock", new object());
        SetField(manager, "<CurrentStats>k__BackingField", new DailyStats(DateTime.Today));
        SetField(
            manager,
            "<History>k__BackingField",
            new Dictionary<string, DailyStats>(StringComparer.Ordinal));
        return manager;
    }

    private static void SetField(object target, string name, object value)
    {
        var field = target.GetType().GetField(name, BindingFlags.Instance | BindingFlags.NonPublic);
        Assert.IsNotNull(field, "Missing test setup field: " + name);
        field!.SetValue(target, value);
    }

    private static void SaveEnabledState(string dataFolder)
    {
        var now = DateTime.UtcNow;
        new SyncStateStore(dataFolder).Save(new SyncState
        {
            IsEnabled = true,
            VaultId = "vault-id",
            DeviceId = "device-id",
            DeviceName = "Test device",
            ActiveDeviceCount = 2,
            RemainingDailySyncs = 8,
            QuotaUtcDay = now.ToString("yyyy-MM-dd"),
            LastSuccessfulSyncAtUtc = now.AddHours(-2)
        });
    }

    private static void SaveCredentials(string dataFolder)
    {
        new SyncCredentialStore(dataFolder).Save(new SyncCredentials
        {
            VaultSeed = new byte[16],
            DeviceToken = "device-id.test-token"
        });
    }

    private sealed class FailureTransport : ISyncTransport
    {
        private readonly Exception _failure;

        public int SyncCallCount { get; private set; }
        public int StateCallCount { get; private set; }
        public int DeleteVaultCallCount { get; private set; }
        public int DeleteFailuresRemaining { get; set; }
        public string? LastDeleteToken { get; private set; }
        public SyncStateResponse? StateResponse { get; set; }
        public Exception? RecoverFailure { get; set; }
        public RecoverVaultRequest? LastRecoverRequest { get; private set; }
        public Queue<Exception> RecoverFailures { get; } = new();
        public List<RecoverVaultRequest> RecoverRequests { get; } = new();

        public FailureTransport(Exception failure) => _failure = failure;

        public Task<SyncResponse> SyncAsync(
            SyncRequest request,
            string deviceToken,
            string idempotencyKey,
            CancellationToken cancellationToken)
        {
            SyncCallCount++;
            return Task.FromException<SyncResponse>(_failure);
        }

        public Task<CreateVaultResponse> CreateVaultAsync(
            CreateVaultRequest request,
            CancellationToken cancellationToken) => throw Unexpected();

        public Task<RecoverVaultResponse> RecoverVaultAsync(
            RecoverVaultRequest request,
            CancellationToken cancellationToken)
        {
            LastRecoverRequest = request;
            RecoverRequests.Add(request);
            if (RecoverFailures.Count > 0)
            {
                return Task.FromException<RecoverVaultResponse>(RecoverFailures.Dequeue());
            }
            return RecoverFailure != null
                ? Task.FromException<RecoverVaultResponse>(RecoverFailure!)
                : throw Unexpected();
        }

        public Task<CreatePairingSessionResponse> CreatePairingSessionAsync(
            CreatePairingSessionRequest request,
            CancellationToken cancellationToken) => throw Unexpected();

        public Task<JoinPairingSessionResponse> JoinPairingSessionAsync(
            string code,
            JoinPairingSessionRequest request,
            string deviceToken,
            CancellationToken cancellationToken) => throw Unexpected();

        public Task ApprovePairingSessionAsync(
            string sessionId,
            ApprovePairingSessionRequest request,
            string deviceToken,
            CancellationToken cancellationToken) => throw Unexpected();

        public Task<CompletePairingSessionResponse> CompletePairingSessionAsync(
            string sessionId,
            CompletePairingSessionRequest request,
            CancellationToken cancellationToken) => throw Unexpected();

        public Task<HistoryResponse> GetHistoryAsync(
            long cursor,
            string deviceToken,
            CancellationToken cancellationToken) => throw Unexpected();

        public Task<SyncStateResponse> GetStateAsync(
            string deviceToken,
            CancellationToken cancellationToken)
        {
            StateCallCount++;
            return StateResponse != null
                ? Task.FromResult(StateResponse)
                : Task.FromException<SyncStateResponse>(Unexpected());
        }

        public Task RevokeDeviceAsync(
            string deviceId,
            string deviceToken,
            CancellationToken cancellationToken) => throw Unexpected();

        public Task DeleteVaultAsync(string deviceToken, CancellationToken cancellationToken)
        {
            DeleteVaultCallCount++;
            LastDeleteToken = deviceToken;
            if (DeleteFailuresRemaining > 0)
            {
                DeleteFailuresRemaining--;
                return Task.FromException(_failure);
            }
            return Task.CompletedTask;
        }

        public void Dispose()
        {
        }

        private static InvalidOperationException Unexpected()
            => new("Unexpected transport call in sync failure test.");
    }

    private sealed class StaticResponseHandler : HttpMessageHandler
    {
        private readonly HttpResponseMessage _response;

        public StaticResponseHandler(HttpResponseMessage response) => _response = response;

        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken) => Task.FromResult(_response);
    }
}
