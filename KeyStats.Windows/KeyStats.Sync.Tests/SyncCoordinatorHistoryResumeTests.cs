using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Reflection;
using System.Runtime.Serialization;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using KeyStats.Models;
using KeyStats.Services;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KeyStats.Sync.Tests;

[TestClass]
public sealed class SyncCoordinatorHistoryResumeTests
{
    [TestMethod]
    public void StartupWithPrimaryCache_PreservesTrustedHistoryCursor()
    {
        TestPlatform.RequireWindows();
        using var directory = new TestDirectory();
        SaveSynchronizedState(directory.Path, cursor: 1295, isEnabled: true);
        SaveCredentials(directory.Path);
        var cache = new RemoteShardCache(directory.Path);
        cache.Apply(CreateCachedRecord(revision: 2, ciphertextHash: "hash-2", keyPresses: 20));
        using var transport = new RecordingTransport();

        using var coordinator = CreateCoordinator(directory.Path, transport);

        var state = new SyncStateStore(directory.Path).Load();
        Assert.AreEqual(1295L, state.HistoryCursor);
        Assert.IsFalse(state.NeedsHistoryBootstrap);
    }

    [TestMethod]
    public async Task StartupWithRecoveredCache_ReplaysHistoryFromZeroAndPreservesLocalDataAndCredentials()
    {
        TestPlatform.RequireWindows();
        using var directory = new TestDirectory();
        SaveSynchronizedState(directory.Path, cursor: 1295, isEnabled: true);
        SaveCredentials(directory.Path);
        var localStats = new DailyStats(new DateTime(2026, 7, 18)) { KeyPresses = 73 };
        var statsManager = CreateStatsManager(localStats);
        var crypto = new SyncCrypto();
        var vaultSeed = new byte[16];
        var dataKey = crypto.DeriveDataKey(vaultSeed);
        var indexKey = crypto.DeriveIndexKey(vaultSeed);
        const string remoteDeviceId = "remote-device";
        const string localDay = "2026-07-13";
        var recordId = crypto.CreateRecordId(indexKey, remoteDeviceId, localDay);
        var revision2 = CreateEncryptedRecord(
            crypto, dataKey, recordId, remoteDeviceId, localDay, revision: 2, keyPresses: 20);
        var revision3 = CreateEncryptedRecord(
            crypto, dataKey, recordId, remoteDeviceId, localDay, revision: 3, keyPresses: 30);
        SeedRolledBackCache(directory.Path, revision2, keyPresses: 20);
        var transport = new RecordingTransport(new HistoryResponse
        {
            Cursor = 1295,
            HasMore = false,
            Changes = new List<SyncHistoryChange>
            {
                new() { Cursor = 1157, RecordId = recordId, Record = revision2 },
                new() { Cursor = 1158, RecordId = recordId, Record = revision3 }
            }
        });

        using (var coordinator = new SyncCoordinator(statsManager, directory.Path, null, "test", transport))
        {
            var resetState = new SyncStateStore(directory.Path).Load();
            Assert.AreEqual(0L, resetState.HistoryCursor);
            Assert.IsTrue(resetState.NeedsHistoryBootstrap);
            Assert.IsTrue(resetState.IsEnabled);
            Assert.AreEqual(73, statsManager.CurrentStats.KeyPresses);
            var credentials = new SyncCredentialStore(directory.Path).Load("vault-id", "device-id");
            Assert.AreEqual("device-id.test-token", credentials.DeviceToken);
            CollectionAssert.AreEqual(vaultSeed, credentials.VaultSeed);

            await coordinator.RetryBootstrapAsync().ConfigureAwait(false);
        }

        CollectionAssert.AreEqual(new long[] { 0 }, transport.HistoryCursors.ToArray());
        var completed = new SyncStateStore(directory.Path).Load();
        Assert.AreEqual(1295L, completed.HistoryCursor);
        Assert.IsFalse(completed.NeedsHistoryBootstrap);
        var cached = new RemoteShardCache(directory.Path).GetAll().Single(record => record.RecordId == recordId);
        Assert.AreEqual(3L, cached.Revision);
        Assert.AreEqual(30L, cached.Plaintext.KeyPresses);
        Assert.AreEqual(73, statsManager.CurrentStats.KeyPresses);
    }

    [TestMethod]
    public void StartupWithRecoveredCache_WhenSyncDisabled_DoesNotEnableOrBootstrapSync()
    {
        TestPlatform.RequireWindows();
        using var directory = new TestDirectory();
        SaveSynchronizedState(directory.Path, cursor: 1295, isEnabled: false);
        SeedRolledBackCache(
            directory.Path,
            CreateEncryptedRecordForCacheSeed(revision: 2, keyPresses: 20),
            keyPresses: 20);
        using var transport = new RecordingTransport();

        using var coordinator = CreateCoordinator(directory.Path, transport);

        var state = new SyncStateStore(directory.Path).Load();
        Assert.IsFalse(state.IsEnabled);
        Assert.AreEqual(1295L, state.HistoryCursor);
        Assert.IsFalse(state.NeedsHistoryBootstrap);
    }

    [TestMethod]
    public async Task HistoryFailure_PersistsPageCursorAndRestartNeverPostsSync()
    {
        TestPlatform.RequireWindows();
        using var directory = new TestDirectory();
        SaveHistoryOnlyState(directory.Path, cursor: 7);
        SaveCredentials(directory.Path);

        var firstTransport = new RecordingTransport(
            new HistoryResponse { Cursor = 11, HasMore = true },
            new SyncTransportException(
                HttpStatusCode.ServiceUnavailable,
                "History is temporarily unavailable.",
                null));
        using (var firstCoordinator = CreateCoordinator(directory.Path, firstTransport))
        {
            try
            {
                await firstCoordinator.RetryBootstrapAsync().ConfigureAwait(false);
                Assert.Fail("The second history page should fail.");
            }
            catch (SyncTransportException ex)
            {
                Assert.AreEqual(HttpStatusCode.ServiceUnavailable, ex.StatusCode);
            }
        }

        var interrupted = new SyncStateStore(directory.Path).Load();
        Assert.IsFalse(interrupted.NeedsBootstrap);
        Assert.IsTrue(interrupted.NeedsHistoryBootstrap);
        Assert.AreEqual(11L, interrupted.HistoryCursor);
        Assert.AreEqual(0, firstTransport.SyncCallCount);
        CollectionAssert.AreEqual(new long[] { 7, 11 }, firstTransport.HistoryCursors.ToArray());

        var resumedTransport = new RecordingTransport(
            new HistoryResponse { Cursor = 15, HasMore = false });
        using (var resumedCoordinator = CreateCoordinator(directory.Path, resumedTransport))
        {
            await resumedCoordinator.RetryBootstrapAsync().ConfigureAwait(false);
        }

        var completed = new SyncStateStore(directory.Path).Load();
        Assert.IsFalse(completed.NeedsBootstrap);
        Assert.IsFalse(completed.NeedsHistoryBootstrap);
        Assert.AreEqual(15L, completed.HistoryCursor);
        Assert.AreEqual(0, resumedTransport.SyncCallCount);
        CollectionAssert.AreEqual(new long[] { 11 }, resumedTransport.HistoryCursors.ToArray());
    }

    private static SyncCoordinator CreateCoordinator(string dataFolder, ISyncTransport transport)
    {
        var statsManager = (StatsManager)FormatterServices.GetUninitializedObject(typeof(StatsManager));
        return new SyncCoordinator(statsManager, dataFolder, null, "test", transport);
    }

    private static StatsManager CreateStatsManager(DailyStats currentStats)
    {
        var manager = (StatsManager)FormatterServices.GetUninitializedObject(typeof(StatsManager));
        SetField(manager, "_lock", new object());
        SetField(manager, "<CurrentStats>k__BackingField", currentStats);
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

    private static void SaveHistoryOnlyState(string dataFolder, long cursor)
    {
        new SyncStateStore(dataFolder).Save(new SyncState
        {
            IsEnabled = true,
            NeedsBootstrap = false,
            NeedsHistoryBootstrap = true,
            VaultId = "vault-id",
            DeviceId = "device-id",
            DeviceName = "Test device",
            ActiveDeviceCount = 2,
            RemainingDailySyncs = 8,
            LastSuccessfulSyncAtUtc = DateTime.UtcNow,
            HistoryCursor = cursor
        });
    }

    private static void SaveCredentials(string dataFolder)
    {
        new SyncCredentialStore(dataFolder).Save(new SyncCredentials
        {
            VaultId = "vault-id",
            DeviceId = "device-id",
            VaultSeed = new byte[16],
            DeviceToken = "device-id.test-token"
        });
    }

    private static void SaveSynchronizedState(string dataFolder, long cursor, bool isEnabled)
    {
        new SyncStateStore(dataFolder).Save(new SyncState
        {
            IsEnabled = isEnabled,
            NeedsBootstrap = false,
            NeedsHistoryBootstrap = false,
            VaultId = isEnabled ? "vault-id" : string.Empty,
            DeviceId = isEnabled ? "device-id" : string.Empty,
            InstallationDeviceId = "11111111-1111-4111-8111-111111111111",
            DeviceName = "Test device",
            ActiveDeviceCount = isEnabled ? 2 : 0,
            RemainingDailySyncs = 8,
            LastSuccessfulSyncAtUtc = DateTime.UtcNow,
            HistoryCursor = cursor
        });
    }

    private static void SeedRolledBackCache(
        string dataFolder,
        EncryptedSyncRecord revision2,
        long keyPresses)
    {
        var cache = new RemoteShardCache(dataFolder);
        cache.Apply(CreateCachedRecord(revision: 1, ciphertextHash: "hash-1", keyPresses: 10,
            recordId: revision2.RecordId, deviceId: revision2.DeviceId));
        cache.Apply(CreateCachedRecord(revision2.Revision, revision2.CiphertextHash, keyPresses,
            revision2.RecordId, revision2.DeviceId));
        cache.Apply(CreateCachedRecord(revision: 3, ciphertextHash: "discarded-primary", keyPresses: 25,
            recordId: revision2.RecordId, deviceId: revision2.DeviceId));
        File.WriteAllText(Path.Combine(dataFolder, "sync_cache.json"), "damaged");
    }

    private static CachedRemoteRecord CreateCachedRecord(
        long revision,
        string ciphertextHash,
        long keyPresses,
        string recordId = "record-1",
        string deviceId = "remote-device")
    {
        return new CachedRemoteRecord
        {
            RecordId = recordId,
            DeviceId = deviceId,
            Revision = revision,
            CiphertextHash = ciphertextHash,
            Plaintext = new CoreDaySnapshotV1
            {
                DeviceId = deviceId,
                LocalDay = "2026-07-13",
                Revision = revision,
                KeyPresses = keyPresses,
                KeyPressCounts = new Dictionary<string, long>(StringComparer.Ordinal) { ["A"] = keyPresses },
                Clicks = new CoreClickSnapshotV1()
            }
        };
    }

    private static EncryptedSyncRecord CreateEncryptedRecord(
        SyncCrypto crypto,
        byte[] dataKey,
        string recordId,
        string deviceId,
        string localDay,
        long revision,
        long keyPresses)
    {
        var snapshot = new CoreDaySnapshotV1
        {
            DeviceId = deviceId,
            LocalDay = localDay,
            Revision = revision,
            KeyPresses = keyPresses,
            KeyPressCounts = new Dictionary<string, long>(StringComparer.Ordinal) { ["A"] = keyPresses },
            Clicks = new CoreClickSnapshotV1()
        };
        var bytes = JsonSerializer.SerializeToUtf8Bytes(snapshot, new JsonSerializerOptions
        {
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase
        });
        return crypto.EncryptRecord(dataKey, "vault-id", deviceId, recordId, revision, bytes);
    }

    private static EncryptedSyncRecord CreateEncryptedRecordForCacheSeed(long revision, long keyPresses)
    {
        var crypto = new SyncCrypto();
        var dataKey = crypto.DeriveDataKey(new byte[16]);
        const string deviceId = "remote-device";
        const string localDay = "2026-07-13";
        var recordId = crypto.CreateRecordId(crypto.DeriveIndexKey(new byte[16]), deviceId, localDay);
        return CreateEncryptedRecord(crypto, dataKey, recordId, deviceId, localDay, revision, keyPresses);
    }

    private sealed class RecordingTransport : ISyncTransport
    {
        private readonly Queue<object> _historyResults;

        public int SyncCallCount { get; private set; }
        public List<long> HistoryCursors { get; } = new();

        public RecordingTransport(params object[] historyResults)
        {
            _historyResults = new Queue<object>(historyResults);
        }

        public Task<SyncResponse> SyncAsync(
            SyncRequest request,
            string deviceToken,
            string idempotencyKey,
            CancellationToken cancellationToken)
        {
            SyncCallCount++;
            throw new AssertFailedException("History-only recovery must not POST /sync.");
        }

        public Task<HistoryResponse> GetHistoryAsync(
            long cursor,
            string deviceToken,
            CancellationToken cancellationToken)
        {
            HistoryCursors.Add(cursor);
            if (_historyResults.Count == 0)
            {
                throw new AssertFailedException("The test did not configure another history response.");
            }
            var result = _historyResults.Dequeue();
            if (result is Exception exception) return Task.FromException<HistoryResponse>(exception);
            return Task.FromResult((HistoryResponse)result);
        }

        public Task<SyncStateResponse> GetStateAsync(
            string deviceToken,
            CancellationToken cancellationToken) => throw Unexpected();

        public Task<CreateVaultResponse> CreateVaultAsync(
            CreateVaultRequest request,
            CancellationToken cancellationToken) => throw Unexpected();

        public Task<RecoverVaultResponse> RecoverVaultAsync(
            RecoverVaultRequest request,
            CancellationToken cancellationToken) => throw Unexpected();

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

        public Task RevokeDeviceAsync(
            string deviceId,
            string deviceToken,
            CancellationToken cancellationToken) => throw Unexpected();

        public Task DeleteVaultAsync(
            string deviceToken,
            CancellationToken cancellationToken) => throw Unexpected();

        public void Dispose()
        {
        }

        private static InvalidOperationException Unexpected()
            => new("Unexpected transport call in history resume test.");
    }
}
