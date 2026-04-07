using System;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;

namespace KeyStats.Helpers;

public static class WindowBackdropHelper
{
    public static bool Apply(Window window, NativeInterop.DwmSystemBackdropType backdropType)
    {
        var handle = new WindowInteropHelper(window).Handle;
        if (handle == IntPtr.Zero)
        {
            return false;
        }

        NativeInterop.TryExtendFrameIntoClientArea(handle);
        NativeInterop.TrySetImmersiveDarkMode(handle, ThemeManager.Instance.IsDarkTheme);
        var backdropApplied = NativeInterop.TrySetSystemBackdrop(handle, backdropType);
        NativeInterop.TrySetRoundedCorners(handle);
        NativeInterop.TryClearWindowBorder(handle);

        if (PresentationSource.FromVisual(window) is HwndSource hwndSource)
        {
            hwndSource.CompositionTarget.BackgroundColor = Colors.Transparent;
        }

        return backdropApplied;
    }
}
