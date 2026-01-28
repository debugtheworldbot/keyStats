using System;
using System.Collections.Generic;
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
    private readonly HashSet<int> _pressedKeys = new(); // 跟踪当前按下的键，防止长按时重复计数
    private readonly double _mouseSampleInterval = 1.0 / 30.0; // 30 FPS
    private DateTime _lastMouseSampleTime = DateTime.MinValue;
    private System.Drawing.Point? _lastMousePosition;
    private System.Drawing.Point? _lastSampledPosition;
    private double _accumulatedDistance = 0.0;

    public event Action<string, string>? KeyPressed;
    public event Action<string>? LeftMouseClicked;
    public event Action<string>? RightMouseClicked;
    public event Action<double>? MouseMoved;
    public event Action<double, string>? MouseScrolled;

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

            if (_keyboardHookId == IntPtr.Zero)
            {
                var error = Marshal.GetLastWin32Error();
                Debug.WriteLine($"Failed to install keyboard hook. Error code: {error}");
                throw new System.ComponentModel.Win32Exception(error, "Failed to install keyboard hook");
            }

            _mouseHookId = NativeInterop.SetWindowsHookEx(
                NativeInterop.WH_MOUSE_LL,
                _mouseProc,
                moduleHandle,
                0);

            if (_mouseHookId == IntPtr.Zero)
            {
                var error = Marshal.GetLastWin32Error();
                Debug.WriteLine($"Failed to install mouse hook. Error code: {error}");
                // Clean up keyboard hook before throwing
                if (_keyboardHookId != IntPtr.Zero)
                {
                    NativeInterop.UnhookWindowsHookEx(_keyboardHookId);
                    _keyboardHookId = IntPtr.Zero;
                }
                throw new System.ComponentModel.Win32Exception(error, "Failed to install mouse hook");
            }
        }

        _isMonitoring = true;
        Debug.WriteLine("Input monitoring started successfully");
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

        // 清空按下的键集合
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
                // 只在键第一次按下时记录，忽略长按时的重复按下事件
                if (!_pressedKeys.Contains(vkCode))
                {
                    _pressedKeys.Add(vkCode);
                    var keyName = KeyNameMapper.GetKeyName(vkCode);
                    var appName = ActiveWindowManager.GetActiveProcessName();
                    KeyPressed?.Invoke(keyName, appName);
                }
            }
            else if (message == NativeInterop.WM_KEYUP || message == NativeInterop.WM_SYSKEYUP)
            {
                // 键释放时，从集合中移除
                _pressedKeys.Remove(vkCode);
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
                    LeftMouseClicked?.Invoke(ActiveWindowManager.GetActiveProcessName());
                    break;

                case NativeInterop.WM_RBUTTONDOWN:
                    RightMouseClicked?.Invoke(ActiveWindowManager.GetActiveProcessName());
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
        var currentPosition = new System.Drawing.Point(pt.x, pt.y);

        // 初始化位置
        if (!_lastMousePosition.HasValue)
        {
            _lastMousePosition = currentPosition;
            _lastSampledPosition = currentPosition;
            _lastMouseSampleTime = now;
            return;
        }

        // 计算本次移动的距离
        var dx = currentPosition.X - _lastMousePosition.Value.X;
        var dy = currentPosition.Y - _lastMousePosition.Value.Y;
        var segmentDistance = Math.Sqrt(dx * dx + dy * dy);

        // 过滤异常大的单次移动（可能是鼠标跳跃或系统事件）
        // 使用更严格的阈值来过滤异常移动
        const double maxSegmentDistance = 100.0; // 更严格的阈值，过滤异常移动
        if (segmentDistance > maxSegmentDistance)
        {
            // 如果移动距离异常大，可能是鼠标跳跃或系统事件，重置状态
            _accumulatedDistance = 0.0;
            _lastSampledPosition = currentPosition;
            _lastMousePosition = currentPosition;
            _lastMouseSampleTime = now;
            return;
        }

        // 累积移动距离（用于检测异常快速移动和路径分析）
        _accumulatedDistance += segmentDistance;
        _lastMousePosition = currentPosition;

        // 检查是否到了采样时间
        var elapsed = (now - _lastMouseSampleTime).TotalSeconds;
        if (elapsed >= _mouseSampleInterval)
        {
            // 计算从上次采样点到当前点的直线距离（物理移动距离）
            if (_lastSampledPosition.HasValue)
            {
                var sampledDx = currentPosition.X - _lastSampledPosition.Value.X;
                var sampledDy = currentPosition.Y - _lastSampledPosition.Value.Y;
                var sampledDistance = Math.Sqrt(sampledDx * sampledDx + sampledDy * sampledDy);

                // 使用更智能的方法计算距离：
                // 1. 如果直线距离很小（< 10像素）但累积距离较大，说明是画圈，使用累积距离
                // 2. 如果累积距离明显大于直线距离（超过1.3倍）且直线距离较大，可能是来回移动，使用直线距离
                // 3. 否则，使用累积距离和直线距离的较小值，避免过度计算
                double reportedDistance;
                const double smallDistanceThreshold = 10.0; // 小距离阈值，用于检测画圈
                
                if (_accumulatedDistance > 0 && sampledDistance > 0)
                {
                    if (sampledDistance < smallDistanceThreshold && _accumulatedDistance > smallDistanceThreshold)
                    {
                        // 画圈情况：起点和终点接近，但实际移动距离大，使用累积距离
                        reportedDistance = _accumulatedDistance;
                    }
                    else if (_accumulatedDistance > sampledDistance * 1.3)
                    {
                        // 来回移动，使用直线距离
                        reportedDistance = sampledDistance;
                    }
                    else
                    {
                        // 正常移动，使用累积距离，但不超过直线距离的1.1倍（更保守）
                        reportedDistance = Math.Min(_accumulatedDistance, sampledDistance * 1.1);
                    }
                }
                else if (_accumulatedDistance > 0)
                {
                    // 如果只有累积距离（直线距离为0），使用累积距离
                    reportedDistance = _accumulatedDistance;
                }
                else
                {
                    reportedDistance = sampledDistance;
                }

                // 基于报告的距离计算速度（像素/秒），用于检测异常快速移动
                var speed = reportedDistance / Math.Max(elapsed, 0.001); // 避免除以0
                const double maxSpeed = 3000.0; // 最大合理速度（像素/秒）
                const double maxReportedDistance = 500.0; // 单次报告的最大距离（画圈时可能较大，提高阈值）
                
                // 过滤异常值：距离过大或速度过快
                if (reportedDistance <= maxReportedDistance && speed <= maxSpeed)
                {
                    MouseMoved?.Invoke(reportedDistance);
                }
                else
                {
                    // 如果检测到异常，重置状态
                    _accumulatedDistance = 0.0;
                    _lastSampledPosition = currentPosition;
                    _lastMousePosition = currentPosition;
                    _lastMouseSampleTime = now;
                    return;
                }

                // 重置累积距离
                _accumulatedDistance = 0.0;
                _lastSampledPosition = currentPosition;
            }
            else
            {
                _lastSampledPosition = currentPosition;
            }

            _lastMouseSampleTime = now;
        }
    }

    private void HandleScroll(uint mouseData)
    {
        // mouseData contains the scroll delta in the high-order word
        // WHEEL_DELTA is 120, so divide by 120 to get wheel ticks
        var delta = NativeInterop.HiWord((int)mouseData);
        var scrollDistance = Math.Abs(delta) / 120.0;
        MouseScrolled?.Invoke(scrollDistance, ActiveWindowManager.GetActiveProcessName());
    }

    public void ResetLastMousePosition()
    {
        _lastMousePosition = null;
        _lastSampledPosition = null;
        _accumulatedDistance = 0.0;
    }

    public void Dispose()
    {
        StopMonitoring();
        _instance = null;
    }
}
