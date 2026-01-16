using System.Collections;
using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;
using KeyStats.ViewModels;

namespace KeyStats.Views.Controls;

public partial class StatsChartControl : UserControl
{
    public static readonly DependencyProperty ChartDataProperty =
        DependencyProperty.Register(nameof(ChartData), typeof(IEnumerable), typeof(StatsChartControl),
            new PropertyMetadata(null, OnDataChanged));

    public static readonly DependencyProperty ChartStyleProperty =
        DependencyProperty.Register(nameof(ChartStyle), typeof(int), typeof(StatsChartControl),
            new PropertyMetadata(0, OnDataChanged));

    public IEnumerable? ChartData
    {
        get => (IEnumerable?)GetValue(ChartDataProperty);
        set => SetValue(ChartDataProperty, value);
    }

    public int ChartStyle
    {
        get => (int)GetValue(ChartStyleProperty);
        set => SetValue(ChartStyleProperty, value);
    }

    private readonly SolidColorBrush _lineBrush = new(Color.FromRgb(0, 120, 212));
    private readonly SolidColorBrush _fillBrush = new(Color.FromArgb(50, 0, 120, 212));
    private readonly SolidColorBrush _gridBrush = new(Color.FromArgb(60, 128, 128, 128));
    private readonly SolidColorBrush _axisBrush = new(Color.FromArgb(100, 128, 128, 128));
    private readonly SolidColorBrush _textBrush;

    public StatsChartControl()
    {
        InitializeComponent();
        _textBrush = new SolidColorBrush((Color)Application.Current.Resources[SystemColors.GrayTextColorKey]);
        SizeChanged += OnSizeChanged;
    }

    private static void OnDataChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        if (d is StatsChartControl control)
        {
            control.DrawChart();
        }
    }

    private void OnSizeChanged(object sender, SizeChangedEventArgs e)
    {
        DrawChart();
    }

    private void DrawChart()
    {
        ChartCanvas.Children.Clear();

        var data = ChartData?.Cast<ChartDataPoint>().ToList();
        if (data == null || data.Count == 0)
        {
            DrawEmptyState();
            return;
        }

        var width = ChartCanvas.ActualWidth;
        var height = ChartCanvas.ActualHeight;

        if (width <= 0 || height <= 0) return;

        const double leftPadding = 36;
        const double rightPadding = 10;
        const double topPadding = 10;
        const double bottomPadding = 20;

        var plotWidth = width - leftPadding - rightPadding;
        var plotHeight = height - topPadding - bottomPadding;

        if (plotWidth <= 0 || plotHeight <= 0) return;

        var maxValue = data.Max(d => d.Value);
        if (maxValue <= 0) maxValue = 1;

        // Draw grid
        DrawGrid(leftPadding, topPadding, plotWidth, plotHeight);

        // Draw axes
        DrawAxes(leftPadding, topPadding, plotWidth, plotHeight);

        // Draw axis labels
        DrawAxisLabels(leftPadding, topPadding, plotWidth, plotHeight, maxValue, data);

        // Draw chart
        if (ChartStyle == 0)
        {
            DrawLineChart(data, leftPadding, topPadding, plotWidth, plotHeight, maxValue);
        }
        else
        {
            DrawBarChart(data, leftPadding, topPadding, plotWidth, plotHeight, maxValue);
        }
    }

    private void DrawEmptyState()
    {
        var text = new TextBlock
        {
            Text = "No data available",
            Foreground = _textBrush,
            FontSize = 12
        };
        text.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        Canvas.SetLeft(text, (ChartCanvas.ActualWidth - text.DesiredSize.Width) / 2);
        Canvas.SetTop(text, (ChartCanvas.ActualHeight - text.DesiredSize.Height) / 2);
        ChartCanvas.Children.Add(text);
    }

    private void DrawGrid(double left, double top, double width, double height)
    {
        for (int i = 1; i <= 3; i++)
        {
            var y = top + height - (height * i / 4);
            var line = new Line
            {
                X1 = left,
                Y1 = y,
                X2 = left + width,
                Y2 = y,
                Stroke = _gridBrush,
                StrokeThickness = 1
            };
            ChartCanvas.Children.Add(line);
        }
    }

    private void DrawAxes(double left, double top, double width, double height)
    {
        // Y axis
        var yAxis = new Line
        {
            X1 = left,
            Y1 = top,
            X2 = left,
            Y2 = top + height,
            Stroke = _axisBrush,
            StrokeThickness = 1
        };
        ChartCanvas.Children.Add(yAxis);

        // X axis
        var xAxis = new Line
        {
            X1 = left,
            Y1 = top + height,
            X2 = left + width,
            Y2 = top + height,
            Stroke = _axisBrush,
            StrokeThickness = 1
        };
        ChartCanvas.Children.Add(xAxis);
    }

    private void DrawAxisLabels(double left, double top, double width, double height, double maxValue, List<ChartDataPoint> data)
    {
        // Y-axis labels
        var yLabels = new[] { 0.0, maxValue / 2, maxValue };
        for (int i = 0; i < yLabels.Length; i++)
        {
            var y = top + height - (height * i / 2);
            var text = FormatValue(yLabels[i]);
            var label = CreateLabel(text, _textBrush, 10);
            label.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            Canvas.SetLeft(label, left - label.DesiredSize.Width - 4);
            Canvas.SetTop(label, y - label.DesiredSize.Height / 2);
            ChartCanvas.Children.Add(label);
        }

        // X-axis labels
        if (data.Count <= 1) return;

        var step = data.Count <= 7 ? 2 : Math.Max(1, data.Count / 5);
        for (int i = 0; i < data.Count; i += step)
        {
            var x = ChartStyle == 0
                ? left + (width * i / (data.Count - 1))
                : left + (width * (i + 0.5) / data.Count);

            var text = data[i].Date.ToString("M/d");
            var label = CreateLabel(text, _textBrush, 10);
            label.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            Canvas.SetLeft(label, x - label.DesiredSize.Width / 2);
            Canvas.SetTop(label, top + height + 4);
            ChartCanvas.Children.Add(label);
        }

        // Always show last label
        if (data.Count > 1)
        {
            var lastIndex = data.Count - 1;
            if (lastIndex % step != 0)
            {
                var x = ChartStyle == 0
                    ? left + width
                    : left + (width * (lastIndex + 0.5) / data.Count);

                var text = data[lastIndex].Date.ToString("M/d");
                var label = CreateLabel(text, _textBrush, 10);
                label.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
                Canvas.SetLeft(label, x - label.DesiredSize.Width / 2);
                Canvas.SetTop(label, top + height + 4);
                ChartCanvas.Children.Add(label);
            }
        }
    }

    private void DrawLineChart(List<ChartDataPoint> data, double left, double top, double width, double height, double maxValue)
    {
        if (data.Count < 2) return;

        var points = new PointCollection();
        for (int i = 0; i < data.Count; i++)
        {
            var x = left + (width * i / (data.Count - 1));
            var y = top + height - (height * data[i].Value / maxValue);
            points.Add(new Point(x, y));
        }

        // Draw line
        var polyline = new Polyline
        {
            Points = points,
            Stroke = _lineBrush,
            StrokeThickness = 2,
            StrokeLineJoin = PenLineJoin.Round
        };
        ChartCanvas.Children.Add(polyline);

        // Draw dots
        foreach (var point in points)
        {
            var dot = new Ellipse
            {
                Width = 5,
                Height = 5,
                Fill = _lineBrush
            };
            Canvas.SetLeft(dot, point.X - 2.5);
            Canvas.SetTop(dot, point.Y - 2.5);
            ChartCanvas.Children.Add(dot);
        }
    }

    private void DrawBarChart(List<ChartDataPoint> data, double left, double top, double width, double height, double maxValue)
    {
        var barWidth = Math.Min(width * 0.6 / data.Count, 22);
        var stepX = width / data.Count;

        for (int i = 0; i < data.Count; i++)
        {
            var barHeight = height * data[i].Value / maxValue;
            var x = left + (i * stepX) + (stepX - barWidth) / 2;
            var y = top + height - barHeight;

            var bar = new Rectangle
            {
                Width = barWidth,
                Height = Math.Max(0, barHeight),
                Fill = _lineBrush,
                RadiusX = 2,
                RadiusY = 2
            };
            Canvas.SetLeft(bar, x);
            Canvas.SetTop(bar, y);
            ChartCanvas.Children.Add(bar);
        }
    }

    private TextBlock CreateLabel(string text, Brush foreground, double fontSize)
    {
        return new TextBlock
        {
            Text = text,
            Foreground = foreground,
            FontSize = fontSize
        };
    }

    private string FormatValue(double value)
    {
        if (value >= 1_000_000)
            return $"{value / 1_000_000:F1}M";
        if (value >= 1_000)
            return $"{value / 1_000:F1}k";
        return value.ToString("N0");
    }
}
