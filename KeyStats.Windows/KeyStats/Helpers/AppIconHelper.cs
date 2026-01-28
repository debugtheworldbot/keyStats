using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace KeyStats.Helpers;

public static class AppIconHelper
{
    private static readonly Dictionary<string, ImageSource?> _iconCache = new();
    private static readonly object _lock = new object();

    /// <summary>
    /// Gets the icon for an application by its process name.
    /// Returns null if the icon cannot be retrieved.
    /// </summary>
    public static ImageSource? GetAppIcon(string processName)
    {
        if (string.IsNullOrEmpty(processName) || processName == "Unknown")
        {
            return null;
        }

        lock (_lock)
        {
            if (_iconCache.TryGetValue(processName, out var cachedIcon))
            {
                return cachedIcon;
            }
        }

        var icon = LoadAppIcon(processName);

        lock (_lock)
        {
            _iconCache[processName] = icon;
        }

        return icon;
    }

    private static ImageSource? LoadAppIcon(string processName)
    {
        try
        {
            // Try to find a running process with this name to get its executable path
            var processes = Process.GetProcessesByName(processName);
            if (processes.Length > 0)
            {
                try
                {
                    var exePath = processes[0].MainModule?.FileName;
                    if (!string.IsNullOrEmpty(exePath) && File.Exists(exePath))
                    {
                        return ExtractIconFromFile(exePath!);
                    }
                }
                catch
                {
                    // Access denied or process exited
                }
                finally
                {
                    foreach (var p in processes)
                    {
                        p.Dispose();
                    }
                }
            }

            // Fallback: try common locations
            var possiblePaths = new[]
            {
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), processName, $"{processName}.exe"),
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), processName, $"{processName}.exe"),
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), processName, $"{processName}.exe"),
            };

            foreach (var path in possiblePaths)
            {
                if (File.Exists(path))
                {
                    return ExtractIconFromFile(path);
                }
            }
        }
        catch
        {
            // Ignore errors
        }

        return null;
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
}
