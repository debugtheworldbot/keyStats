using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
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
    private int _lastHookCallbackTick;
    private int _isReinstallingHooks;
    private NativeInterop.POINT _lastCursorPos;
    private const int WatchdogIntervalMs = 3000;
    private const int HookDeadThresholdMs = 5000;
    private const int HookInstallReadyTimeoutMs = 5000;
    private const int HookThreadStopTimeoutMs = 2000;
    private const int HookReinstallRetryCount = 3;
    private const int HookReinstallRetryDelayMs = 750;

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
        ResetTransientState();

        _lastHookCallbackTick = Environment.TickCount;
        StartHookThread();

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

        if (!TryStopHookThread())
        {
            throw new InvalidOperationException("Existing hook thread did not stop within the timeout.");
        }

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

        _lastHookCallbackTick = Environment.TickCount;
        StartHookThread();
        ResetTransientState();
        Debug.WriteLine("Watchdog: hooks reinstalled");
    }

    private void StartHookThread()
    {
        var hookStartup = new TaskCompletionSource<Exception?>(TaskCreationOptions.RunContinuationsAsynchronously);

        _hookThread = new Thread(() =>
        {
            try
            {
                _hookThreadId = NativeInterop.GetCurrentThreadId();
                InstallHooks();
                hookStartup.TrySetResult(null);

                while (NativeInterop.GetMessage(out var msg, IntPtr.Zero, 0, 0) > 0)
                {
                    NativeInterop.TranslateMessage(ref msg);
                    NativeInterop.DispatchMessage(ref msg);
                }
            }
            catch (Exception ex)
            {
                hookStartup.TrySetResult(ex);
            }
        });
        _hookThread.IsBackground = true;
        _hookThread.Name = "InputHookThread";
        _hookThread.Start();

        if (!hookStartup.Task.Wait(HookInstallReadyTimeoutMs))
        {
            if (!TryStopHookThread())
            {
                throw new TimeoutException($"Timed out waiting {HookInstallReadyTimeoutMs}ms for hook installation, and the hook thread did not stop within {HookThreadStopTimeoutMs}ms.");
            }

            throw new TimeoutException($"Timed out waiting {HookInstallReadyTimeoutMs}ms for hook installation.");
        }

        var hookError = hookStartup.Task.Result;
        if (hookError != null)
        {
            if (!TryStopHookThread())
            {
                throw new InvalidOperationException($"Hook installation failed and the hook thread did not stop within {HookThreadStopTimeoutMs}ms.", hookError);
            }

            throw hookError;
        }
    }

    private void WatchdogCallback(object? state)
    {
        if (!_isMonitoring) return;

        NativeInterop.GetCursorPos(out var currentPos);
        var cursorMoved = currentPos.x != _lastCursorPos.x || currentPos.y != _lastCursorPos.y;
        _lastCursorPos = currentPos;
        var keyboardActivity = HasRecentKeyboardActivity();

        if (!cursorMoved && !keyboardActivity) return;

        // 光标在移动，但 hook 回调长时间未被触发 → hook 可能已被 Windows 静默移除
        var elapsed = unchecked((uint)(Environment.TickCount - Volatile.Read(ref _lastHookCallbackTick)));
        if (elapsed > HookDeadThresholdMs)
        {
            if (Interlocked.CompareExchange(ref _isReinstallingHooks, 1, 0) != 0)
            {
                return;
            }

            Debug.WriteLine($"Watchdog: hook appears dead (no callback for {elapsed}ms), reinstalling...");
            try
            {
                RetryHookRecovery("watchdog");
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"Watchdog: recovery failed after retries. {ex.Message}");
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
        if (!TryStopHookThread())
        {
            Debug.WriteLine("Failed to stop the hook thread within the timeout. Continuing shutdown cleanup.");
        }

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

        ResetTransientState();

        _isMonitoring = false;
        Debug.WriteLine("Input monitoring stopped");
    }

    private IntPtr KeyboardHookCallback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0)
        {
            Interlocked.Exchange(ref _lastHookCallbackTick, Environment.TickCount);

            var message = (int)wParam;
            var hookStruct = Marshal.PtrToStructure<NativeInterop.KBDLLHOOKSTRUCT>(lParam);
            var vkCode = (int)hookStruct.vkCode;

            if (message == NativeInterop.WM_KEYDOWN || message == NativeInterop.WM_SYSKEYDOWN)
            {
                bool isNewKey;
                lock (_pressedKeys)
                {
                    isNewKey = _pressedKeys.Add(vkCode);
                }

                if (isNewKey)
                {
                    var keyName = KeyNameMapper.GetKeyName(vkCode);
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
                lock (_pressedKeys)
                {
                    _pressedKeys.Remove(vkCode);
                }
            }
        }

        return NativeInterop.CallNextHookEx(_keyboardHookId, nCode, wParam, lParam);
    }

    private IntPtr MouseHookCallback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0)
        {
            Interlocked.Exchange(ref _lastHookCallbackTick, Environment.TickCount);

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

    public void HandleSystemResume()
    {
        if (!_isMonitoring)
        {
            StartMonitoring();
            return;
        }

        if (Interlocked.CompareExchange(ref _isReinstallingHooks, 1, 0) != 0)
        {
            return;
        }

        try
        {
            Debug.WriteLine("Handling system resume: refreshing hooks and transient state.");
            RetryHookRecovery("resume");
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"Resume recovery failed after retries. {ex.Message}");
        }
        finally
        {
            Volatile.Write(ref _isReinstallingHooks, 0);
        }
    }

    private void RestartMonitoring()
    {
        StopMonitoring();
        StartMonitoring();
    }

    private void RetryHookRecovery(string reason)
    {
        Exception? lastError = null;

        for (var attempt = 1; attempt <= HookReinstallRetryCount; attempt++)
        {
            try
            {
                Debug.WriteLine($"Hook recovery attempt {attempt}/{HookReinstallRetryCount} ({reason}).");
                ReinstallHooks();
                return;
            }
            catch (Exception ex)
            {
                lastError = ex;
                Debug.WriteLine($"Hook recovery attempt {attempt} failed: {ex.Message}");
                if (attempt < HookReinstallRetryCount)
                {
                    Thread.Sleep(HookReinstallRetryDelayMs);
                }
            }
        }

        Debug.WriteLine("Hook reinstall retries exhausted, restarting monitoring.");
        RestartMonitoring();

        if (!_isMonitoring)
        {
            throw lastError ?? new InvalidOperationException("Hook recovery failed and monitoring did not restart.");
        }
    }

    private bool HasRecentKeyboardActivity()
    {
        for (var vk = 0x08; vk <= 0xFE; vk++)
        {
            var state = NativeInterop.GetAsyncKeyState(vk);
            if ((state & 0x0001) != 0 || (state & 0x8000) != 0)
            {
                return true;
            }
        }

        return false;
    }

    private bool TryStopHookThread()
    {
        var thread = _hookThread;
        var threadId = _hookThreadId;
        if (thread == null && threadId == 0)
        {
            return true;
        }

        if (threadId != 0)
        {
            NativeInterop.PostThreadMessage(threadId, NativeInterop.WM_QUIT, IntPtr.Zero, IntPtr.Zero);
        }

        if (thread == null)
        {
            Debug.WriteLine("Hook thread reference is missing while thread id is still set; keeping thread state for a later retry.");
            return false;
        }

        if (thread != null && !thread.Join(HookThreadStopTimeoutMs))
        {
            Debug.WriteLine($"Hook thread did not exit within {HookThreadStopTimeoutMs}ms.");
            return false;
        }

        _hookThread = null;
        _hookThreadId = 0;
        return true;
    }

    private void ResetTransientState()
    {
        lock (_pressedKeys)
        {
            _pressedKeys.Clear();
        }

        _lastMousePosition = null;
        _accumulatedDistance = 0.0;
        _lastMouseSampleTime = DateTime.MinValue;
    }

    public void Dispose()
    {
        StopMonitoring();
        _instance = null;
    }
}
