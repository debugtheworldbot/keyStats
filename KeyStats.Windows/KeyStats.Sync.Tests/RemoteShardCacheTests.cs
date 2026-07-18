using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using KeyStats.Models;
using KeyStats.Services;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KeyStats.Sync.Tests;

[TestClass]
public sealed class RemoteShardCacheTests
{
    [TestMethod]
    public void SameRevision_IsIdempotentAndNewRevisionReplacesAggregate()
    {
        TestPlatform.RequireWindows();
        using var directory = new TestDirectory();
        var cache = new RemoteShardCache(directory.Path);
        var aggregator = new DisplayStatsAggregator(cache, () => "local-device");
        var first = CreateRecord(revision: 1, ciphertextHash: "hash-1", keyPresses: 5);

        Assert.IsTrue(cache.Apply(first));
        Assert.IsFalse(cache.Apply(CreateRecord(revision: 1, ciphertextHash: "hash-1", keyPresses: 5)));

        var local = new DailyStats(new DateTime(2026, 7, 13))
        {
            KeyPresses = 2,
            LeftClicks = 1,
            KeyPressCounts = new Dictionary<string, int>(StringComparer.Ordinal) { ["A"] = 2 }
        };
        var firstAggregate = aggregator.Aggregate(local.Date, local);
        Assert.AreEqual(7, firstAggregate.KeyPresses);
        Assert.AreEqual(4, firstAggregate.LeftClicks);
        Assert.AreEqual(7, firstAggregate.KeyPressCounts["A"]);

        Assert.IsTrue(cache.Apply(CreateRecord(revision: 2, ciphertextHash: "hash-2", keyPresses: 8)));
        Assert.IsFalse(cache.Apply(CreateRecord(revision: 2, ciphertextHash: "hash-2", keyPresses: 8)));
        var secondAggregate = aggregator.Aggregate(local.Date, local);
        Assert.AreEqual(10, secondAggregate.KeyPresses);
        Assert.AreEqual(7, secondAggregate.LeftClicks);
        Assert.AreEqual(10, secondAggregate.KeyPressCounts["A"]);
        Assert.AreEqual(1, cache.GetAll().Count);

        Assert.ThrowsExactly<RemoteShardConflictException>(() =>
            cache.Apply(CreateRecord(revision: 2, ciphertextHash: "conflict", keyPresses: 8)));
    }

    [TestMethod]
    public void Save_IsDurableAndReloadsLatestProtectedCache()
    {
        TestPlatform.RequireWindows();
        using var directory = new TestDirectory();
        var path = Path.Combine(directory.Path, "sync_cache.json");
        var cache = new RemoteShardCache(directory.Path);

        Assert.IsTrue(cache.Apply(CreateRecord(revision: 1, ciphertextHash: "hash-1", keyPresses: 5)));
        Assert.IsTrue(cache.Apply(CreateRecord(revision: 2, ciphertextHash: "hash-2", keyPresses: 8)));

        Assert.IsTrue(File.Exists(path));
        Assert.IsTrue(File.Exists(path + ".bak"));
        Assert.IsFalse(File.Exists(path + ".tmp"));

        var reloaded = new RemoteShardCache(directory.Path);
        Assert.IsFalse(reloaded.NeedsRepair);
        Assert.IsFalse(reloaded.RecoveredFromBackup);
        var record = reloaded.GetAll().Single();
        Assert.AreEqual(2L, record.Revision);
        Assert.AreEqual("hash-2", record.CiphertextHash);
        Assert.AreEqual(8L, record.Plaintext.KeyPresses);

        File.WriteAllText(path, "damaged");
        var recovered = new RemoteShardCache(directory.Path);
        Assert.IsFalse(recovered.NeedsRepair);
        Assert.IsTrue(recovered.RecoveredFromBackup);
        Assert.AreEqual(1L, recovered.GetAll().Single().Revision);
    }

    private static CachedRemoteRecord CreateRecord(long revision, string ciphertextHash, long keyPresses)
    {
        return new CachedRemoteRecord
        {
            RecordId = "record-1",
            DeviceId = "remote-device",
            Revision = revision,
            CiphertextHash = ciphertextHash,
            IsCurrent = true,
            Plaintext = new CoreDaySnapshotV1
            {
                DeviceId = "remote-device",
                LocalDay = "2026-07-13",
                Revision = revision,
                KeyPresses = keyPresses,
                KeyPressCounts = new Dictionary<string, long>(StringComparer.Ordinal) { ["A"] = keyPresses },
                Clicks = new CoreClickSnapshotV1 { Left = keyPresses - 2 }
            }
        };
    }
}
