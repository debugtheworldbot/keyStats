using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using KeyStats.Helpers;

namespace KeyStats.Views.Controls;

public sealed class ContributionDay
{
    public ContributionDay(DateTime date, int value, bool isInRange)
    {
        Date = date;
        Value = value;
        IsInRange = isInRange;
    }

    public DateTime Date { get; }
    public int Value { get; }
    public bool IsInRange { get; }
}

/// <summary>
/// GitHub 风格的年度贡献墙：列为周、行为周一到周日，颜色跟随热力图配色。
/// </summary>
public class ContributionWallControl : FrameworkElement
{
    private const double MaxCellSize = 15;
    private const double MinCellSize = 6;
    private const double CellGap = 3;
    private const double LeftLabelWidth = 30;
    private const double TopLabelHeight = 18;
    private const double LegendHeight = 26;

    private IReadOnlyList<ContributionDay> _days = Array.Empty<ContributionDay>();
    private int[] _quartiles = Array.Empty<int>();
    private readonly ToolTip _toolTip;

    public ContributionWallControl()
    {
        SnapsToDevicePixels = true;
        UseLayoutRounding = true;
        _toolTip = new ToolTip
        {
            PlacementTarget = this,
            Placement = PlacementMode.Relative
        };
        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
    }

    /// <summary>悬停提示文案，由窗口按当前指标提供。</summary>
    public Func<ContributionDay, string>? TooltipFormatter { get; set; }

    public string LessText { get; set; } = string.Empty;

    public string MoreText { get; set; } = string.Empty;

    /// <summary>days 必须从某个周一开始、按天连续。</summary>
    public void Apply(IReadOnlyList<ContributionDay> days)
    {
        _days = days;
        // GitHub 式四分位分档：有数据的日子按 25/50/75 百分位分成 4 档，和图例一一对应
        var sorted = days.Where(d => d.IsInRange && d.Value > 0).Select(d => d.Value).OrderBy(v => v).ToList();
        _quartiles = sorted.Count == 0
            ? Array.Empty<int>()
            : new[] { 0.25, 0.5, 0.75 }.Select(p => sorted[(int)((sorted.Count - 1) * p)]).ToArray();
        InvalidateMeasure();
        InvalidateVisual();
    }

    private int ColumnCount => (_days.Count + 6) / 7;

    private double CellSizeFor(double width)
    {
        var columns = Math.Max(1, ColumnCount);
        var available = width - LeftLabelWidth - CellGap * (columns - 1);
        return Math.Max(MinCellSize, Math.Min(MaxCellSize, available / columns));
    }

    protected override Size MeasureOverride(Size availableSize)
    {
        var width = double.IsInfinity(availableSize.Width) ? 900 : availableSize.Width;
        var cell = CellSizeFor(width);
        var height = TopLabelHeight + cell * 7 + CellGap * 6 + LegendHeight;
        return new Size(width, height);
    }

    protected override void OnRender(DrawingContext drawingContext)
    {
        base.OnRender(drawingContext);
        if (_days.Count == 0 || ActualWidth <= 0)
        {
            return;
        }

        var isDarkMode = ThemeManager.Instance.IsDarkTheme;
        var cell = CellSizeFor(ActualWidth);
        var radius = Math.Max(2, cell * 0.2);
        var labelBrush = Freeze(new SolidColorBrush(HeatmapPalette.ResolveColor("TextSecondaryBrush", Colors.Gray)));
        var borderPen = new Pen(Freeze(new SolidColorBrush(isDarkMode
            ? Color.FromArgb(28, 255, 255, 255)
            : Color.FromArgb(20, 0, 0, 0))), 0.6);
        borderPen.Freeze();
        var culture = CultureInfo.CurrentUICulture;

        // 左侧星期标签：只标周一、周三、周五
        foreach (var row in new[] { 0, 2, 4 })
        {
            var dayOfWeek = (DayOfWeek)((row + 1) % 7);
            var text = CreateText(culture.DateTimeFormat.GetAbbreviatedDayName(dayOfWeek), 10, labelBrush);
            var y = TopLabelHeight + row * (cell + CellGap) + (cell - text.Height) / 2;
            drawingContext.DrawText(text, new Point(0, y));
        }

        var lastMonthLabelRight = double.MinValue;
        for (var index = 0; index < _days.Count; index++)
        {
            var day = _days[index];
            var column = index / 7;
            var row = index % 7;
            var x = LeftLabelWidth + column * (cell + CellGap);
            var y = TopLabelHeight + row * (cell + CellGap);

            // 顶部月份标签：标在每月第一天所在的列
            if ((day.IsInRange && day.Date.Day == 1) || (index == 0 && day.Date.Day <= 7))
            {
                var monthText = CreateText(culture.DateTimeFormat.GetAbbreviatedMonthName(day.Date.Month), 10, labelBrush);
                var labelX = LeftLabelWidth + column * (cell + CellGap);
                if (labelX > lastMonthLabelRight + 4)
                {
                    drawingContext.DrawText(monthText, new Point(labelX, 0));
                    lastMonthLabelRight = labelX + monthText.Width;
                }
            }

            if (!day.IsInRange)
            {
                continue;
            }

            var fill = Freeze(new SolidColorBrush(ColorFor(day.Value, isDarkMode)));
            drawingContext.DrawRoundedRectangle(fill, borderPen, new Rect(x, y, cell, cell), radius, radius);
        }

        DrawLegend(drawingContext, cell, radius, isDarkMode, labelBrush, borderPen);
    }

    private void DrawLegend(DrawingContext drawingContext, double cell, double radius, bool isDarkMode, Brush labelBrush, Pen borderPen)
    {
        var legendCell = Math.Min(cell, 12);
        var gridBottom = TopLabelHeight + cell * 7 + CellGap * 6;
        var top = gridBottom + (LegendHeight - legendCell) / 2 + 2;
        var gridRight = LeftLabelWidth + ColumnCount * (cell + CellGap) - CellGap;

        var moreText = CreateText(MoreText, 10, labelBrush);
        var lessText = CreateText(LessText, 10, labelBrush);
        var x = gridRight - moreText.Width;
        drawingContext.DrawText(moreText, new Point(x, top + (legendCell - moreText.Height) / 2));
        x -= 6;

        var levels = new[] { 1.0, 0.75, 0.5, 0.25 };
        foreach (var level in levels)
        {
            x -= legendCell;
            var brush = Freeze(new SolidColorBrush(HeatmapPalette.ColorFor(level, isDarkMode)));
            drawingContext.DrawRoundedRectangle(brush, borderPen, new Rect(x, top, legendCell, legendCell), radius, radius);
            x -= CellGap;
        }
        x -= legendCell;
        var neutral = Freeze(new SolidColorBrush(HeatmapPalette.NeutralColor(isDarkMode)));
        drawingContext.DrawRoundedRectangle(neutral, borderPen, new Rect(x, top, legendCell, legendCell), radius, radius);
        x -= 6 + lessText.Width;
        drawingContext.DrawText(lessText, new Point(x, top + (legendCell - lessText.Height) / 2));
    }

    private Color ColorFor(int value, bool isDarkMode)
    {
        if (value <= 0 || _quartiles.Length == 0)
        {
            return HeatmapPalette.NeutralColor(isDarkMode);
        }

        var intensity = value <= _quartiles[0] ? 0.25
            : value <= _quartiles[1] ? 0.5
            : value <= _quartiles[2] ? 0.75
            : 1.0;
        return HeatmapPalette.ColorFor(intensity, isDarkMode);
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        var day = HitTestDay(e.GetPosition(this));
        if (day == null || TooltipFormatter == null)
        {
            _toolTip.IsOpen = false;
            return;
        }

        var position = e.GetPosition(this);
        _toolTip.Content = TooltipFormatter(day);
        _toolTip.HorizontalOffset = position.X + 12;
        _toolTip.VerticalOffset = position.Y + 16;
        _toolTip.IsOpen = true;
    }

    protected override void OnMouseLeave(MouseEventArgs e)
    {
        base.OnMouseLeave(e);
        _toolTip.IsOpen = false;
    }

    private ContributionDay? HitTestDay(Point point)
    {
        if (_days.Count == 0)
        {
            return null;
        }

        var cell = CellSizeFor(ActualWidth);
        var step = cell + CellGap;
        var localX = point.X - LeftLabelWidth;
        var localY = point.Y - TopLabelHeight;
        if (localX < 0 || localY < 0)
        {
            return null;
        }

        var column = (int)(localX / step);
        var row = (int)(localY / step);
        if (row > 6 || localX - column * step > cell || localY - row * step > cell)
        {
            return null;
        }

        var index = column * 7 + row;
        if (index >= _days.Count || !_days[index].IsInRange)
        {
            return null;
        }
        return _days[index];
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

    private FormattedText CreateText(string value, double fontSize, Brush brush)
    {
        return new FormattedText(
            value,
            CultureInfo.CurrentUICulture,
            FlowDirection.LeftToRight,
            new Typeface(new FontFamily("Segoe UI"), FontStyles.Normal, FontWeights.Normal, FontStretches.Normal),
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
