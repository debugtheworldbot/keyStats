using System;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using KeyStats.Views;

namespace KeyStats.Helpers;

/// <summary>
/// Hosts the compact statistics view as its own HWND beside the notification area.
/// </summary>
public sealed class TaskbarStatsHost : IDisposable
{
    private const int BaseWidth = 142;
    private const int BaseHeight = 40;
    private const int BaseEdgeInset = 2;
    private const int BaseFallbackNotificationWidth = 96;
    private const int WM_MOUSEACTIVATE = 0x0021;
    private const int MA_NOACTIVATE = 3;

    private readonly DispatcherTimer _positionTimer;
    private HwndSource? _source;
    private TaskbarStatsView? _view;
    private IntPtr _taskbarHandle;
    private bool _isEmbedded;
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
        ThemeManager.Instance.ThemeChanged += OnThemeChanged;
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
            DestroySource();
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

        DestroySource();
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
        ThemeManager.Instance.ThemeChanged -= OnThemeChanged;
        DestroySource();
    }

    private void OnPositionTimerTick(object? sender, EventArgs e)
    {
        EnsureHost();
    }

    private void OnThemeChanged()
    {
        if (_isDisposed)
        {
            return;
        }

        Application.Current?.Dispatcher.BeginInvoke(new Action(() =>
        {
            ApplyCompositionBackground();
            _view?.InvalidateVisual();
        }));
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
            DestroySource();
            return;
        }

        var sourceHandle = GetSourceHandle();
        var parentChanged = _taskbarHandle != IntPtr.Zero && _taskbarHandle != taskbar;
        var embeddedParentChanged = _isEmbedded &&
                                    sourceHandle != IntPtr.Zero &&
                                    NativeInterop.GetParent(sourceHandle) != taskbar;
        if (sourceHandle == IntPtr.Zero || parentChanged || embeddedParentChanged)
        {
            DestroySource();
            TryCreateHost(taskbar);
            return;
        }

        if (TryGetPlacement(taskbar, out var placement))
        {
            ApplyPlacement(placement);
        }
    }

    private void TryCreateHost(IntPtr taskbar)
    {
        if (!TryGetPlacement(taskbar, out var placement))
        {
            return;
        }

        _taskbarHandle = taskbar;
        try
        {
            CreateSource(placement, embedded: true);
            return;
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Taskbar stats embedding failed, using overlay fallback: {ex.Message}");
            DestroySource();
            _taskbarHandle = taskbar;
        }

        try
        {
            CreateSource(placement, embedded: false);
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Taskbar stats overlay fallback failed: {ex.Message}");
            DestroySource();
        }
    }

    private void CreateSource(Placement placement, bool embedded)
    {
        var parameters = new HwndSourceParameters("KeyStatsTaskbarStatsWindow")
        {
            ParentWindow = embedded ? _taskbarHandle : IntPtr.Zero,
            PositionX = embedded ? placement.RelativeX : placement.ScreenX,
            PositionY = embedded ? placement.RelativeY : placement.ScreenY,
            Width = placement.Width,
            Height = placement.Height,
            WindowStyle = embedded
                ? NativeInterop.WS_CHILD |
                  NativeInterop.WS_VISIBLE |
                  NativeInterop.WS_CLIPSIBLINGS |
                  NativeInterop.WS_CLIPCHILDREN
                : NativeInterop.WS_POPUP | NativeInterop.WS_VISIBLE,
            ExtendedWindowStyle = NativeInterop.WS_EX_TOOLWINDOW |
                                  NativeInterop.WS_EX_NOACTIVATE |
                                  NativeInterop.WS_EX_NOPARENTNOTIFY
        };

        HwndSource? source = null;
        TaskbarStatsView? view = null;
        try
        {
            source = new HwndSource(parameters);
            if (source.Handle == IntPtr.Zero)
            {
                throw new InvalidOperationException("The taskbar statistics HWND was not created.");
            }

            view = new TaskbarStatsView();
            view.SetCompactMode(placement.Compact);
            source.RootVisual = view;
            source.AddHook(WindowHook);

            _source = source;
            _view = view;
            _isEmbedded = embedded;
            ApplyCompositionBackground();
            ApplyPlacement(placement);
        }
        catch
        {
            view?.Cleanup();
            source?.Dispose();
            throw;
        }
    }

    private IntPtr WindowHook(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == WM_MOUSEACTIVATE)
        {
            handled = true;
            return new IntPtr(MA_NOACTIVATE);
        }

        return IntPtr.Zero;
    }

    private void ApplyPlacement(Placement placement)
    {
        var handle = GetSourceHandle();
        if (handle == IntPtr.Zero)
        {
            return;
        }

        _view?.SetCompactMode(placement.Compact);
        var x = _isEmbedded ? placement.RelativeX : placement.ScreenX;
        var y = _isEmbedded ? placement.RelativeY : placement.ScreenY;
        NativeInterop.SetWindowPos(
            handle,
            _isEmbedded ? NativeInterop.HWND_TOP : NativeInterop.HWND_TOPMOST,
            x,
            y,
            placement.Width,
            placement.Height,
            NativeInterop.SWP_NOACTIVATE | NativeInterop.SWP_SHOWWINDOW);
    }

    private void ApplyCompositionBackground()
    {
        if (_source?.CompositionTarget == null)
        {
            return;
        }

        var color = Colors.Transparent;
        if (Application.Current?.Resources["SurfaceColor"] is Color surfaceColor)
        {
            color = surfaceColor;
        }

        _source.CompositionTarget.BackgroundColor = color;
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

        placement = new Placement(
            relativeX,
            relativeY,
            taskbarRect.Left + relativeX,
            taskbarRect.Top + relativeY,
            width,
            height,
            compact);
        return true;
    }

    private static int Scale(int value, double scale)
    {
        return Math.Max(1, (int)Math.Round(value * scale, MidpointRounding.AwayFromZero));
    }

    private IntPtr GetSourceHandle()
    {
        try
        {
            var handle = _source?.Handle ?? IntPtr.Zero;
            return handle != IntPtr.Zero && NativeInterop.IsWindow(handle) ? handle : IntPtr.Zero;
        }
        catch (ObjectDisposedException)
        {
            return IntPtr.Zero;
        }
    }

    private void DestroySource()
    {
        _view?.Cleanup();
        _view = null;

        if (_source != null)
        {
            try
            {
                _source.RemoveHook(WindowHook);
            }
            catch (InvalidOperationException)
            {
                // Explorer may have already destroyed the child HWND.
            }

            try
            {
                _source.Dispose();
            }
            catch (ObjectDisposedException)
            {
                // The source was disposed as part of taskbar recreation.
            }
            _source = null;
        }

        _taskbarHandle = IntPtr.Zero;
        _isEmbedded = false;
    }

    private readonly struct Placement
    {
        public Placement(
            int relativeX,
            int relativeY,
            int screenX,
            int screenY,
            int width,
            int height,
            bool compact)
        {
            RelativeX = relativeX;
            RelativeY = relativeY;
            ScreenX = screenX;
            ScreenY = screenY;
            Width = width;
            Height = height;
            Compact = compact;
        }

        public int RelativeX { get; }
        public int RelativeY { get; }
        public int ScreenX { get; }
        public int ScreenY { get; }
        public int Width { get; }
        public int Height { get; }
        public bool Compact { get; }
    }
}
