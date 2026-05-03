using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;
using System.Text;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Microsoft.Win32;

namespace KeyStats.Helpers;

public static class AppIconHelper
{
    private const int MaxShortcutScanCount = 3000;
    private const int SteamAppInfoIconSearchWindow = 16000;
    private static readonly TimeSpan FailedIconCacheDuration = TimeSpan.FromSeconds(10);
    private static readonly Regex SteamExecutableRegex = new(@"[A-Za-z0-9_. \\/-]+\.exe", RegexOptions.IgnoreCase);
    private static readonly Regex SteamIconHashRegex = new(@"\b[a-f0-9]{40}\b", RegexOptions.IgnoreCase);
    private static readonly Dictionary<string, IconCacheEntry> _iconCache = new(StringComparer.OrdinalIgnoreCase);
    private static readonly object _lock = new object();
    private static readonly object _indexLock = new object();
    private static bool _shortcutIndexBuildStarted;
    private static bool _steamIndexBuildStarted;
    private static List<ShortcutIconEntry>? _shortcutIndex;
    private static Dictionary<string, List<string>>? _steamExecutableIndex;

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
                     .Concat(GetIndexedShortcutIconPaths(processName, displayName))
                     .Concat(GetIndexedSteamLibraryPaths(processName)))
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

    private static IEnumerable<string> GetIndexedShortcutIconPaths(string processName, string? displayName)
    {
        EnsureShortcutIndexBuildStarted();

        List<ShortcutIconEntry>? shortcutIndex;
        lock (_indexLock)
        {
            shortcutIndex = _shortcutIndex;
        }

        if (shortcutIndex == null)
        {
            yield break;
        }

        foreach (var shortcut in shortcutIndex)
        {
            if (!IsLikelyMatch(shortcut.ShortcutName, processName, displayName) &&
                !IsLikelyMatch(shortcut.TargetName, processName, displayName))
            {
                continue;
            }

            if (!string.IsNullOrWhiteSpace(shortcut.IconPath))
            {
                yield return shortcut.IconPath!;
            }

            if (!string.IsNullOrWhiteSpace(shortcut.TargetPath))
            {
                yield return shortcut.TargetPath!;
            }
        }
    }

    private static void EnsureShortcutIndexBuildStarted()
    {
        lock (_indexLock)
        {
            if (_shortcutIndexBuildStarted)
            {
                return;
            }

            _shortcutIndexBuildStarted = true;
        }

        ThreadPool.QueueUserWorkItem(_ =>
        {
            List<ShortcutIconEntry> shortcutIndex;
            try
            {
                shortcutIndex = BuildShortcutIndex().ToList();
            }
            catch
            {
                shortcutIndex = new List<ShortcutIconEntry>();
            }

            lock (_indexLock)
            {
                _shortcutIndex = shortcutIndex;
            }
        });
    }

    private static IEnumerable<ShortcutIconEntry> BuildShortcutIndex()
    {
        foreach (var shortcutPath in EnumerateShortcutPaths())
        {
            var shortcutName = Path.GetFileNameWithoutExtension(shortcutPath);
            var targetPath = ResolveShortcutTargetPath(shortcutPath);
            var iconPath = ResolveShortcutIconPath(shortcutPath);
            var targetName = Path.GetFileNameWithoutExtension(targetPath);

            if (string.IsNullOrWhiteSpace(shortcutName) &&
                string.IsNullOrWhiteSpace(targetName))
            {
                continue;
            }

            yield return new ShortcutIconEntry(shortcutName, targetName, iconPath, targetPath);
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

    private static IEnumerable<string> GetIndexedSteamLibraryPaths(string processName)
    {
        EnsureSteamIndexBuildStarted();

        Dictionary<string, List<string>>? steamExecutableIndex;
        lock (_indexLock)
        {
            steamExecutableIndex = _steamExecutableIndex;
        }

        if (steamExecutableIndex == null ||
            !steamExecutableIndex.TryGetValue($"{processName}.exe", out var paths))
        {
            yield break;
        }

        foreach (var path in paths)
        {
            yield return path;
        }
    }

    private static void EnsureSteamIndexBuildStarted()
    {
        lock (_indexLock)
        {
            if (_steamIndexBuildStarted)
            {
                return;
            }

            _steamIndexBuildStarted = true;
        }

        ThreadPool.QueueUserWorkItem(_ =>
        {
            Dictionary<string, List<string>> steamIndex;
            try
            {
                steamIndex = BuildSteamExecutableIndex();
            }
            catch
            {
                steamIndex = new Dictionary<string, List<string>>(StringComparer.OrdinalIgnoreCase);
            }

            lock (_indexLock)
            {
                _steamExecutableIndex = steamIndex;
            }
        });
    }

    private static Dictionary<string, List<string>> BuildSteamExecutableIndex()
    {
        var index = new Dictionary<string, List<string>>(StringComparer.OrdinalIgnoreCase);
        var steamRoots = GetSteamRoots()
            .Select(NormalizeDirectoryPath)
            .Where(path => path != null && Directory.Exists(path))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();

        foreach (var steamRoot in steamRoots)
        {
            IndexSteamAppInfoIcons(index, steamRoot!);

            foreach (var libraryRoot in GetSteamLibraryFolders(steamRoot!).Prepend(steamRoot).Distinct(StringComparer.OrdinalIgnoreCase))
            {
                var normalizedLibraryRoot = NormalizeDirectoryPath(libraryRoot);
                if (normalizedLibraryRoot == null)
                {
                    continue;
                }

                foreach (var manifestPath in GetSteamAppManifestPaths(normalizedLibraryRoot))
                {
                    var app = TryReadSteamAppManifest(normalizedLibraryRoot, manifestPath);
                    if (app == null)
                    {
                        continue;
                    }

                    foreach (var exePath in FindExecutablesNearRoot(app.InstallPath))
                    {
                        var exeName = Path.GetFileName(exePath);
                        if (string.IsNullOrWhiteSpace(exeName))
                        {
                            continue;
                        }

                        AddIndexedPath(index, exeName, exePath);
                    }
                }
            }
        }

        return index;
    }

    private static void IndexSteamAppInfoIcons(Dictionary<string, List<string>> index, string steamRoot)
    {
        string appInfoPath;
        string iconDirectory;
        try
        {
            appInfoPath = Path.Combine(steamRoot, "appcache", "appinfo.vdf");
            iconDirectory = Path.Combine(steamRoot, "steam", "games");
        }
        catch
        {
            return;
        }

        if (!File.Exists(appInfoPath) || !Directory.Exists(iconDirectory))
        {
            return;
        }

        Dictionary<string, string> iconPaths;
        try
        {
            iconPaths = Directory.EnumerateFiles(iconDirectory, "*.ico", SearchOption.TopDirectoryOnly)
                .Select(path => new { Hash = Path.GetFileNameWithoutExtension(path), Path = path })
                .Where(item => item.Hash.Length == 40)
                .GroupBy(item => item.Hash, StringComparer.OrdinalIgnoreCase)
                .ToDictionary(group => group.Key, group => group.First().Path, StringComparer.OrdinalIgnoreCase);
        }
        catch
        {
            return;
        }

        if (iconPaths.Count == 0)
        {
            return;
        }

        string appInfoText;
        try
        {
            appInfoText = Encoding.UTF8.GetString(File.ReadAllBytes(appInfoPath));
        }
        catch
        {
            return;
        }

        foreach (Match executableMatch in SteamExecutableRegex.Matches(appInfoText))
        {
            var executableName = NormalizeSteamExecutableName(executableMatch.Value);
            if (string.IsNullOrWhiteSpace(executableName))
            {
                continue;
            }

            var iconPath = FindNearestSteamIconPath(appInfoText, executableMatch.Index, iconPaths);
            if (iconPath == null)
            {
                continue;
            }

            AddIndexedPath(index, executableName!, iconPath);
        }
    }

    private static string? NormalizeSteamExecutableName(string executableValue)
    {
        var normalized = executableValue.Trim().Replace('/', '\\');
        var fileName = Path.GetFileName(normalized);
        return string.IsNullOrWhiteSpace(fileName) ? null : fileName;
    }

    private static string? FindNearestSteamIconPath(string appInfoText, int executableIndex, Dictionary<string, string> iconPaths)
    {
        var startIndex = Math.Max(0, executableIndex - SteamAppInfoIconSearchWindow);
        var length = executableIndex - startIndex;
        if (length <= 0)
        {
            return null;
        }

        var precedingText = appInfoText.Substring(startIndex, length);
        var matches = SteamIconHashRegex.Matches(precedingText);
        for (var index = matches.Count - 1; index >= 0; index--)
        {
            if (iconPaths.TryGetValue(matches[index].Value, out var iconPath))
            {
                return iconPath;
            }
        }

        return null;
    }

    private static void AddIndexedPath(Dictionary<string, List<string>> index, string executableName, string path)
    {
        if (!index.TryGetValue(executableName, out var paths))
        {
            paths = new List<string>();
            index[executableName] = paths;
        }

        if (!paths.Contains(path, StringComparer.OrdinalIgnoreCase))
        {
            paths.Add(path);
        }
    }

    private static IEnumerable<string> GetSteamAppManifestPaths(string libraryRoot)
    {
        string steamAppsPath;
        try
        {
            steamAppsPath = Path.Combine(libraryRoot, "steamapps");
        }
        catch
        {
            yield break;
        }

        if (!Directory.Exists(steamAppsPath))
        {
            yield break;
        }

        IEnumerable<string> manifests;
        try
        {
            manifests = Directory.EnumerateFiles(steamAppsPath, "appmanifest_*.acf", SearchOption.TopDirectoryOnly).ToList();
        }
        catch
        {
            yield break;
        }

        foreach (var manifest in manifests)
        {
            yield return manifest;
        }
    }

    private static SteamAppEntry? TryReadSteamAppManifest(string libraryRoot, string manifestPath)
    {
        Dictionary<string, string> manifestValues;
        try
        {
            manifestValues = File.ReadLines(manifestPath)
                .Select(TryParseKeyValueLine)
                .Where(pair => pair.HasValue)
                .ToDictionary(
                    pair => pair!.Value.Key,
                    pair => pair!.Value.Value,
                    StringComparer.OrdinalIgnoreCase);
        }
        catch
        {
            return null;
        }

        if (!manifestValues.TryGetValue("installdir", out var installDir) ||
            string.IsNullOrWhiteSpace(installDir))
        {
            return null;
        }

        string installPath;
        try
        {
            installPath = Path.Combine(libraryRoot, "steamapps", "common", installDir);
        }
        catch
        {
            return null;
        }

        var normalizedInstallPath = NormalizeDirectoryPath(installPath);
        if (normalizedInstallPath == null || !Directory.Exists(normalizedInstallPath))
        {
            return null;
        }

        return new SteamAppEntry(normalizedInstallPath);
    }

    private static KeyValuePair<string, string>? TryParseKeyValueLine(string line)
    {
        var trimmed = line.Trim();
        if (!trimmed.StartsWith("\"", StringComparison.Ordinal))
        {
            return null;
        }

        var parts = trimmed.Split(new[] { '"' }, StringSplitOptions.RemoveEmptyEntries)
            .Select(part => part.Trim())
            .Where(part => !string.IsNullOrWhiteSpace(part))
            .ToList();

        if (parts.Count < 2)
        {
            return null;
        }

        return new KeyValuePair<string, string>(parts[0], parts[1].Replace(@"\\", @"\"));
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

    private static IEnumerable<string> FindExecutablesNearRoot(string root)
    {
        if (!Directory.Exists(root))
        {
            yield break;
        }

        foreach (var exePath in EnumerateExecutables(root))
        {
            yield return exePath;
        }

        IEnumerable<string> firstLevelDirectories;
        try
        {
            firstLevelDirectories = Directory.EnumerateDirectories(root).ToList();
        }
        catch
        {
            yield break;
        }

        foreach (var directory in firstLevelDirectories)
        {
            foreach (var exePath in EnumerateExecutables(directory))
            {
                yield return exePath;
            }
        }
    }

    private static IEnumerable<string> EnumerateExecutables(string root)
    {
        IEnumerable<string> files;
        try
        {
            files = Directory.EnumerateFiles(root, "*.exe", SearchOption.TopDirectoryOnly).ToList();
        }
        catch
        {
            yield break;
        }

        foreach (var file in files)
        {
            yield return file;
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

    private sealed class ShortcutIconEntry
    {
        public ShortcutIconEntry(string? shortcutName, string? targetName, string? iconPath, string? targetPath)
        {
            ShortcutName = shortcutName;
            TargetName = targetName;
            IconPath = iconPath;
            TargetPath = targetPath;
        }

        public string? ShortcutName { get; }
        public string? TargetName { get; }
        public string? IconPath { get; }
        public string? TargetPath { get; }
    }

    private sealed class SteamAppEntry
    {
        public SteamAppEntry(string installPath)
        {
            InstallPath = installPath;
        }

        public string InstallPath { get; }
    }
}
