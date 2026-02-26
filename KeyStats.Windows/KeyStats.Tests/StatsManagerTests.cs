using System;
using System.IO;
using System.Threading;
using KeyStats.Services;
using KeyStats.Models;
using Xunit;

namespace KeyStats.Tests;

public class StatsManagerTests : IDisposable
{
    private readonly string _testDataFolder;
    private readonly StatsManager _statsManager;
    private readonly InputMonitorService _inputMonitor;

    public StatsManagerTests()
    {
        _testDataFolder = Path.Combine(Path.GetTempPath(), "KeyStatsTests_" + Guid.NewGuid());
        Directory.CreateDirectory(_testDataFolder);

        StatsManager.ResetInstanceForTesting(_testDataFolder);
        _statsManager = StatsManager.Instance;

        // InputMonitorService is a singleton, so we get the same instance.
        // We can't easily reset it, but we can use it to fire events.
        _inputMonitor = InputMonitorService.Instance;
    }

    public void Dispose()
    {
        // Cleanup
        StatsManager.ResetInstanceForTesting(null);
        try
        {
            if (Directory.Exists(_testDataFolder))
            {
                Directory.Delete(_testDataFolder, true);
            }
        }
        catch { /* Ignore cleanup errors */ }
    }

    [Fact]
    public void Initialization_ShouldStartWithZeroStats()
    {
        Assert.Equal(0, _statsManager.CurrentStats.KeyPresses);
        Assert.Equal(0, _statsManager.CurrentStats.TotalClicks);
    }

    [Fact]
    public void IncrementKeyPresses_ShouldIncreaseCount()
    {
        _inputMonitor.SimulateKeyPress("A", "TestApp", "Test App");

        // Allow some time for async processing if any (InputMonitor uses ThreadPool, but invokes delegate directly in SimulateKeyPress?)
        // Wait, SimulateKeyPress invokes KeyPressed event.
        // StatsManager subscribes to KeyPressed.
        // StatsManager.OnKeyPressed handles it inside a lock.
        // However, InputMonitorService.KeyboardHookCallback uses ThreadPool.QueueUserWorkItem.
        // But my SimulateKeyPress calls Invoke directly on the current thread.
        // So it should be synchronous unless StatsManager handles it asynchronously?
        // StatsManager.OnKeyPressed is synchronous.
        // So no wait needed.

        Assert.Equal(1, _statsManager.CurrentStats.KeyPresses);
        Assert.True(_statsManager.CurrentStats.KeyPressCounts.ContainsKey("A"));
        Assert.Equal(1, _statsManager.CurrentStats.KeyPressCounts["A"]);
    }

    [Fact]
    public void IncrementClicks_ShouldIncreaseCount()
    {
        _inputMonitor.SimulateLeftClick("TestApp", "Test App");
        Assert.Equal(1, _statsManager.CurrentStats.LeftClicks);
        Assert.Equal(1, _statsManager.CurrentStats.TotalClicks);

        _inputMonitor.SimulateRightClick("TestApp", "Test App");
        Assert.Equal(1, _statsManager.CurrentStats.RightClicks);
        Assert.Equal(2, _statsManager.CurrentStats.TotalClicks);
    }

    [Fact]
    public void Persistence_ShouldSaveAndLoadStats()
    {
        _inputMonitor.SimulateKeyPress("SaveTest", "TestApp", "Test App");

        // Force save (StatsManager saves on schedule, but we can trigger it via Dispose or public method if any)
        // StatsManager.FlushPendingSave is public.
        _statsManager.FlushPendingSave();

        // Reset instance to simulate restart
        StatsManager.ResetInstanceForTesting(_testDataFolder);
        var newManager = StatsManager.Instance;

        Assert.Equal(1, newManager.CurrentStats.KeyPresses);
        Assert.True(newManager.CurrentStats.KeyPressCounts.ContainsKey("SaveTest"));
    }
}
