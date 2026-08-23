using System;
using System.Windows.Threading;
using KeyStats.Views;

namespace KeyStats.Helpers;

/// <summary>
/// Hosts the compact statistics control as a native child of the primary taskbar.
/// </summary>
public sealed class TaskbarStatsHost : IDisposable
{
    private const int BaseWidth = 142;
    private const int BaseHeight = 40;
    private const int BaseEdgeInset = 2;
    private const int BaseFallbackNotificationWidth = 96;

    private readonly DispatcherTimer _positionTimer;
    private TaskbarStatsNativeControl? _control;
    private IntPtr _taskbarHandle;
    private bool _enabled;
    private bool _isDisposed;

    public bool IsEnabled => _enabled;

    public TaskbarStatsHost()
    {
        _positionTimer = new DispatcherTimer(DispatcherPriority.Background)
        {
            Interval = TimeSpan.FromSeconds(1)
        };
        _positionTimer.Tick += OnPositionTimerTick;
    }

    public void SetEnabled(bool enabled)
    {
        if (_isDisposed || _enabled == enabled)
        {
            return;
        }

        _enabled = enabled;
        if (!enabled)
        {
            _positionTimer.Stop();
            DestroyControl();
            return;
        }

        EnsureHost();
        _positionTimer.Start();
    }

    public void Recreate()
    {
        if (_isDisposed || !_enabled)
        {
            return;
        }

        DestroyControl();
        EnsureHost();
    }

    public void Dispose()
    {
        if (_isDisposed)
        {
            return;
        }

        _isDisposed = true;
        _positionTimer.Stop();
        _positionTimer.Tick -= OnPositionTimerTick;
        DestroyControl();
    }

    private void OnPositionTimerTick(object? sender, EventArgs e)
    {
        EnsureHost();
    }

    private void EnsureHost()
    {
        if (!_enabled || _isDisposed)
        {
            return;
        }

        var taskbar = NativeInterop.FindWindow("Shell_TrayWnd", null);
        if (taskbar == IntPtr.Zero || !NativeInterop.IsWindow(taskbar))
        {
            DestroyControl();
            return;
        }

        var controlHandle = GetControlHandle();
        var parentChanged = _taskbarHandle != IntPtr.Zero && _taskbarHandle != taskbar;
        var nativeParentChanged = controlHandle != IntPtr.Zero &&
                                  NativeInterop.GetParent(controlHandle) != taskbar;
        if (controlHandle == IntPtr.Zero || parentChanged || nativeParentChanged)
        {
            DestroyControl();
            TryCreateControl(taskbar);
            return;
        }

        if (TryGetPlacement(taskbar, out var placement))
        {
            ApplyPlacement(placement);
        }
    }

    private void TryCreateControl(IntPtr taskbar)
    {
        if (!TryGetPlacement(taskbar, out var placement))
        {
            return;
        }

        TaskbarStatsNativeControl? control = null;
        try
        {
            control = new TaskbarStatsNativeControl();
            control.CreateInTaskbar(taskbar);
            _taskbarHandle = taskbar;
            _control = control;
            ApplyPlacement(placement);
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Taskbar stats native window creation failed: {ex.Message}");
            control?.Dispose();
            _control = null;
            _taskbarHandle = IntPtr.Zero;
        }
    }

    private void ApplyPlacement(Placement placement)
    {
        var handle = GetControlHandle();
        if (handle == IntPtr.Zero)
        {
            return;
        }

        _control?.SetCompactMode(placement.Compact);
        NativeInterop.SetWindowPos(
            handle,
            NativeInterop.HWND_TOP,
            placement.RelativeX,
            placement.RelativeY,
            placement.Width,
            placement.Height,
            NativeInterop.SWP_NOACTIVATE | NativeInterop.SWP_SHOWWINDOW);
    }

    private static bool TryGetPlacement(IntPtr taskbar, out Placement placement)
    {
        placement = default;
        if (!NativeInterop.GetWindowRect(taskbar, out var taskbarRect))
        {
            return false;
        }

        var taskbarWidth = taskbarRect.Right - taskbarRect.Left;
        var taskbarHeight = taskbarRect.Bottom - taskbarRect.Top;
        if (taskbarWidth <= 0 || taskbarHeight <= 0)
        {
            return false;
        }

        var dpi = NativeInterop.TryGetDpiForWindow(taskbar);
        var scale = dpi / 96.0;
        var edgeInset = Math.Max(1, Scale(BaseEdgeInset, scale));
        var horizontal = taskbarWidth >= taskbarHeight;
        var notify = NativeInterop.FindWindowEx(taskbar, IntPtr.Zero, "TrayNotifyWnd", null);
        NativeInterop.RECT notifyRect = default;
        var hasNotifyRect = notify != IntPtr.Zero && NativeInterop.GetWindowRect(notify, out notifyRect);

        int width;
        int height;
        int relativeX;
        int relativeY;
        bool compact;

        if (horizontal)
        {
            width = Math.Min(Scale(BaseWidth, scale), Math.Max(1, taskbarWidth - edgeInset * 2));
            height = Math.Min(Scale(BaseHeight, scale), Math.Max(1, taskbarHeight - edgeInset * 2));
            var notifyLeft = hasNotifyRect
                ? notifyRect.Left - taskbarRect.Left
                : taskbarWidth - Scale(BaseFallbackNotificationWidth, scale);
            relativeX = Math.Max(edgeInset, notifyLeft - width - edgeInset);
            relativeY = Math.Max(edgeInset, (taskbarHeight - height) / 2);
            compact = false;
        }
        else
        {
            width = Math.Max(1, taskbarWidth - edgeInset * 2);
            height = Math.Min(Scale(BaseHeight, scale), Math.Max(1, taskbarHeight - edgeInset * 2));
            var notifyTop = hasNotifyRect
                ? notifyRect.Top - taskbarRect.Top
                : taskbarHeight - Scale(BaseFallbackNotificationWidth, scale);
            relativeX = edgeInset;
            relativeY = Math.Max(edgeInset, notifyTop - height - edgeInset);
            compact = true;
        }

        placement = new Placement(relativeX, relativeY, width, height, compact);
        return true;
    }

    private static int Scale(int value, double scale)
    {
        return Math.Max(1, (int)Math.Round(value * scale, MidpointRounding.AwayFromZero));
    }

    private IntPtr GetControlHandle()
    {
        if (_control == null || !_control.IsHandleCreated)
        {
            return IntPtr.Zero;
        }

        var handle = _control.Handle;
        return handle != IntPtr.Zero && NativeInterop.IsWindow(handle) ? handle : IntPtr.Zero;
    }

    private void DestroyControl()
    {
        if (_control != null)
        {
            try
            {
                _control.Dispose();
            }
            catch (InvalidOperationException)
            {
                // Explorer may have already destroyed the cross-process child HWND.
            }
            _control = null;
        }

        _taskbarHandle = IntPtr.Zero;
    }

    private readonly struct Placement
    {
        public Placement(int relativeX, int relativeY, int width, int height, bool compact)
        {
            RelativeX = relativeX;
            RelativeY = relativeY;
            Width = width;
            Height = height;
            Compact = compact;
        }

        public int RelativeX { get; }
        public int RelativeY { get; }
        public int Width { get; }
        public int Height { get; }
        public bool Compact { get; }
    }
}
