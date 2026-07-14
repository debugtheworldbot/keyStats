using System;
using System.IO;
using System.Reflection;
using System.Runtime.Serialization;
using KeyStats.Models;
using KeyStats.Services;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KeyStats.Sync.Tests;

[TestClass]
public sealed class SyncSchedulingTests
{
    [TestMethod]
    public void DamagedRemoteCache_RequiresExplicitRepairWithoutBootstrapReplay()
    {
        TestPlatform.RequireWindows();
        using var directory = new TestDirectory();
        new SyncStateStore(directory.Path).Save(new SyncState
        {
            IsEnabled = true,
            NeedsBootstrap = false,
            VaultId = "vault-id",
            DeviceId = "device-id",
            DeviceName = "Test device",
            ActiveDeviceCount = 2,
            RemainingDailySyncs = 8
        });
        new SyncCredentialStore(directory.Path).Save(new SyncCredentials
        {
            VaultSeed = new byte[16],
            DeviceToken = "device-id.test-token"
        });
        File.WriteAllText(Path.Combine(directory.Path, "sync_cache.json"), "damaged");

        var statsManager = (StatsManager)FormatterServices.GetUninitializedObject(typeof(StatsManager));
        using var coordinator = new SyncCoordinator(
            statsManager,
            directory.Path,
            new Uri("https://unit-tests.workers.dev/"),
            "test");

        var status = coordinator.GetStatus();
        var persisted = new SyncStateStore(directory.Path).Load();
        Assert.IsTrue(status.NeedsRepair);
        Assert.IsFalse(status.CanRetryBootstrap);
        Assert.IsTrue(persisted.NeedsRepair);
        Assert.IsFalse(persisted.NeedsBootstrap);
        Assert.IsFalse(persisted.NeedsHistoryBootstrap);
    }

    [TestMethod]
    public void Start_WithOneDevice_DoesNotScheduleOrEnableManualSync()
    {
        TestPlatform.RequireWindows();
        using var directory = new TestDirectory();
        var stateStore = new SyncStateStore(directory.Path);
        stateStore.Save(new SyncState
        {
            IsEnabled = true,
            VaultId = "vault-id",
            DeviceId = "only-device",
            DeviceName = "Only device",
            ActiveDeviceCount = 1,
            RemainingDailySyncs = 8
        });
        new SyncCredentialStore(directory.Path).Save(new SyncCredentials
        {
            VaultSeed = new byte[16],
            DeviceToken = "only-device.test-token"
        });

        // Avoid opening or modifying the real user's statistics directory. The coordinator only
        // attaches events and a display projection during construction; neither needs loaded stats.
        var statsManager = (StatsManager)FormatterServices.GetUninitializedObject(typeof(StatsManager));
        using var coordinator = new SyncCoordinator(
            statsManager,
            directory.Path,
            new Uri("https://unit-tests.workers.dev/"),
            "test");
        coordinator.Start();

        var status = coordinator.GetStatus();
        Assert.IsTrue(status.IsServiceConfigured);
        Assert.IsTrue(status.IsEnabled);
        Assert.AreEqual(1, status.ActiveDeviceCount);
        Assert.IsFalse(status.CanSync);
        Assert.IsFalse(status.CanManualSync);
        Assert.IsNull(stateStore.Load().NextAutomaticSyncAtUtc);

        var timerField = typeof(SyncCoordinator).GetField(
            "_automaticTimer",
            BindingFlags.Instance | BindingFlags.NonPublic);
        Assert.IsNotNull(timerField);
        Assert.IsNull(timerField!.GetValue(coordinator));
    }
}
