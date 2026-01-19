using System;
using Microsoft.Win32;

namespace KeyStats.Services;

public class StartupManager
{
    private static StartupManager? _instance;
    public static StartupManager Instance => _instance ??= new StartupManager();

    private const string RegistryKeyPath = @"SOFTWARE\Microsoft\Windows\CurrentVersion\Run";
    private const string AppName = "KeyStats";

    private StartupManager() { }

    public bool IsEnabled
    {
        get
        {
            try
            {
                using var key = Registry.CurrentUser.OpenSubKey(RegistryKeyPath, false);
                return key?.GetValue(AppName) != null;
            }
            catch
            {
                return false;
            }
        }
    }

    public void SetEnabled(bool enabled)
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RegistryKeyPath, true);
            if (key == null) return;

            if (enabled)
            {
                // .NET Framework 4.8 兼容：使用 Assembly.Location 替代 Environment.ProcessPath
                var exePath = System.Reflection.Assembly.GetExecutingAssembly().Location;
                if (!string.IsNullOrEmpty(exePath))
                {
                    key.SetValue(AppName, $"\"{exePath}\"");
                }
            }
            else
            {
                key.DeleteValue(AppName, false);
            }

            // Update settings
            StatsManager.Instance.Settings.LaunchAtStartup = enabled;
            StatsManager.Instance.SaveSettings();
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"Error setting startup: {ex.Message}");
            throw;
        }
    }
}
