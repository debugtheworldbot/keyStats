using System;
using System.Windows;
using System.Windows.Media;
using KeyStats.Helpers;

namespace KeyStats.Views.Controls;

/// <summary>
/// 设置页里的热力图色阶预览：从「未按过」到最高热度的一排小键帽。
/// </summary>
public class HeatmapPalettePreviewControl : FrameworkElement
{
    private const int CellCount = 9;
    private const double CellGap = 4;

    public HeatmapPalettePreviewControl()
    {
        SnapsToDevicePixels = true;
        UseLayoutRounding = true;
        Height = 22;
        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
    }

    protected override void OnRender(DrawingContext drawingContext)
    {
        base.OnRender(drawingContext);

        if (ActualWidth <= 0 || ActualHeight <= 0)
        {
            return;
        }

        var isDarkMode = ThemeManager.Instance.IsDarkTheme;
        var borderColor = isDarkMode
            ? Color.FromArgb(36, 255, 255, 255)
            : Color.FromArgb(23, 0, 0, 0);
        var borderPen = new Pen(new SolidColorBrush(borderColor), 0.8);
        borderPen.Freeze();

        var cellWidth = (ActualWidth - CellGap * (CellCount - 1)) / CellCount;
        if (cellWidth <= 0)
        {
            return;
        }

        var radius = Math.Min(4, ActualHeight * 0.2);
        for (var i = 0; i < CellCount; i++)
        {
            var color = i == 0
                ? HeatmapPalette.NeutralColor(isDarkMode)
                : HeatmapPalette.ColorFor(i / (double)(CellCount - 1), isDarkMode);
            var brush = new SolidColorBrush(color);
            brush.Freeze();
            var rect = new Rect(i * (cellWidth + CellGap), 0, cellWidth, ActualHeight);
            drawingContext.DrawRoundedRectangle(brush, borderPen, rect, radius, radius);
        }
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
    }

    private void OnPaletteChanged()
    {
        Dispatcher.BeginInvoke(new Action(InvalidateVisual));
    }
}
