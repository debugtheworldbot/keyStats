using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
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
    private readonly HashSet<int> _pressedKeys = new(); // 跟踪当前按下的键，防止长按时重复计数
    private readonly double _mouseSampleInterval = 1.0 / 30.0; // 30 FPS
    private DateTime _lastMouseSampleTime = DateTime.MinValue;
    private System.Drawing.Point? _lastMousePosition;
    private double _accumulatedDistance = 0.0;

    // 专用 hook 线程，避免 UI 线程卡顿导致 hook 超时
    private Thread? _hookThread;
    private uint _hookThreadId;

    // hook 健康检查：watchdog 定时检测 hook 是否被 Windows 静默移除
    private Timer? _watchdogTimer;
    private int _lastMouseHookTick;
    private int _isReinstallingHooks;
    private NativeInterop.POINT _lastCursorPos;
    private const int WatchdogIntervalMs = 3000;
    private const int HookDeadThresholdMs = 5000;

    public event Action<string, string, string>? KeyPressed;
    public event Action<string, string>? LeftMouseClicked;
    public event Action<string, string>? RightMouseClicked;
    public event Action<string, string>? MiddleMouseClicked;
    public event Action<string, string>? SideBackMouseClicked;
    public event Action<string, string>? SideForwardMouseClicked;
    public event Action<double>? MouseMoved;
    public event Action<double, string, string>? MouseScrolled;

    private InputMonitorService() { }

    public void StartMonitoring()
    {
        if (_isMonitoring) return;

        _keyboardProc = KeyboardHookCallback;
        _mouseProc = MouseHookCallback;

        _lastMouseHookTick = Environment.TickCount;

        // 在专用线程上安装 hook 并运行消息循环，使 hook 回调不受 UI 线程阻塞影响
        var readyEvent = new ManualResetEventSlim(false);
        Exception? hookError = null;

        _hookThread = new Thread(() =>
        {
            try
            {
                _hookThreadId = NativeInterop.GetCurrentThreadId();
                InstallHooks();
                readyEvent.Set();

                // 低级钩子需要消息循环来分发回调
                while (NativeInterop.GetMessage(out var msg, IntPtr.Zero, 0, 0) > 0)
                {
                    NativeInterop.TranslateMessage(ref msg);
                    NativeInterop.DispatchMessage(ref msg);
                }
            }
            catch (Exception ex)
            {
                hookError = ex;
                readyEvent.Set();
            }
        });
        _hookThread.IsBackground = true;
        _hookThread.Name = "InputHookThread";
        _hookThread.Start();

        readyEvent.Wait();
        if (hookError != null)
        {
            throw hookError;
        }

        _isMonitoring = true;

        // 启动 watchdog 定时检测 hook 是否存活
        _watchdogTimer = new Timer(WatchdogCallback, null, WatchdogIntervalMs, WatchdogIntervalMs);

        Debug.WriteLine("Input monitoring started successfully (dedicated hook thread)");
    }

    private void InstallHooks()
    {
        var moduleHandle = NativeInterop.GetModuleHandle(null);

        _keyboardHookId = NativeInterop.SetWindowsHookEx(
            NativeInterop.WH_KEYBOARD_LL,
            _keyboardProc!,
            moduleHandle,
            0);

        if (_keyboardHookId == IntPtr.Zero)
        {
            var error = Marshal.GetLastWin32Error();
            Debug.WriteLine($"Failed to install keyboard hook. Error code: {error}");
            throw new System.ComponentModel.Win32Exception(error, "Failed to install keyboard hook");
        }

        _mouseHookId = NativeInterop.SetWindowsHookEx(
            NativeInterop.WH_MOUSE_LL,
            _mouseProc!,
            moduleHandle,
            0);

        if (_mouseHookId == IntPtr.Zero)
        {
            var error = Marshal.GetLastWin32Error();
            Debug.WriteLine($"Failed to install mouse hook. Error code: {error}");
            if (_keyboardHookId != IntPtr.Zero)
            {
                NativeInterop.UnhookWindowsHookEx(_keyboardHookId);
                _keyboardHookId = IntPtr.Zero;
            }
            throw new System.ComponentModel.Win32Exception(error, "Failed to install mouse hook");
        }
    }

    private void ReinstallHooks()
    {
        Debug.WriteLine("Watchdog: reinstalling hooks...");

        // 在 hook 线程上卸载旧 hook 并重新安装
        if (_hookThreadId != 0)
        {
            // 终止旧的消息循环
            NativeInterop.PostThreadMessage(_hookThreadId, NativeInterop.WM_QUIT, IntPtr.Zero, IntPtr.Zero);
        }

        _hookThread?.Join(2000);

        // 清理可能残留的 hook handle
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

        _lastMouseHookTick = Environment.TickCount;

        var readyEvent = new ManualResetEventSlim(false);

        _hookThread = new Thread(() =>
        {
            try
            {
                _hookThreadId = NativeInterop.GetCurrentThreadId();
                InstallHooks();
                readyEvent.Set();

                while (NativeInterop.GetMessage(out var msg, IntPtr.Zero, 0, 0) > 0)
                {
                    NativeInterop.TranslateMessage(ref msg);
                    NativeInterop.DispatchMessage(ref msg);
                }
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"Watchdog: hook reinstall failed: {ex.Message}");
                readyEvent.Set();
            }
        });
        _hookThread.IsBackground = true;
        _hookThread.Name = "InputHookThread";
        _hookThread.Start();

        readyEvent.Wait();
        Debug.WriteLine("Watchdog: hooks reinstalled");
    }

    private void WatchdogCallback(object? state)
    {
        if (!_isMonitoring) return;

        NativeInterop.GetCursorPos(out var currentPos);
        var cursorMoved = currentPos.x != _lastCursorPos.x || currentPos.y != _lastCursorPos.y;
        _lastCursorPos = currentPos;

        if (!cursorMoved) return;

        // 光标在移动，但 hook 回调长时间未被触发 → hook 可能已被 Windows 静默移除
        var elapsed = unchecked((uint)(Environment.TickCount - Volatile.Read(ref _lastMouseHookTick)));
        if (elapsed > HookDeadThresholdMs)
        {
            if (Interlocked.CompareExchange(ref _isReinstallingHooks, 1, 0) != 0)
            {
                return;
            }

            Debug.WriteLine($"Watchdog: mouse hook appears dead (no callback for {elapsed}ms), reinstalling...");
            try
            {
                ReinstallHooks();
            }
            finally
            {
                Volatile.Write(ref _isReinstallingHooks, 0);
            }
        }
    }

    public void StopMonitoring()
    {
        if (!_isMonitoring) return;

        _watchdogTimer?.Dispose();
        _watchdogTimer = null;

        // 终止 hook 线程的消息循环
        if (_hookThreadId != 0)
        {
            NativeInterop.PostThreadMessage(_hookThreadId, NativeInterop.WM_QUIT, IntPtr.Zero, IntPtr.Zero);
        }

        _hookThread?.Join(2000);

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

        _pressedKeys.Clear();

        _isMonitoring = false;
        Debug.WriteLine("Input monitoring stopped");
    }

    private IntPtr KeyboardHookCallback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0)
        {
            var message = (int)wParam;
            var hookStruct = Marshal.PtrToStructure<NativeInterop.KBDLLHOOKSTRUCT>(lParam);
            var vkCode = (int)hookStruct.vkCode;

            if (message == NativeInterop.WM_KEYDOWN || message == NativeInterop.WM_SYSKEYDOWN)
            {
                if (!_pressedKeys.Contains(vkCode))
                {
                    _pressedKeys.Add(vkCode);
                    // GetKeyName 需在 hook 回调中同步调用以准确获取修饰键状态
                    var keyName = KeyNameMapper.GetKeyName(vkCode);
                    // 捕获前台窗口句柄和进程 ID（轻量 P/Invoke），完整解析异步进行
                    var hWnd = NativeInterop.GetForegroundWindow();
                    NativeInterop.GetWindowThreadProcessId(hWnd, out uint pid);
                    ThreadPool.QueueUserWorkItem(_ =>
                    {
                        var activeApp = ActiveWindowManager.ResolveAppInfo(hWnd, pid);
                        KeyPressed?.Invoke(keyName, activeApp.AppName, activeApp.DisplayName);
                    });
                }
            }
            else if (message == NativeInterop.WM_KEYUP || message == NativeInterop.WM_SYSKEYUP)
            {
                _pressedKeys.Remove(vkCode);
            }
        }

        return NativeInterop.CallNextHookEx(_keyboardHookId, nCode, wParam, lParam);
    }

    private IntPtr MouseHookCallback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0)
        {
            Interlocked.Exchange(ref _lastMouseHookTick, Environment.TickCount);

            var message = (int)wParam;
            var hookStruct = Marshal.PtrToStructure<NativeInterop.MSLLHOOKSTRUCT>(lParam);

            switch (message)
            {
                case NativeInterop.WM_LBUTTONDOWN:
                case NativeInterop.WM_RBUTTONDOWN:
                case NativeInterop.WM_MBUTTONDOWN:
                    {
                        var msg = message;
                        var hWnd = NativeInterop.GetForegroundWindow();
                        NativeInterop.GetWindowThreadProcessId(hWnd, out uint pid);
                        ThreadPool.QueueUserWorkItem(_ =>
                        {
                            var activeApp = ActiveWindowManager.ResolveAppInfo(hWnd, pid);
                            var appName = activeApp.AppName;
                            var displayName = activeApp.DisplayName;
                            if (msg == NativeInterop.WM_LBUTTONDOWN)
                                LeftMouseClicked?.Invoke(appName, displayName);
                            else if (msg == NativeInterop.WM_RBUTTONDOWN)
                                RightMouseClicked?.Invoke(appName, displayName);
                            else
                                MiddleMouseClicked?.Invoke(appName, displayName);
                        });
                    }
                    break;

                case NativeInterop.WM_XBUTTONDOWN:
                    {
                        var mouseData = hookStruct.mouseData;
                        var hWnd = NativeInterop.GetForegroundWindow();
                        NativeInterop.GetWindowThreadProcessId(hWnd, out uint pid);
                        ThreadPool.QueueUserWorkItem(_ =>
                        {
                            var activeApp = ActiveWindowManager.ResolveAppInfo(hWnd, pid);
                            var button = NativeInterop.HiWord((int)mouseData);
                            if (button == NativeInterop.XBUTTON2)
                                SideForwardMouseClicked?.Invoke(activeApp.AppName, activeApp.DisplayName);
                            else
                                SideBackMouseClicked?.Invoke(activeApp.AppName, activeApp.DisplayName);
                        });
                    }
                    break;

                case NativeInterop.WM_MOUSEMOVE:
                    HandleMouseMove(hookStruct.pt);
                    break;

                case NativeInterop.WM_MOUSEWHEEL:
                case NativeInterop.WM_MOUSEHWHEEL:
                    {
                        var mouseData = hookStruct.mouseData;
                        var hWnd = NativeInterop.GetForegroundWindow();
                        NativeInterop.GetWindowThreadProcessId(hWnd, out uint pid);
                        ThreadPool.QueueUserWorkItem(_ =>
                        {
                            var activeApp = ActiveWindowManager.ResolveAppInfo(hWnd, pid);
                            HandleScroll(mouseData, activeApp.AppName, activeApp.DisplayName);
                        });
                    }
                    break;
            }
        }

        return NativeInterop.CallNextHookEx(_mouseHookId, nCode, wParam, lParam);
    }

    private void HandleMouseMove(NativeInterop.POINT pt)
    {
        var currentPosition = new System.Drawing.Point(pt.x, pt.y);

        if (!_lastMousePosition.HasValue)
        {
            _lastMousePosition = currentPosition;
            _lastMouseSampleTime = DateTime.MinValue;
            return;
        }

        var dx = currentPosition.X - _lastMousePosition.Value.X;
        var dy = currentPosition.Y - _lastMousePosition.Value.Y;
        var segmentDistance = Math.Sqrt(dx * dx + dy * dy);

        const double maxSegmentDistance = 250.0;
        if (segmentDistance > maxSegmentDistance)
        {
            _accumulatedDistance = 0.0;
            _lastMousePosition = currentPosition;
            _lastMouseSampleTime = DateTime.Now;
            return;
        }

        _accumulatedDistance += segmentDistance;
        _lastMousePosition = currentPosition;

        var elapsed = (DateTime.Now - _lastMouseSampleTime).TotalSeconds;
        if (elapsed < _mouseSampleInterval)
        {
            return;
        }

        var reportedDistance = _accumulatedDistance;
        _accumulatedDistance = 0.0;
        _lastMouseSampleTime = DateTime.Now;

        if (reportedDistance <= 0)
        {
            return;
        }

        var distance = reportedDistance;
        ThreadPool.QueueUserWorkItem(_ => MouseMoved?.Invoke(distance));
    }

    private void HandleScroll(uint mouseData, string appName, string displayName)
    {
        var delta = NativeInterop.HiWord((int)mouseData);
        var scrollDistance = Math.Abs(delta) / 120.0;
        MouseScrolled?.Invoke(scrollDistance, appName, displayName);
    }

    public void ResetLastMousePosition()
    {
        _lastMousePosition = null;
        _accumulatedDistance = 0.0;
    }

    public void Dispose()
    {
        StopMonitoring();
        _instance = null;
    }
}
