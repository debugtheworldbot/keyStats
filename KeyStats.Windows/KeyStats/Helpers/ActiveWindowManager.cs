using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Text;

namespace KeyStats.Helpers;

public static class ActiveWindowManager
{
    private static readonly object _lock = new();
    private static readonly HashSet<string> HostProcessNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "javaw",
        "java",
        "python",
        "pythonw",
        "node",
        "dotnet"
    };

    private static readonly HashSet<string> GenericDisplayNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "java(tm) platform se binary",
        "openjdk platform binary",
        "python",
        "pythonw",
        "node.js javascript runtime",
        "microsoft(r) .net host"
    };

    private static readonly string[] TitleSeparators = { " - ", " | ", " — ", " – ", ":" };

    private static IntPtr _lastWindowHandle = IntPtr.Zero;
    private static ActiveAppInfo _lastAppInfo = ActiveAppInfo.Unknown;

    // Cache process name + display name by process ID to avoid repeated
    // Process.GetProcessById / FileVersionInfo lookups inside the hook callback.
    private static readonly Dictionary<uint, (string ProcessName, string DisplayName)> _processCache = new();
    private const int MaxProcessCacheSize = 64;

    /// <summary>
    /// Gets the foreground app identity for attribution and display.
    /// </summary>
    public static ActiveAppInfo GetActiveAppInfo()
    {
        try
        {
            var hWnd = NativeInterop.GetForegroundWindow();
            if (hWnd == IntPtr.Zero)
            {
                return ActiveAppInfo.Unknown;
            }

            lock (_lock)
            {
                if (hWnd == _lastWindowHandle && _lastAppInfo.IsKnown)
                {
                    return _lastAppInfo;
                }

                NativeInterop.GetWindowThreadProcessId(hWnd, out uint processId);
                if (processId == 0)
                {
                    return ActiveAppInfo.Unknown;
                }

                var appInfo = BuildAppInfo(hWnd, processId);
                _lastWindowHandle = hWnd;
                _lastAppInfo = appInfo;
                return appInfo;
            }
        }
        catch
        {
            return ActiveAppInfo.Unknown;
        }
    }

    /// <summary>
    /// Resolves app info from a pre-captured window handle and process ID.
    /// Use this when hWnd/pid were captured in a time-critical path (e.g. hook callback)
    /// and the expensive resolution is deferred to a background thread.
    /// </summary>
    public static ActiveAppInfo ResolveAppInfo(IntPtr hWnd, uint processId)
    {
        if (hWnd == IntPtr.Zero || processId == 0)
        {
            return ActiveAppInfo.Unknown;
        }

        try
        {
            lock (_lock)
            {
                if (hWnd == _lastWindowHandle && _lastAppInfo.IsKnown)
                {
                    return _lastAppInfo;
                }

                var appInfo = BuildAppInfo(hWnd, processId);
                _lastWindowHandle = hWnd;
                _lastAppInfo = appInfo;
                return appInfo;
            }
        }
        catch
        {
            return ActiveAppInfo.Unknown;
        }
    }

    /// <summary>
    /// Backward-compatible accessor when only process identity is needed.
    /// </summary>
    public static string GetActiveProcessName()
    {
        return GetActiveAppInfo().AppName;
    }

    private static ActiveAppInfo BuildAppInfo(IntPtr windowHandle, uint processId)
    {
        var windowTitle = GetWindowTitle(windowHandle);

        // Use cached process identity when available to avoid expensive
        // Process.GetProcessById + FileVersionInfo on every window switch.
        if (_processCache.TryGetValue(processId, out var cached))
        {
            var displayName = ResolveDisplayName(cached.ProcessName, cached.DisplayName, windowTitle);
            return new ActiveAppInfo(cached.ProcessName, displayName, windowTitle, processId, windowHandle);
        }

        try
        {
            using var process = Process.GetProcessById((int)processId);
            var processName = NormalizeProcessName(process.ProcessName);
            var fileDisplayName = GetFileDisplayName(process, processName);

            if (_processCache.Count >= MaxProcessCacheSize)
            {
                _processCache.Clear();
            }
            _processCache[processId] = (processName, fileDisplayName);

            var resolvedDisplayName = ResolveDisplayName(processName, fileDisplayName, windowTitle);
            return new ActiveAppInfo(processName, resolvedDisplayName, windowTitle, processId, windowHandle);
        }
        catch
        {
            return new ActiveAppInfo("Unknown", "Unknown", windowTitle, processId, windowHandle);
        }
    }

    private static string NormalizeProcessName(string? processName)
    {
        var normalized = processName?.Trim();
        if (string.IsNullOrWhiteSpace(normalized))
        {
            return "Unknown";
        }

        return normalized ?? "Unknown";
    }

    private static string GetFileDisplayName(Process process, string processName)
    {
        try
        {
            var version = process.MainModule?.FileVersionInfo;
            if (version == null)
            {
                return processName;
            }

            var fileDescription = (version.FileDescription ?? string.Empty).Trim();
            if (IsPreferredDisplayName(fileDescription, processName))
            {
                return fileDescription;
            }

            var productName = (version.ProductName ?? string.Empty).Trim();
            if (IsPreferredDisplayName(productName, processName))
            {
                return productName;
            }
        }
        catch
        {
            // Access denied for some protected processes. Keep process name fallback.
        }

        return processName;
    }

    private static string ResolveDisplayName(string processName, string fileDisplayName, string windowTitle)
    {
        if (string.Equals(processName, "Unknown", StringComparison.OrdinalIgnoreCase))
        {
            return "Unknown";
        }

        if (IsMinecraftWindow(windowTitle))
        {
            return "Minecraft";
        }

        if (HostProcessNames.Contains(processName))
        {
            var titleName = ExtractMeaningfulTitle(windowTitle);
            if (!string.IsNullOrWhiteSpace(titleName))
            {
                return titleName;
            }
        }

        return IsPreferredDisplayName(fileDisplayName, processName) ? fileDisplayName : processName;
    }

    private static bool IsMinecraftWindow(string windowTitle)
    {
        return windowTitle.IndexOf("minecraft", StringComparison.OrdinalIgnoreCase) >= 0;
    }

    private static string ExtractMeaningfulTitle(string windowTitle)
    {
        if (string.IsNullOrWhiteSpace(windowTitle))
        {
            return string.Empty;
        }

        var normalized = windowTitle.Trim();
        var cutIndex = -1;
        foreach (var separator in TitleSeparators)
        {
            var index = normalized.IndexOf(separator, StringComparison.Ordinal);
            if (index <= 0)
            {
                continue;
            }

            if (cutIndex == -1 || index < cutIndex)
            {
                cutIndex = index;
            }
        }

        var segment = cutIndex > 0 ? normalized.Substring(0, cutIndex).Trim() : normalized;

        if (segment.Length < 2 || segment.Length > 64)
        {
            return string.Empty;
        }

        if (segment.IndexOf(".exe", StringComparison.OrdinalIgnoreCase) >= 0 ||
            segment.Contains("\\") ||
            segment.Contains("/"))
        {
            return string.Empty;
        }

        return segment;
    }

    private static bool IsPreferredDisplayName(string? candidate, string processName)
    {
        var trimmed = candidate?.Trim();
        if (string.IsNullOrWhiteSpace(trimmed))
        {
            return false;
        }

        var normalized = trimmed!;

        if (string.Equals(normalized, processName, StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        if (string.Equals(normalized, "Unknown", StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        return !GenericDisplayNames.Contains(normalized);
    }

    private static string GetWindowTitle(IntPtr windowHandle)
    {
        var length = NativeInterop.GetWindowTextLength(windowHandle);
        if (length <= 0)
        {
            return string.Empty;
        }

        var sb = new StringBuilder(length + 1);
        _ = NativeInterop.GetWindowText(windowHandle, sb, sb.Capacity);
        return sb.ToString().Trim();
    }
}
