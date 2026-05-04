using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;
using System.Text;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Microsoft.Win32;

namespace KeyStats.Helpers;

public static class AppIconHelper
{
    private const int MaxShortcutScanCount = 3000;
    private const int MaxSteamAppInfoBytes = 16 * 1024 * 1024;
    private const int SteamAppInfoIconSearchWindow = 16000;
    private const int MaxSteamExecutableTokenBytes = 260;
    private static readonly TimeSpan FailedIconCacheDuration = TimeSpan.FromSeconds(10);
    private static readonly TimeSpan IndexRetryDelay = TimeSpan.FromSeconds(30);
    private static readonly Dictionary<string, IconCacheEntry> _iconCache = new(StringComparer.OrdinalIgnoreCase);
    private static readonly object _lock = new object();
    private static readonly object _indexLock = new object();
    private static bool _shortcutIndexBuildInProgress;
    private static bool _steamIndexBuildInProgress;
    private static DateTime _shortcutIndexLastAttemptUtc = DateTime.MinValue;
    private static DateTime _steamIndexLastAttemptUtc = DateTime.MinValue;
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
            foreach (var iconCandidate in GetIconCandidatePaths(processName, displayName))
            {
                var icon = ExtractIconFromFile(iconCandidate.Path, iconCandidate.IconIndex);
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

    private static IEnumerable<IconCandidate> GetIconCandidatePaths(string processName, string? displayName)
    {
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        foreach (var path in GetRunningProcessPaths(processName)
                     .Concat(GetAppPathsRegistryEntries(processName))
                     .Concat(GetKnownInstallPaths(processName))
                     .Concat(GetIndexedShortcutIconPaths(processName, displayName))
                     .Concat(GetIndexedSteamLibraryPaths(processName)))
        {
            var candidate = NormalizeIconCandidate(path);
            if (candidate == null || !File.Exists(candidate.Path))
            {
                continue;
            }

            if (seen.Add(candidate.CacheKey))
            {
                yield return candidate;
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
            if (_shortcutIndex != null ||
                _shortcutIndexBuildInProgress ||
                DateTime.UtcNow - _shortcutIndexLastAttemptUtc < IndexRetryDelay)
            {
                return;
            }

            _shortcutIndexBuildInProgress = true;
            _shortcutIndexLastAttemptUtc = DateTime.UtcNow;
        }

        var thread = new Thread(() =>
        {
            try
            {
                var shortcutIndex = BuildShortcutIndex().ToList();
                lock (_indexLock)
                {
                    _shortcutIndex = shortcutIndex;
                    _shortcutIndexBuildInProgress = false;
                }
            }
            catch
            {
                lock (_indexLock)
                {
                    _shortcutIndex = null;
                    _shortcutIndexBuildInProgress = false;
                }
            }
        })
        {
            IsBackground = true,
            Name = "KeyStats Shortcut Icon Index"
        };

        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
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
            if (_steamExecutableIndex != null ||
                _steamIndexBuildInProgress ||
                DateTime.UtcNow - _steamIndexLastAttemptUtc < IndexRetryDelay)
            {
                return;
            }

            _steamIndexBuildInProgress = true;
            _steamIndexLastAttemptUtc = DateTime.UtcNow;
        }

        ThreadPool.QueueUserWorkItem(_ =>
        {
            try
            {
                var steamIndex = BuildSteamExecutableIndex();
                lock (_indexLock)
                {
                    _steamExecutableIndex = steamIndex;
                    _steamIndexBuildInProgress = false;
                }
            }
            catch
            {
                lock (_indexLock)
                {
                    _steamExecutableIndex = null;
                    _steamIndexBuildInProgress = false;
                }
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

        var appInfoFile = new FileInfo(appInfoPath);
        if (appInfoFile.Length > MaxSteamAppInfoBytes)
        {
            return;
        }

        byte[] appInfoBytes;
        try
        {
            appInfoBytes = File.ReadAllBytes(appInfoPath);
        }
        catch
        {
            return;
        }

        foreach (var executableMatch in FindSteamExecutableMatches(appInfoBytes))
        {
            var executableName = NormalizeSteamExecutableName(executableMatch.Value);
            if (string.IsNullOrWhiteSpace(executableName))
            {
                continue;
            }

            var iconPath = FindNearestSteamIconPath(appInfoBytes, executableMatch.Index, iconPaths);
            if (iconPath == null)
            {
                continue;
            }

            AddIndexedPath(index, executableName!, iconPath);
        }
    }

    private static IEnumerable<SteamExecutableMatch> FindSteamExecutableMatches(byte[] appInfoBytes)
    {
        for (var index = 0; index <= appInfoBytes.Length - 4; index++)
        {
            if (!IsAsciiDotExeAt(appInfoBytes, index))
            {
                continue;
            }

            var startIndex = index;
            var minStartIndex = Math.Max(0, index - MaxSteamExecutableTokenBytes + 1);
            while (startIndex > minStartIndex && IsSteamExecutablePathByte(appInfoBytes[startIndex - 1]))
            {
                startIndex--;
            }

            var length = index + 4 - startIndex;
            if (length <= 4)
            {
                continue;
            }

            yield return new SteamExecutableMatch(
                index,
                Encoding.ASCII.GetString(appInfoBytes, startIndex, length));
        }
    }

    private static string? NormalizeSteamExecutableName(string executableValue)
    {
        var normalized = executableValue.Trim().Replace('/', '\\');
        var fileName = Path.GetFileName(normalized);
        return string.IsNullOrWhiteSpace(fileName) ? null : fileName;
    }

    private static string? FindNearestSteamIconPath(byte[] appInfoBytes, int executableIndex, Dictionary<string, string> iconPaths)
    {
        var startIndex = Math.Max(0, executableIndex - SteamAppInfoIconSearchWindow);
        for (var index = executableIndex - 40; index >= startIndex; index--)
        {
            if (!IsSteamIconHashAt(appInfoBytes, index))
            {
                continue;
            }

            var hash = Encoding.ASCII.GetString(appInfoBytes, index, 40);
            if (iconPaths.TryGetValue(hash, out var iconPath))
            {
                return iconPath;
            }
        }

        return null;
    }

    private static bool IsAsciiDotExeAt(byte[] bytes, int index)
    {
        return bytes[index] == (byte)'.' &&
               IsAsciiLower(bytes[index + 1], 'e') &&
               IsAsciiLower(bytes[index + 2], 'x') &&
               IsAsciiLower(bytes[index + 3], 'e');
    }

    private static bool IsAsciiLower(byte value, char expected)
    {
        return char.ToLowerInvariant((char)value) == expected;
    }

    private static bool IsSteamExecutablePathByte(byte value)
    {
        return value == (byte)' ' ||
               value == (byte)'_' ||
               value == (byte)'.' ||
               value == (byte)'-' ||
               value == (byte)'\\' ||
               value == (byte)'/' ||
               (value >= (byte)'0' && value <= (byte)'9') ||
               (value >= (byte)'A' && value <= (byte)'Z') ||
               (value >= (byte)'a' && value <= (byte)'z');
    }

    private static bool IsSteamIconHashAt(byte[] bytes, int index)
    {
        if (index < 0 || index + 40 > bytes.Length)
        {
            return false;
        }

        for (var offset = 0; offset < 40; offset++)
        {
            var value = bytes[index + offset];
            var isHex = (value >= (byte)'0' && value <= (byte)'9') ||
                        (value >= (byte)'a' && value <= (byte)'f') ||
                        (value >= (byte)'A' && value <= (byte)'F');
            if (!isHex)
            {
                return false;
            }
        }

        return true;
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
        return string.IsNullOrWhiteSpace(path) ? null : path;
    }

    private static IconCandidate? NormalizeIconCandidate(string? rawPath)
    {
        var path = NormalizeIconPath(rawPath);
        if (string.IsNullOrWhiteSpace(path))
        {
            return null;
        }

        var normalizedPath = path!;
        int? iconIndex = null;
        var commaIndex = normalizedPath.LastIndexOf(',');
        if (commaIndex > 1 && int.TryParse(normalizedPath.Substring(commaIndex + 1).Trim(), out var parsedIconIndex))
        {
            iconIndex = parsedIconIndex;
            normalizedPath = normalizedPath.Substring(0, commaIndex).Trim().Trim('"');
        }

        return string.IsNullOrWhiteSpace(normalizedPath) ? null : new IconCandidate(normalizedPath, iconIndex);
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

    private static ImageSource? ExtractIconFromFile(string filePath, int? iconIndex = null)
    {
        if (iconIndex.HasValue)
        {
            var indexedIcon = ExtractIconFromFileByIndex(filePath, iconIndex.Value);
            if (indexedIcon != null)
            {
                return indexedIcon;
            }
        }

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

    private static ImageSource? ExtractIconFromFileByIndex(string filePath, int iconIndex)
    {
        var largeIcons = new[] { IntPtr.Zero };
        var smallIcons = new[] { IntPtr.Zero };

        try
        {
            var extractedCount = ExtractIconEx(filePath, iconIndex, largeIcons, smallIcons, 1);
            if (extractedCount == 0)
            {
                return null;
            }

            var iconHandle = largeIcons[0] != IntPtr.Zero ? largeIcons[0] : smallIcons[0];
            if (iconHandle == IntPtr.Zero)
            {
                return null;
            }

            var imageSource = Imaging.CreateBitmapSourceFromHIcon(
                iconHandle,
                Int32Rect.Empty,
                BitmapSizeOptions.FromEmptyOptions());

            imageSource.Freeze();
            return imageSource;
        }
        catch
        {
            return null;
        }
        finally
        {
            if (largeIcons[0] != IntPtr.Zero)
            {
                NativeInterop.DestroyIcon(largeIcons[0]);
            }

            if (smallIcons[0] != IntPtr.Zero && smallIcons[0] != largeIcons[0])
            {
                NativeInterop.DestroyIcon(smallIcons[0]);
            }
        }
    }

    [System.Runtime.InteropServices.DllImport("gdi32.dll")]
    private static extern bool DeleteObject(IntPtr hObject);

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern uint ExtractIconEx(
        string szFileName,
        int nIconIndex,
        IntPtr[] phiconLarge,
        IntPtr[] phiconSmall,
        uint nIcons);

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

    private sealed class IconCandidate
    {
        public IconCandidate(string path, int? iconIndex)
        {
            Path = path;
            IconIndex = iconIndex;
        }

        public string Path { get; }
        public int? IconIndex { get; }
        public string CacheKey => IconIndex.HasValue ? $"{Path},{IconIndex.Value}" : Path;
    }

    private sealed class SteamAppEntry
    {
        public SteamAppEntry(string installPath)
        {
            InstallPath = installPath;
        }

        public string InstallPath { get; }
    }

    private readonly struct SteamExecutableMatch
    {
        public SteamExecutableMatch(int index, string value)
        {
            Index = index;
            Value = value;
        }

        public int Index { get; }
        public string Value { get; }
    }
}
