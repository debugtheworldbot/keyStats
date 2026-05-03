using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Microsoft.Win32;

namespace KeyStats.Helpers;

public static class AppIconHelper
{
    private const int MaxShortcutScanCount = 3000;
    private const int MaxSteamSearchDirectories = 2000;
    private static readonly TimeSpan FailedIconCacheDuration = TimeSpan.FromMinutes(2);
    private static readonly Dictionary<string, IconCacheEntry> _iconCache = new(StringComparer.OrdinalIgnoreCase);
    private static readonly object _lock = new object();

    /// <summary>
    /// Gets the icon for an application by its process name.
    /// Returns null if the icon cannot be retrieved.
    /// </summary>
    public static ImageSource? GetAppIcon(string processName)
    {
        return GetAppIcon(processName, null);
    }

    /// <summary>
    /// Gets the icon for an application by its process name and optional display name.
    /// Returns null if the icon cannot be retrieved.
    /// </summary>
    public static ImageSource? GetAppIcon(string processName, string? displayName)
    {
        if (string.IsNullOrEmpty(processName) || processName == "Unknown")
        {
            return null;
        }

        var cacheKey = string.IsNullOrWhiteSpace(displayName)
            ? processName
            : $"{processName}|{displayName!.Trim()}";

        lock (_lock)
        {
            if (_iconCache.TryGetValue(cacheKey, out var cachedIcon) && cachedIcon.IsFresh)
            {
                return cachedIcon.Icon;
            }
        }

        var icon = LoadAppIcon(processName, displayName);

        lock (_lock)
        {
            _iconCache[cacheKey] = new IconCacheEntry(icon, DateTime.UtcNow);
        }

        return icon;
    }

    private static ImageSource? LoadAppIcon(string processName, string? displayName)
    {
        try
        {
            foreach (var iconPath in GetIconCandidatePaths(processName, displayName))
            {
                var icon = ExtractIconFromFile(iconPath);
                if (icon != null)
                {
                    return icon;
                }
            }
        }
        catch
        {
            // Icon lookup is best-effort; never block opening stats UI.
        }

        return null;
    }

    private static IEnumerable<string> GetIconCandidatePaths(string processName, string? displayName)
    {
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        foreach (var path in GetRunningProcessPaths(processName)
                     .Concat(GetAppPathsRegistryEntries(processName))
                     .Concat(GetKnownInstallPaths(processName))
                     .Concat(GetShortcutIconPaths(processName, displayName))
                     .Concat(GetSteamLibraryPaths(processName)))
        {
            var normalizedPath = NormalizeIconPath(path);
            if (string.IsNullOrWhiteSpace(normalizedPath) || !File.Exists(normalizedPath))
            {
                continue;
            }

            if (seen.Add(normalizedPath!))
            {
                yield return normalizedPath!;
            }
        }
    }

    private static IEnumerable<string> GetRunningProcessPaths(string processName)
    {
        Process[] processes;
        try
        {
            processes = Process.GetProcessesByName(processName);
        }
        catch
        {
            yield break;
        }

        foreach (var process in processes)
        {
            using (process)
            {
                string? exePath = null;
                try
                {
                    exePath = process.MainModule?.FileName;
                }
                catch
                {
                    // Protected/elevated processes may deny module access.
                }

                if (!string.IsNullOrWhiteSpace(exePath))
                {
                    yield return exePath!;
                }
            }
        }
    }

    private static IEnumerable<string> GetAppPathsRegistryEntries(string processName)
    {
        var appPathNames = new[]
        {
            $"{processName}.exe",
            processName
        };

        foreach (var hive in new[] { RegistryHive.CurrentUser, RegistryHive.LocalMachine })
        {
            foreach (var view in new[] { RegistryView.Registry64, RegistryView.Registry32 })
            {
                RegistryKey? baseKey = null;
                try
                {
                    baseKey = RegistryKey.OpenBaseKey(hive, view);
                }
                catch
                {
                    continue;
                }

                using (baseKey)
                {
                    foreach (var appPathName in appPathNames)
                    {
                        using var appPathKey = baseKey.OpenSubKey($@"SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\{appPathName}");
                        var path = appPathKey?.GetValue(null) as string;
                        if (!string.IsNullOrWhiteSpace(path))
                        {
                            yield return path!;
                        }
                    }
                }
            }
        }
    }

    private static IEnumerable<string> GetKnownInstallPaths(string processName)
    {
        var exeName = $"{processName}.exe";
        var roots = new[]
        {
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86),
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Microsoft", "WindowsApps")
        };

        foreach (var root in roots.Where(r => !string.IsNullOrWhiteSpace(r)))
        {
            yield return Path.Combine(root, processName, exeName);
            yield return Path.Combine(root, exeName);
        }
    }

    private static IEnumerable<string> GetShortcutIconPaths(string processName, string? displayName)
    {
        foreach (var shortcutPath in EnumerateShortcutPaths())
        {
            var shortcutName = Path.GetFileNameWithoutExtension(shortcutPath);
            if (!IsLikelyMatch(shortcutName, processName, displayName))
            {
                var targetName = Path.GetFileNameWithoutExtension(ResolveShortcutTargetPath(shortcutPath));
                if (!IsLikelyMatch(targetName, processName, displayName))
                {
                    continue;
                }
            }

            var iconPath = ResolveShortcutIconPath(shortcutPath);
            if (!string.IsNullOrWhiteSpace(iconPath))
            {
                yield return iconPath!;
            }

            var targetPath = ResolveShortcutTargetPath(shortcutPath);
            if (!string.IsNullOrWhiteSpace(targetPath))
            {
                yield return targetPath!;
            }
        }
    }

    private static IEnumerable<string> EnumerateShortcutPaths()
    {
        var roots = new[]
        {
            Environment.GetFolderPath(Environment.SpecialFolder.StartMenu),
            Environment.GetFolderPath(Environment.SpecialFolder.CommonStartMenu),
            Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory),
            Environment.GetFolderPath(Environment.SpecialFolder.CommonDesktopDirectory)
        };

        var count = 0;
        foreach (var root in roots.Where(Directory.Exists).Distinct(StringComparer.OrdinalIgnoreCase))
        {
            foreach (var shortcut in EnumerateShortcutPathsSafely(root))
            {
                if (++count > MaxShortcutScanCount)
                {
                    yield break;
                }

                yield return shortcut;
            }
        }
    }

    private static IEnumerable<string> EnumerateShortcutPathsSafely(string root)
    {
        var pending = new Queue<string>();
        pending.Enqueue(root);

        while (pending.Count > 0)
        {
            var current = pending.Dequeue();

            IEnumerable<string> shortcuts;
            try
            {
                shortcuts = Directory.EnumerateFiles(current, "*.lnk", SearchOption.TopDirectoryOnly).ToList();
            }
            catch
            {
                continue;
            }

            foreach (var shortcut in shortcuts)
            {
                yield return shortcut;
            }

            IEnumerable<string> directories;
            try
            {
                directories = Directory.EnumerateDirectories(current).ToList();
            }
            catch
            {
                continue;
            }

            foreach (var directory in directories)
            {
                pending.Enqueue(directory);
            }
        }
    }

    private static IEnumerable<string> GetSteamLibraryPaths(string processName)
    {
        var steamRoots = GetSteamRoots()
            .Select(NormalizeDirectoryPath)
            .Where(path => path != null && Directory.Exists(path))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();

        foreach (var steamRoot in steamRoots)
        {
            foreach (var libraryRoot in GetSteamLibraryFolders(steamRoot!).Prepend(steamRoot).Distinct(StringComparer.OrdinalIgnoreCase))
            {
                var normalizedLibraryRoot = NormalizeDirectoryPath(libraryRoot);
                if (normalizedLibraryRoot == null)
                {
                    continue;
                }

                string commonPath;
                try
                {
                    commonPath = Path.Combine(normalizedLibraryRoot, "steamapps", "common");
                }
                catch
                {
                    continue;
                }

                foreach (var exePath in FindExecutableUnder(commonPath, $"{processName}.exe", MaxSteamSearchDirectories))
                {
                    yield return exePath;
                }
            }
        }
    }

    private static IEnumerable<string> GetSteamRoots()
    {
        foreach (var hive in new[] { RegistryHive.CurrentUser, RegistryHive.LocalMachine })
        {
            foreach (var view in new[] { RegistryView.Registry64, RegistryView.Registry32 })
            {
                RegistryKey? baseKey = null;
                try
                {
                    baseKey = RegistryKey.OpenBaseKey(hive, view);
                }
                catch
                {
                    continue;
                }

                using (baseKey)
                using (var steamKey = baseKey.OpenSubKey(@"SOFTWARE\Valve\Steam"))
                {
                    foreach (var valueName in new[] { "SteamPath", "InstallPath" })
                    {
                        var path = steamKey?.GetValue(valueName) as string;
                        if (!string.IsNullOrWhiteSpace(path))
                        {
                            yield return path!;
                        }
                    }
                }
            }
        }

        yield return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), "Steam");
        yield return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "Steam");
    }

    private static IEnumerable<string> GetSteamLibraryFolders(string steamRoot)
    {
        var libraryFile = Path.Combine(steamRoot, "steamapps", "libraryfolders.vdf");
        if (!File.Exists(libraryFile))
        {
            yield break;
        }

        string[] lines;
        try
        {
            lines = File.ReadAllLines(libraryFile);
        }
        catch
        {
            yield break;
        }

        foreach (var line in lines)
        {
            var trimmed = line.Trim();
            if (!trimmed.StartsWith("\"path\"", StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            var parts = trimmed.Split(new[] { '"' }, StringSplitOptions.RemoveEmptyEntries)
                .Select(part => part.Trim())
                .Where(part => !string.IsNullOrWhiteSpace(part) &&
                               !string.Equals(part, "path", StringComparison.OrdinalIgnoreCase))
                .ToList();

            var path = parts.LastOrDefault();
            if (!string.IsNullOrWhiteSpace(path))
            {
                yield return path!.Replace(@"\\", @"\");
            }
        }
    }

    private static IEnumerable<string> FindExecutableUnder(string root, string exeName, int maxDirectories)
    {
        if (!Directory.Exists(root))
        {
            yield break;
        }

        var visitedDirectories = 0;
        var pending = new Queue<string>();
        pending.Enqueue(root);

        while (pending.Count > 0 && visitedDirectories < maxDirectories)
        {
            var current = pending.Dequeue();
            visitedDirectories++;

            IEnumerable<string> files;
            try
            {
                files = Directory.EnumerateFiles(current, exeName, SearchOption.TopDirectoryOnly);
            }
            catch
            {
                files = Enumerable.Empty<string>();
            }

            foreach (var file in files)
            {
                yield return file;
            }

            IEnumerable<string> directories;
            try
            {
                directories = Directory.EnumerateDirectories(current);
            }
            catch
            {
                continue;
            }

            foreach (var directory in directories)
            {
                pending.Enqueue(directory);
            }
        }
    }

    private static string? ResolveShortcutTargetPath(string shortcutPath)
    {
        return ResolveShortcutProperty(shortcutPath, "TargetPath");
    }

    private static string? ResolveShortcutIconPath(string shortcutPath)
    {
        return ResolveShortcutProperty(shortcutPath, "IconLocation");
    }

    private static string? ResolveShortcutProperty(string shortcutPath, string propertyName)
    {
        object? shell = null;
        object? shortcut = null;
        try
        {
            var shellType = Type.GetTypeFromProgID("WScript.Shell");
            if (shellType == null)
            {
                return null;
            }

            shell = Activator.CreateInstance(shellType);
            shortcut = shellType.InvokeMember("CreateShortcut", System.Reflection.BindingFlags.InvokeMethod, null, shell, new object[] { shortcutPath });
            return shortcut?.GetType().InvokeMember(propertyName, System.Reflection.BindingFlags.GetProperty, null, shortcut, null) as string;
        }
        catch
        {
            return null;
        }
        finally
        {
            if (shortcut != null && Marshal.IsComObject(shortcut))
            {
                Marshal.ReleaseComObject(shortcut);
            }

            if (shell != null && Marshal.IsComObject(shell))
            {
                Marshal.ReleaseComObject(shell);
            }
        }
    }

    private static string? NormalizeIconPath(string? rawPath)
    {
        if (string.IsNullOrWhiteSpace(rawPath))
        {
            return null;
        }

        var path = Environment.ExpandEnvironmentVariables(rawPath!.Trim().Trim('"'));
        var commaIndex = path.LastIndexOf(',');
        if (commaIndex > 1 && int.TryParse(path.Substring(commaIndex + 1).Trim(), out _))
        {
            path = path.Substring(0, commaIndex).Trim().Trim('"');
        }

        return string.IsNullOrWhiteSpace(path) ? null : path;
    }

    private static string? NormalizeDirectoryPath(string? rawPath)
    {
        var path = NormalizeIconPath(rawPath);
        if (string.IsNullOrWhiteSpace(path))
        {
            return null;
        }

        try
        {
            return path!.IndexOfAny(Path.GetInvalidPathChars()) >= 0 ? null : path;
        }
        catch
        {
            return null;
        }
    }

    private static bool IsLikelyMatch(string? candidate, string processName, string? displayName)
    {
        if (string.IsNullOrWhiteSpace(candidate))
        {
            return false;
        }

        return IsLikelyMatch(candidate, processName) || IsLikelyMatch(candidate, displayName);
    }

    private static bool IsLikelyMatch(string? candidate, string? expected)
    {
        if (string.IsNullOrWhiteSpace(candidate) || string.IsNullOrWhiteSpace(expected))
        {
            return false;
        }

        var normalizedCandidate = candidate!;
        var normalizedExpected = expected!;

        return normalizedCandidate.IndexOf(normalizedExpected, StringComparison.OrdinalIgnoreCase) >= 0 ||
               normalizedExpected.IndexOf(normalizedCandidate, StringComparison.OrdinalIgnoreCase) >= 0;
    }

    private static ImageSource? ExtractIconFromFile(string filePath)
    {
        try
        {
            using var icon = Icon.ExtractAssociatedIcon(filePath);
            if (icon == null) return null;

            var bitmap = icon.ToBitmap();
            var hBitmap = bitmap.GetHbitmap();

            try
            {
                var imageSource = Imaging.CreateBitmapSourceFromHBitmap(
                    hBitmap,
                    IntPtr.Zero,
                    Int32Rect.Empty,
                    BitmapSizeOptions.FromEmptyOptions());

                imageSource.Freeze();
                return imageSource;
            }
            finally
            {
                DeleteObject(hBitmap);
                bitmap.Dispose();
            }
        }
        catch
        {
            return null;
        }
    }

    [System.Runtime.InteropServices.DllImport("gdi32.dll")]
    private static extern bool DeleteObject(IntPtr hObject);

    private sealed class IconCacheEntry
    {
        public IconCacheEntry(ImageSource? icon, DateTime cachedAt)
        {
            Icon = icon;
            CachedAt = cachedAt;
        }

        public ImageSource? Icon { get; }
        public DateTime CachedAt { get; }
        public bool IsFresh => Icon != null || DateTime.UtcNow - CachedAt < FailedIconCacheDuration;
    }
}
