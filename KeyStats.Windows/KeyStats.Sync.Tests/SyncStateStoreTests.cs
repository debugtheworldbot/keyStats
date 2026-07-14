using System.IO;
using KeyStats.Models;
using KeyStats.Services;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KeyStats.Sync.Tests;

[TestClass]
public sealed class SyncStateStoreTests
{
    [TestMethod]
    public void Load_WithDamagedPrimary_RestoresValidatedBackup()
    {
        using var directory = new TestDirectory();
        var path = Path.Combine(directory.Path, "sync_state.json");
        var store = new SyncStateStore(directory.Path);
        store.Save(CreateState(activeDeviceCount: 1));
        store.Save(CreateState(activeDeviceCount: 2));
        File.WriteAllText(path, "damaged");

        var reloadedStore = new SyncStateStore(directory.Path);
        var recovered = reloadedStore.Load();

        Assert.IsFalse(reloadedStore.NeedsRepair);
        Assert.IsTrue(reloadedStore.RecoveredFromBackup);
        Assert.AreEqual(1, recovered.ActiveDeviceCount);
        Assert.AreEqual("device-id", recovered.DeviceId);
    }

    [TestMethod]
    public void Load_WithNoValidCopy_RequiresRepairWithoutOverwritingPrimary()
    {
        using var directory = new TestDirectory();
        var path = Path.Combine(directory.Path, "sync_state.json");
        File.WriteAllText(path, "damaged");

        var store = new SyncStateStore(directory.Path);
        var state = store.Load();

        Assert.IsTrue(store.NeedsRepair);
        Assert.IsTrue(state.NeedsRepair);
        Assert.AreEqual("damaged", File.ReadAllText(path));
    }

    [TestMethod]
    public void Save_HistoryOnlyBootstrapPhaseSurvivesRestart()
    {
        using var directory = new TestDirectory();
        var store = new SyncStateStore(directory.Path);
        var state = CreateState(activeDeviceCount: 2);
        state.NeedsBootstrap = false;
        state.NeedsHistoryBootstrap = true;
        state.HistoryCursor = 42;

        store.Save(state);
        var restored = new SyncStateStore(directory.Path).Load();

        Assert.IsFalse(restored.NeedsBootstrap);
        Assert.IsTrue(restored.NeedsHistoryBootstrap);
        Assert.AreEqual(42L, restored.HistoryCursor);
    }

    [TestMethod]
    public void Save_AcknowledgedCurrentEnvelopeSurvivesCrossDayRetry()
    {
        using var directory = new TestDirectory();
        var store = new SyncStateStore(directory.Path);
        var state = CreateState(activeDeviceCount: 2);
        state.LastAcknowledgedCurrentSnapshot = new EncryptedSyncRecord
        {
            RecordId = "prior-current",
            DeviceId = "device-id",
            Revision = 7,
            Nonce = "nonce",
            Ciphertext = "ciphertext",
            Tag = "tag",
            CiphertextHash = "hash"
        };

        store.Save(state);
        var restored = new SyncStateStore(directory.Path).Load();

        Assert.IsNotNull(restored.LastAcknowledgedCurrentSnapshot);
        Assert.AreEqual("prior-current", restored.LastAcknowledgedCurrentSnapshot!.RecordId);
        Assert.AreEqual(7L, restored.LastAcknowledgedCurrentSnapshot.Revision);
        Assert.AreEqual("hash", restored.LastAcknowledgedCurrentSnapshot.CiphertextHash);
    }

    private static SyncState CreateState(int activeDeviceCount)
    {
        return new SyncState
        {
            IsEnabled = true,
            VaultId = "vault-id",
            DeviceId = "device-id",
            DeviceName = "Test device",
            ActiveDeviceCount = activeDeviceCount,
            RemainingDailySyncs = 8
        };
    }
}
