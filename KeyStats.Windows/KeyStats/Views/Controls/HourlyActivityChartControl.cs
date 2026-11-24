using System;
using System.Globalization;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using KeyStats.Helpers;

namespace KeyStats.Views.Controls;

/// <summary>
/// 24 小时活跃度柱状图：柱色按相对高度跟随热力图配色，最高的柱顶标数值。
/// </summary>
public class HourlyActivityChartControl : FrameworkElement
{
    private const int Hours = 24;
    private const double ChartHeight = 200;
    private const double TopLabelSpace = 18;
    private const double AxisLabelSpace = 20;
    private const double BarGapRatio = 0.28;

    private double[] _values = new double[Hours];
    private int _peakHour = -1;
    private readonly ToolTip _toolTip;

    public HourlyActivityChartControl()
    {
        SnapsToDevicePixels = true;
        UseLayoutRounding = true;
        _toolTip = new ToolTip { PlacementTarget = this, Placement = PlacementMode.Relative };
        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
    }

    /// <summary>悬停提示文案：参数为小时与该小时的值。</summary>
    public Func<int, double, string>? TooltipFormatter { get; set; }

    public void Apply(double[] values, int peakHour)
    {
        _values = values.Length == Hours ? values.ToArray() : new double[Hours];
        _peakHour = peakHour;
        InvalidateVisual();
    }

    protected override Size MeasureOverride(Size availableSize)
    {
        var width = double.IsInfinity(availableSize.Width) ? 800 : availableSize.Width;
        return new Size(width, ChartHeight + TopLabelSpace + AxisLabelSpace);
    }

    private double SlotWidth => ActualWidth / Hours;

    protected override void OnRender(DrawingContext drawingContext)
    {
        base.OnRender(drawingContext);
        if (ActualWidth <= 0)
        {
            return;
        }

        var isDarkMode = ThemeManager.Instance.IsDarkTheme;
        var labelBrush = Freeze(new SolidColorBrush(HeatmapPalette.ResolveColor("TextSecondaryBrush", Colors.Gray)));
        var valueBrush = Freeze(new SolidColorBrush(HeatmapPalette.ResolveColor("TextPrimaryBrush", Colors.Black)));
        var gridPen = new Pen(Freeze(new SolidColorBrush(isDarkMode
            ? Color.FromArgb(30, 255, 255, 255)
            : Color.FromArgb(22, 0, 0, 0))), 1);
        gridPen.Freeze();

        var baseline = TopLabelSpace + ChartHeight;
        drawingContext.DrawLine(gridPen, new Point(0, baseline), new Point(ActualWidth, baseline));

        var max = _values.Max();
        var slot = SlotWidth;
        var barWidth = slot * (1 - BarGapRatio);
        var radius = Math.Min(4, barWidth / 3);

        for (var hour = 0; hour < Hours; hour++)
        {
            var value = _values[hour];
            var x = hour * slot + (slot - barWidth) / 2;
            var ratio = max > 0 ? value / max : 0;
            var height = value > 0 ? Math.Max(3, ratio * ChartHeight) : 2;
            var color = value > 0
                ? HeatmapPalette.ColorFor(Math.Max(0.15, ratio), isDarkMode)
                : HeatmapPalette.NeutralColor(isDarkMode);
            var rect = new Rect(x, baseline - height, barWidth, height);
            drawingContext.DrawRoundedRectangle(Freeze(new SolidColorBrush(color)), null, rect, radius, radius);

            if (hour % 3 == 0)
            {
                var label = CreateText(hour.ToString(CultureInfo.InvariantCulture), 10, labelBrush, FontWeights.Normal);
                drawingContext.DrawText(label, new Point(hour * slot + (slot - label.Width) / 2, baseline + 4));
            }

            if (hour == _peakHour && value > 0)
            {
                var peakText = CreateText(Math.Round(value).ToString("N0", CultureInfo.CurrentCulture), 11, valueBrush, FontWeights.SemiBold);
                var textX = Math.Max(0, Math.Min(ActualWidth - peakText.Width, x + (barWidth - peakText.Width) / 2));
                drawingContext.DrawText(peakText, new Point(textX, rect.Top - peakText.Height - 2));
            }
        }
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        var position = e.GetPosition(this);
        var hour = (int)(position.X / Math.Max(1, SlotWidth));
        if (TooltipFormatter == null || hour < 0 || hour >= Hours || position.Y > TopLabelSpace + ChartHeight)
        {
            _toolTip.IsOpen = false;
            return;
        }

        _toolTip.Content = TooltipFormatter(hour, _values[hour]);
        _toolTip.HorizontalOffset = position.X + 12;
        _toolTip.VerticalOffset = position.Y + 16;
        _toolTip.IsOpen = true;
    }

    protected override void OnMouseLeave(MouseEventArgs e)
    {
        base.OnMouseLeave(e);
        _toolTip.IsOpen = false;
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        ThemeManager.Instance.ThemeChanged += OnPaletteChanged;
        HeatmapPalette.SchemeChanged += OnPaletteChanged;
    }

    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        ThemeManager.Instance.ThemeChanged -= OnPaletteChanged;
        HeatmapPalette.SchemeChanged -= OnPaletteChanged;
        _toolTip.IsOpen = false;
    }

    private void OnPaletteChanged()
    {
        Dispatcher.BeginInvoke(new Action(InvalidateVisual));
    }

    private FormattedText CreateText(string value, double fontSize, Brush brush, FontWeight weight)
    {
        return new FormattedText(
            value,
            CultureInfo.CurrentUICulture,
            FlowDirection.LeftToRight,
            new Typeface(new FontFamily("Segoe UI"), FontStyles.Normal, weight, FontStretches.Normal),
            fontSize,
            brush,
            VisualTreeHelper.GetDpi(this).PixelsPerDip);
    }

    private static T Freeze<T>(T freezable) where T : Freezable
    {
        freezable.Freeze();
        return freezable;
    }
}
