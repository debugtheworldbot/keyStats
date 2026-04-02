using System;
using System.Globalization;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Threading;
using KeyStats.Helpers;
using KeyStats.Services;

namespace KeyStats.Views;

public partial class MouseCalibrationWindow : Window
{
    private bool _isMeasuring;
    private System.Drawing.Point? _startPoint;
    private bool _isInitializing;
    private readonly DispatcherTimer _liveTimer;
    private double _lastLiveDistance;

    public MouseCalibrationWindow()
    {
        InitializeComponent();
        _isInitializing = true;
        LengthTextBox.Text = "10";
        LoadSettings();
        _isInitializing = false;
        Loaded += (_, _) => Keyboard.Focus(this);

        _liveTimer = new DispatcherTimer
        {
            Interval = TimeSpan.FromMilliseconds(33)
        };
        _liveTimer.Tick += (_, _) => UpdateLiveDistance();
        Loaded += OnLoaded;
        Closed += OnClosed;
        ThemeManager.Instance.ThemeChanged += OnThemeChanged;
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        ApplyWindowTitleBarTheme();
        App.CurrentApp?.TrackPageView("mouse_calibration");
    }

    private void OnClosed(object? sender, EventArgs e)
    {
        ThemeManager.Instance.ThemeChanged -= OnThemeChanged;
    }

    private void OnThemeChanged()
    {
        Dispatcher.BeginInvoke(new Action(ApplyWindowTitleBarTheme));
    }

    private void ApplyWindowTitleBarTheme()
    {
        var handle = new WindowInteropHelper(this).Handle;
        NativeInterop.TrySetImmersiveDarkMode(handle, ThemeManager.Instance.IsDarkTheme);
    }

    private void LoadSettings()
    {
        var settings = StatsManager.Instance.Settings;
        UpdateScaleText(settings.MouseMetersPerPixel);
        UpdatePixelsText(null);

        var unit = settings.MouseDistanceUnit;
        UnitComboBox.SelectedIndex = string.Equals(unit, "px", StringComparison.OrdinalIgnoreCase) ? 1 : 0;
    }

    private void StartButton_Click(object sender, RoutedEventArgs e)
    {
        _startPoint = GetCursorPosition();
        _isMeasuring = true;
        StatusText.Text = "已开始，移动标尺长度后按回车结束";
        StartButton.IsEnabled = false;
        FinishButton.IsEnabled = true;
        _lastLiveDistance = 0;
        UpdatePixelsText(0);
        StartLiveUpdate();
    }

    private void FinishButton_Click(object sender, RoutedEventArgs e)
    {
        if (!_isMeasuring || !_startPoint.HasValue)
        {
            StatusText.Text = "请先按回车开始";
            return;
        }

        var endPoint = GetCursorPosition();
        var dx = endPoint.X - _startPoint.Value.X;
        var dy = endPoint.Y - _startPoint.Value.Y;
        var distance = Math.Sqrt(dx * dx + dy * dy);

        if (distance < 10)
        {
            StatusText.Text = "移动距离过短，请重新校准";
            ResetMeasureState();
            return;
        }

        if (!TryGetLengthCm(out var lengthCm) || lengthCm <= 0)
        {
            StatusText.Text = "标尺长度无效";
            ResetMeasureState();
            return;
        }

        var metersPerPixel = (lengthCm / 100.0) / distance;
        StatsManager.Instance.UpdateMouseCalibration(metersPerPixel);

        UpdatePixelsText(distance);
        UpdateScaleText(metersPerPixel);

        StatusText.Text = "校准完成";
        ResetMeasureState();
    }

    private void Window_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Enter)
        {
            return;
        }

        e.Handled = true;

        if (_isMeasuring)
        {
            FinishButton_Click(this, new RoutedEventArgs());
        }
        else
        {
            StartButton_Click(this, new RoutedEventArgs());
        }
    }

    private void UnitComboBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_isInitializing) return;
        if (UnitComboBox.SelectedItem is ComboBoxItem item && item.Tag is string tag)
        {
            StatsManager.Instance.UpdateMouseDistanceUnit(tag);
        }
    }

    private void NumericOnly_PreviewTextInput(object sender, TextCompositionEventArgs e)
    {
        e.Handled = !Regex.IsMatch(e.Text, "^[0-9.]$");
    }

    private bool TryGetLengthCm(out double lengthCm)
    {
        var text = LengthTextBox.Text?.Trim() ?? string.Empty;
        if (double.TryParse(text, NumberStyles.Float, CultureInfo.CurrentCulture, out lengthCm))
        {
            return true;
        }
        return double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out lengthCm);
    }

    private static System.Drawing.Point GetCursorPosition()
    {
        return System.Windows.Forms.Control.MousePosition;
    }

    private void UpdatePixelsText(double? distance)
    {
        PixelsText.Text = distance.HasValue ? $"像素距离: {distance.Value:F0} px" : "像素距离: --";
    }

    private void UpdateScaleText(double metersPerPixel)
    {
        if (double.IsNaN(metersPerPixel) || double.IsInfinity(metersPerPixel) || metersPerPixel <= 0)
        {
            ScaleText.Text = "换算系数: --";
            return;
        }
        ScaleText.Text = $"换算系数: {metersPerPixel:E4} m/px";
    }

    private void ResetMeasureState()
    {
        StopLiveUpdate();
        _isMeasuring = false;
        _startPoint = null;
        StartButton.IsEnabled = true;
        FinishButton.IsEnabled = false;
        StatusText.Text = "未开始，按回车开始";
    }

    private void StartLiveUpdate()
    {
        if (!_liveTimer.IsEnabled)
        {
            _liveTimer.Start();
        }
    }

    private void StopLiveUpdate()
    {
        if (_liveTimer.IsEnabled)
        {
            _liveTimer.Stop();
        }
    }

    private void UpdateLiveDistance()
    {
        if (!_isMeasuring || !_startPoint.HasValue)
        {
            return;
        }

        var current = GetCursorPosition();
        var dx = current.X - _startPoint.Value.X;
        var dy = current.Y - _startPoint.Value.Y;
        var distance = Math.Sqrt(dx * dx + dy * dy);

        if (Math.Abs(distance - _lastLiveDistance) < 0.5)
        {
            return;
        }

        _lastLiveDistance = distance;
        UpdatePixelsText(distance);
    }
}
