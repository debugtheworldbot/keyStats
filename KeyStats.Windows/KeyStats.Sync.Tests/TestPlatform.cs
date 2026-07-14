using System;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KeyStats.Sync.Tests;

internal static class TestPlatform
{
    public static void RequireWindows()
    {
        if (Environment.OSVersion.Platform != PlatformID.Win32NT)
        {
            Assert.Inconclusive("This test exercises Windows DPAPI and only runs on Windows.");
        }
    }
}
