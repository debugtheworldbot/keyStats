using System.Windows;
using System.Windows.Media;
using Forms = System.Windows.Forms;

namespace KeyStats.Helpers;

public static class MonitorGeometryHelper
{
    /// <summary>
    /// Converts a monitor work area from device pixels to WPF device-independent units.
    /// </summary>
    public static Rect GetWorkingAreaInDips(Forms.Screen screen, Matrix fallbackTransform)
    {
        var bounds = screen.Bounds;
        var center = new NativeInterop.POINT
        {
            x = bounds.Left + bounds.Width / 2,
            y = bounds.Top + bounds.Height / 2
        };
        var monitor = NativeInterop.MonitorFromPoint(center, NativeInterop.MONITOR_DEFAULTTONEAREST);
        if (NativeInterop.TryGetMonitorScaleFactor(monitor, out var scaleFactor))
        {
            var workingArea = screen.WorkingArea;
            return new Rect(
                workingArea.Left / scaleFactor,
                workingArea.Top / scaleFactor,
                workingArea.Width / scaleFactor,
                workingArea.Height / scaleFactor);
        }

        var fallbackTopLeft = fallbackTransform.Transform(
            new Point(screen.WorkingArea.Left, screen.WorkingArea.Top));
        var fallbackBottomRight = fallbackTransform.Transform(
            new Point(screen.WorkingArea.Right, screen.WorkingArea.Bottom));
        return new Rect(fallbackTopLeft, fallbackBottomRight);
    }
}
