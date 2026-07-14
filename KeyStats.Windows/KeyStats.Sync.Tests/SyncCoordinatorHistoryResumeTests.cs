using System;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Runtime.Serialization;
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
            VaultSeed = new byte[16],
            DeviceToken = "device-id.test-token"
        });
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
