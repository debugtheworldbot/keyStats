using System;
using System.Linq;
using System.Reflection;
using KeyStats.Models;
using KeyStats.Services;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KeyStats.Sync.Tests;

[TestClass]
public sealed class SyncBatchPlannerTests
{
    [TestMethod]
    public void SyncProgress_AdvancesByDayAndStopsAtTotal()
    {
        var progress = new SyncProgress(18);

        progress.Advance(16);
        Assert.AreEqual(16, progress.CompletedDays);

        progress.Advance(16);
        Assert.AreEqual(18, progress.CompletedDays);
    }

    [DataTestMethod]
    [DataRow(0, 1, "0")]
    [DataRow(16, 1, "16")]
    [DataRow(17, 2, "16,1")]
    [DataRow(35, 3, "16,16,3")]
    public void Bootstrap_SplitsArchivesAndOnlyMarksFinalBatchComplete(
        int archiveCount,
        int expectedBatchCount,
        string expectedSizes)
    {
        var request = CreateRequest("bootstrap", archiveCount);

        var batches = SyncBatchPlanner.CreateBatches(request);

        Assert.AreEqual(expectedBatchCount, batches.Count);
        Assert.AreEqual(expectedSizes, string.Join(",", batches.Select(batch => batch.Archives.Count)));
        for (var index = 0; index < batches.Count - 1; index++)
        {
            Assert.IsFalse(batches[index].BootstrapComplete);
            Assert.IsNull(batches[index].CurrentSnapshot);
            Assert.IsNull(batches[index].EncryptedDeviceProfile);
        }
        Assert.IsTrue(batches[batches.Count - 1].BootstrapComplete);
        Assert.AreSame(request.CurrentSnapshot, batches[batches.Count - 1].CurrentSnapshot);
        Assert.AreSame(request.EncryptedDeviceProfile, batches[batches.Count - 1].EncryptedDeviceProfile);
        CollectionAssert.AreEqual(
            request.Archives.Select(record => record.RecordId).ToArray(),
            batches.SelectMany(batch => batch.Archives).Select(record => record.RecordId).ToArray());
    }

    [TestMethod]
    public void Bootstrap_AllowsProtocolMaximumAndRejectsOverflowBeforeSending()
    {
        var maximum = CreateRequest("recovery", SyncProtocol.MaximumBootstrapArchives);
        var overflow = CreateRequest("pairing", SyncProtocol.MaximumBootstrapArchives + 1);

        var batches = SyncBatchPlanner.CreateBatches(maximum);

        Assert.AreEqual(SyncProtocol.MaximumBootstrapRequests, batches.Count);
        Assert.IsTrue(batches[batches.Count - 1].BootstrapComplete);
        Assert.ThrowsExactly<InvalidOperationException>(() => SyncBatchPlanner.CreateBatches(overflow));
    }

    [DataTestMethod]
    [DataRow("manual")]
    [DataRow("automatic")]
    public void OrdinarySync_UsesOneCompleteOldestFirstBatch(string reason)
    {
        var request = CreateRequest(reason, 35);
        request.BootstrapComplete = false;

        var batches = SyncBatchPlanner.CreateBatches(request);

        Assert.AreEqual(1, batches.Count);
        Assert.IsTrue(batches[0].BootstrapComplete);
        Assert.AreEqual(SyncProtocol.MaximumArchivesPerRequest, batches[0].Archives.Count);
        CollectionAssert.AreEqual(
            Enumerable.Range(0, SyncProtocol.MaximumArchivesPerRequest)
                .Select(index => "record-" + index)
                .ToArray(),
            batches[0].Archives.Select(record => record.RecordId).ToArray());
        Assert.AreSame(request.CurrentSnapshot, batches[0].CurrentSnapshot);
        Assert.AreSame(request.EncryptedDeviceProfile, batches[0].EncryptedDeviceProfile);
    }

    [TestMethod]
    public void OrdinarySync_CrossDayBacklogStartsWithExactAcknowledgedCurrentArchive()
    {
        var request = CreateRequest("manual", 35);
        request.CurrentSnapshot = CreateRecord("today-current");
        var acknowledgedCurrent = CreateRecord("record-34");
        acknowledgedCurrent.Revision = 1;
        acknowledgedCurrent.CiphertextHash = "acknowledged-current-hash";
        request.Archives[34].Revision = 2;
        request.Archives[34].CiphertextHash = "newer-local-history-hash";

        var batches = SyncBatchPlanner.CreateBatches(request, acknowledgedCurrent);

        Assert.AreEqual(1, batches.Count);
        Assert.AreEqual(SyncProtocol.MaximumArchivesPerRequest, batches[0].Archives.Count);
        Assert.AreSame(acknowledgedCurrent, batches[0].Archives[0]);
        Assert.AreEqual("acknowledged-current-hash", batches[0].Archives[0].CiphertextHash);
        CollectionAssert.AreEqual(
            Enumerable.Range(0, SyncProtocol.MaximumArchivesPerRequest - 1)
                .Select(index => "record-" + index)
                .ToArray(),
            batches[0].Archives.Skip(1).Select(record => record.RecordId).ToArray());
        Assert.IsFalse(batches[0].Archives.Any(record =>
            string.Equals(record.CiphertextHash, "newer-local-history-hash", StringComparison.Ordinal)));
        Assert.AreSame(request.CurrentSnapshot, batches[0].CurrentSnapshot);
    }

    [TestMethod]
    public void SyncRequest_DefaultsToCompletedBootstrap()
    {
        Assert.IsTrue(new SyncRequest().BootstrapComplete);
    }

    [TestMethod]
    public void Transport_RejectsOversizedOrIncompleteOrdinaryRequestsBeforeNetwork()
    {
        using var transport = new CloudflareSyncTransport(new Uri("https://unit-tests.workers.dev/"));
        var oversized = CreateRequest("bootstrap", SyncProtocol.MaximumArchivesPerRequest + 1);
        var incompleteManual = CreateRequest("manual", 0);
        incompleteManual.BootstrapComplete = false;

        Assert.ThrowsExactly<ArgumentException>(() =>
            transport.SyncAsync(oversized, "token", "key", default));
        Assert.ThrowsExactly<ArgumentException>(() =>
            transport.SyncAsync(incompleteManual, "token", "key", default));
    }

    [TestMethod]
    public void IdempotencyFingerprint_IncludesBootstrapCompletionFlag()
    {
        var serializer = typeof(SyncCoordinator)
            .GetMethods(BindingFlags.Static | BindingFlags.NonPublic)
            .Single(method =>
                method.Name == "SerializeCanonical" &&
                method.GetParameters().Length == 1 &&
                method.GetParameters()[0].ParameterType == typeof(SyncRequest));
        var request = CreateRequest("bootstrap", 1);
        request.BootstrapComplete = true;
        var completedBytes = (byte[])serializer.Invoke(null, new object[] { request })!;
        request.BootstrapComplete = false;
        var incompleteBytes = (byte[])serializer.Invoke(null, new object[] { request })!;

        Assert.AreNotEqual(
            SyncCrypto.Sha256Base64Url(completedBytes),
            SyncCrypto.Sha256Base64Url(incompleteBytes));
    }

    private static SyncRequest CreateRequest(string reason, int archiveCount)
    {
        return new SyncRequest
        {
            Reason = reason,
            HistoryCursor = 7,
            CurrentSnapshot = CreateRecord("current"),
            Archives = Enumerable.Range(0, archiveCount)
                .Select(index => CreateRecord("record-" + index))
                .ToList(),
            EncryptedDeviceProfile = new PairingEncryptedPayload
            {
                Nonce = "profile-nonce",
                Ciphertext = "profile-ciphertext",
                Tag = "profile-tag"
            }
        };
    }

    private static EncryptedSyncRecord CreateRecord(string recordId)
    {
        return new EncryptedSyncRecord
        {
            RecordId = recordId,
            DeviceId = "device-id",
            Revision = 1,
            Nonce = "nonce",
            Ciphertext = "ciphertext",
            Tag = "tag",
            CiphertextHash = "hash"
        };
    }
}
