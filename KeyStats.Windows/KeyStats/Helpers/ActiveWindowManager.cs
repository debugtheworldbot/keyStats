using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace KeyStats.Helpers;

public class ActiveWindowManager
{
    private static IntPtr _lastWindowHandle = IntPtr.Zero;
    private static string _lastProcessName = "";
    private static uint _lastProcessId = 0;
    private static readonly object _lock = new object();

    /// <summary>
    /// Gets the process name of the current foreground window.
    /// Returns "Unknown" if it fails.
    /// </summary>
    public static string GetActiveProcessName()
    {
        try
        {
            var hWnd = NativeInterop.GetForegroundWindow();
            if (hWnd == IntPtr.Zero) return "Unknown";

            lock (_lock)
            {
                // Simple caching: if the window handle hasn't changed, return the cached name
                if (hWnd == _lastWindowHandle && !string.IsNullOrEmpty(_lastProcessName))
                {
                    return _lastProcessName;
                }

                NativeInterop.GetWindowThreadProcessId(hWnd, out uint processId);
                
                if (processId == 0) return "Unknown";

                // Secondary caching: if window changed but PID is same (e.g. different window of same app), 
                // we could reuse name, but let's re-fetch to be safe or if we want window titles later.
                // For now, let's check PID to avoid Process lookup overhead if possible.
                if (processId == _lastProcessId && !string.IsNullOrEmpty(_lastProcessName))
                {
                    _lastWindowHandle = hWnd;
                    return _lastProcessName;
                }

                // Fetch new process info
                using (var process = Process.GetProcessById((int)processId))
                {
                    _lastProcessName = process.ProcessName;
                    _lastProcessId = processId;
                    _lastWindowHandle = hWnd;
                }
            }
            
            return _lastProcessName;
        }
        catch (Exception)
        {
            // Fallback for errors (e.g. process exiting, access denied)
            return "Unknown";
        }
    }
}
