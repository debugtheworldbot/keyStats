using System.IO;
using System.Linq;
using System.Security.Cryptography;
using KeyStats.Models;
using KeyStats.Services;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KeyStats.Sync.Tests;

[TestClass]
public sealed class SyncCredentialStoreTests
{
    [TestMethod]
    public void SaveAndLoad_RoundTripsWithCurrentUserDpapi()
    {
        TestPlatform.RequireWindows();
        using var directory = new TestDirectory();
        var store = new SyncCredentialStore(directory.Path);
        var expected = new SyncCredentials
        {
            VaultId = "vault-id",
            DeviceId = "device-id",
            VaultSeed = Enumerable.Range(0, 16).Select(value => (byte)value).ToArray(),
            DeviceToken = "device-id.test-token"
        };

        store.Save(expected);
        var actual = store.Load("vault-id", "device-id");

        Assert.AreEqual(expected.VaultId, actual.VaultId);
        Assert.AreEqual(expected.DeviceId, actual.DeviceId);
        CollectionAssert.AreEqual(expected.VaultSeed, actual.VaultSeed);
        Assert.AreEqual(expected.DeviceToken, actual.DeviceToken);
    }

    [TestMethod]
    public void Load_WithDamagedPrimary_RestoresDpapiBackup()
    {
        TestPlatform.RequireWindows();
        using var directory = new TestDirectory();
        var store = new SyncCredentialStore(directory.Path);
        var first = new SyncCredentials
        {
            VaultSeed = Enumerable.Range(0, 16).Select(value => (byte)value).ToArray(),
            DeviceToken = "device-id.first-token"
        };
        store.Save(first);
        store.Save(new SyncCredentials
        {
            VaultSeed = Enumerable.Repeat((byte)7, 16).ToArray(),
            DeviceToken = "device-id.second-token"
        });
        File.WriteAllBytes(Path.Combine(directory.Path, "sync_credentials.bin"), new byte[] { 1, 2, 3 });

        var recovered = store.Load();

        CollectionAssert.AreEqual(first.VaultSeed, recovered.VaultSeed);
        Assert.AreEqual(first.DeviceToken, recovered.DeviceToken);
    }

    [TestMethod]
    public void Load_WithBackupForDifferentDevice_RejectsDeviceBinding()
    {
        TestPlatform.RequireWindows();
        using var directory = new TestDirectory();
        var store = new SyncCredentialStore(directory.Path);
        store.Save(new SyncCredentials
        {
            VaultSeed = Enumerable.Range(0, 16).Select(value => (byte)value).ToArray(),
            DeviceToken = "old-device.old-token"
        });
        store.Save(new SyncCredentials
        {
            VaultSeed = Enumerable.Repeat((byte)7, 16).ToArray(),
            DeviceToken = "current-device.current-token"
        });
        File.WriteAllBytes(Path.Combine(directory.Path, "sync_credentials.bin"), new byte[] { 1, 2, 3 });

        Assert.ThrowsExactly<CryptographicException>(() => store.Load("current-device"));
    }

    [TestMethod]
    public void PendingPairingCompletion_RoundTripsSecretsWithCurrentUserDpapi()
    {
        TestPlatform.RequireWindows();
        using var directory = new TestDirectory();
        var store = new SyncPendingSecretsStore(directory.Path);
        var expected = new PendingSyncSecrets
        {
            Kind = "pairing-final",
            VaultId = "vault-id",
            DeviceId = "device-id",
            VaultSeed = Enumerable.Range(0, 16).Select(value => (byte)value).ToArray(),
            DeviceToken = "device-id.test-token",
            PairingPrivateKey = Enumerable.Repeat((byte)3, 32).ToArray(),
            PairingPublicKey = Enumerable.Repeat((byte)7, 32).ToArray(),
            PairingSessionId = "session-id",
            PairingCompletionToken = "completion-token"
        };

        store.Save(expected);
        var actual = store.Load();

        Assert.AreEqual(expected.Kind, actual.Kind);
        Assert.AreEqual(expected.VaultId, actual.VaultId);
        Assert.AreEqual(expected.DeviceId, actual.DeviceId);
        Assert.AreEqual(expected.DeviceToken, actual.DeviceToken);
        CollectionAssert.AreEqual(expected.VaultSeed, actual.VaultSeed);
        CollectionAssert.AreEqual(expected.PairingPrivateKey, actual.PairingPrivateKey);
        CollectionAssert.AreEqual(expected.PairingPublicKey, actual.PairingPublicKey);
    }
}
