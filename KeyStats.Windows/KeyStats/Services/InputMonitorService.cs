using System.Diagnostics;
using System.Runtime.InteropServices;
using KeyStats.Helpers;

namespace KeyStats.Services;

public class InputMonitorService : IDisposable
{
    private static InputMonitorService? _instance;
    public static InputMonitorService Instance => _instance ??= new InputMonitorService();

    private IntPtr _keyboardHookId = IntPtr.Zero;
    private IntPtr _mouseHookId = IntPtr.Zero;
    private NativeInterop.LowLevelKeyboardProc? _keyboardProc;
    private NativeInterop.LowLevelMouseProc? _mouseProc;

    private bool _isMonitoring;
    private readonly double _mouseSampleInterval = 1.0 / 30.0; // 30 FPS
    private DateTime _lastMouseSampleTime = DateTime.MinValue;
    private System.Drawing.Point? _lastMousePosition;

    public event Action<string>? KeyPressed;
    public event Action? LeftMouseClicked;
    public event Action? RightMouseClicked;
    public event Action<double>? MouseMoved;
    public event Action<double>? MouseScrolled;

    private InputMonitorService() { }

    public void StartMonitoring()
    {
        if (_isMonitoring) return;

        _keyboardProc = KeyboardHookCallback;
        _mouseProc = MouseHookCallback;

        using var curProcess = Process.GetCurrentProcess();
        using var curModule = curProcess.MainModule;

        if (curModule != null)
        {
            var moduleHandle = NativeInterop.GetModuleHandle(curModule.ModuleName);
            _keyboardHookId = NativeInterop.SetWindowsHookEx(
                NativeInterop.WH_KEYBOARD_LL,
                _keyboardProc,
                moduleHandle,
                0);

            _mouseHookId = NativeInterop.SetWindowsHookEx(
                NativeInterop.WH_MOUSE_LL,
                _mouseProc,
                moduleHandle,
                0);
        }

        _isMonitoring = true;
        Debug.WriteLine("Input monitoring started");
    }

    public void StopMonitoring()
    {
        if (!_isMonitoring) return;

        if (_keyboardHookId != IntPtr.Zero)
        {
            NativeInterop.UnhookWindowsHookEx(_keyboardHookId);
            _keyboardHookId = IntPtr.Zero;
        }

        if (_mouseHookId != IntPtr.Zero)
        {
            NativeInterop.UnhookWindowsHookEx(_mouseHookId);
            _mouseHookId = IntPtr.Zero;
        }

        _isMonitoring = false;
        Debug.WriteLine("Input monitoring stopped");
    }

    private IntPtr KeyboardHookCallback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0)
        {
            var message = (int)wParam;
            if (message == NativeInterop.WM_KEYDOWN || message == NativeInterop.WM_SYSKEYDOWN)
            {
                var hookStruct = Marshal.PtrToStructure<NativeInterop.KBDLLHOOKSTRUCT>(lParam);
                var vkCode = (int)hookStruct.vkCode;
                var keyName = KeyNameMapper.GetKeyName(vkCode);
                KeyPressed?.Invoke(keyName);
            }
        }

        return NativeInterop.CallNextHookEx(_keyboardHookId, nCode, wParam, lParam);
    }

    private IntPtr MouseHookCallback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0)
        {
            var message = (int)wParam;
            var hookStruct = Marshal.PtrToStructure<NativeInterop.MSLLHOOKSTRUCT>(lParam);

            switch (message)
            {
                case NativeInterop.WM_LBUTTONDOWN:
                    LeftMouseClicked?.Invoke();
                    break;

                case NativeInterop.WM_RBUTTONDOWN:
                    RightMouseClicked?.Invoke();
                    break;

                case NativeInterop.WM_MOUSEMOVE:
                    HandleMouseMove(hookStruct.pt);
                    break;

                case NativeInterop.WM_MOUSEWHEEL:
                case NativeInterop.WM_MOUSEHWHEEL:
                    HandleScroll(hookStruct.mouseData);
                    break;
            }
        }

        return NativeInterop.CallNextHookEx(_mouseHookId, nCode, wParam, lParam);
    }

    private void HandleMouseMove(NativeInterop.POINT pt)
    {
        var now = DateTime.Now;
        var elapsed = (now - _lastMouseSampleTime).TotalSeconds;

        if (elapsed < _mouseSampleInterval) return;

        var currentPosition = new System.Drawing.Point(pt.x, pt.y);

        if (_lastMousePosition.HasValue)
        {
            var dx = currentPosition.X - _lastMousePosition.Value.X;
            var dy = currentPosition.Y - _lastMousePosition.Value.Y;
            var distance = Math.Sqrt(dx * dx + dy * dy);

            // Filter out abnormally large distances (mouse jumps)
            if (distance < 500)
            {
                MouseMoved?.Invoke(distance);
            }
        }

        _lastMousePosition = currentPosition;
        _lastMouseSampleTime = now;
    }

    private void HandleScroll(uint mouseData)
    {
        // mouseData contains the scroll delta in the high-order word
        var delta = NativeInterop.HiWord((int)mouseData);
        var scrollDistance = Math.Abs(delta) / 120.0 * 10.0; // Normalize and scale
        MouseScrolled?.Invoke(scrollDistance);
    }

    public void ResetLastMousePosition()
    {
        _lastMousePosition = null;
    }

    public void Dispose()
    {
        StopMonitoring();
        _instance = null;
    }
}
