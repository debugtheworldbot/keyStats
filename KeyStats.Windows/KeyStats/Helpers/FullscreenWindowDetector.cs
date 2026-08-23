using System;
using System.Runtime.InteropServices;

namespace KeyStats.Helpers;

public static class FullscreenWindowDetector
{
    private const int BoundsTolerance = 2;

    /// <summary>
    /// Returns whether the foreground app covers the bounds of its nearest monitor.
    /// </summary>
    public static bool IsForegroundWindowFullscreen()
    {
        var windowHandle = NativeInterop.GetForegroundWindow();
        if (windowHandle == IntPtr.Zero ||
            windowHandle == NativeInterop.GetDesktopWindow() ||
            windowHandle == NativeInterop.GetShellWindow() ||
            !NativeInterop.IsWindowVisible(windowHandle) ||
            NativeInterop.IsIconic(windowHandle) ||
            !NativeInterop.GetWindowRect(windowHandle, out var windowBounds))
        {
            return false;
        }

        var monitorHandle = NativeInterop.MonitorFromWindow(
            windowHandle,
            NativeInterop.MONITOR_DEFAULTTONEAREST);
        if (monitorHandle == IntPtr.Zero)
        {
            return false;
        }

        var monitorInfo = new NativeInterop.MONITORINFO
        {
            cbSize = (uint)Marshal.SizeOf(typeof(NativeInterop.MONITORINFO))
        };
        if (!NativeInterop.GetMonitorInfo(monitorHandle, ref monitorInfo))
        {
            return false;
        }

        if (!CoversMonitor(windowBounds, monitorInfo.rcMonitor))
        {
            return false;
        }

        // Some video players keep WS_MAXIMIZE while Windows still reports fullscreen mode.
        return !NativeInterop.IsZoomed(windowHandle) ||
               IsSystemInFullscreenMode();
    }

    private static bool IsSystemInFullscreenMode()
    {
        var result = NativeInterop.SHQueryUserNotificationState(out var state);
        if (result != 0)
        {
            return false;
        }

        return state == NativeInterop.UserNotificationState.Busy ||
               state == NativeInterop.UserNotificationState.RunningDirect3DFullscreen ||
               state == NativeInterop.UserNotificationState.PresentationMode;
    }

    internal static bool CoversMonitor(NativeInterop.RECT windowBounds, NativeInterop.RECT monitorBounds)
    {
        if (windowBounds.Right <= windowBounds.Left ||
            windowBounds.Bottom <= windowBounds.Top ||
            monitorBounds.Right <= monitorBounds.Left ||
            monitorBounds.Bottom <= monitorBounds.Top)
        {
            return false;
        }

        return windowBounds.Left <= monitorBounds.Left + BoundsTolerance &&
               windowBounds.Top <= monitorBounds.Top + BoundsTolerance &&
               windowBounds.Right >= monitorBounds.Right - BoundsTolerance &&
               windowBounds.Bottom >= monitorBounds.Bottom - BoundsTolerance;
    }
}
