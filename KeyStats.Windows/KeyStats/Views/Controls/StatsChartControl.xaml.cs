using System;
using System.Collections;
using System.Collections.Generic;
using System.Collections.Specialized;
using System.Globalization;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;
using KeyStats.Helpers;
using KeyStats.Services;
using KeyStats.ViewModels;

namespace KeyStats.Views.Controls;

public partial class StatsChartControl : System.Windows.Controls.UserControl
{
    public static readonly DependencyProperty ChartDataProperty =
        DependencyProperty.Register(nameof(ChartData), typeof(IEnumerable), typeof(StatsChartControl),
            new PropertyMetadata(null, OnChartDataChanged));

    public static readonly DependencyProperty LocalChartDataProperty =
        DependencyProperty.Register(nameof(LocalChartData), typeof(IEnumerable), typeof(StatsChartControl),
            new PropertyMetadata(null, OnChartDataChanged));

    public static readonly DependencyProperty ChartStyleProperty =
        DependencyProperty.Register(nameof(ChartStyle), typeof(int), typeof(StatsChartControl),
            new PropertyMetadata(0, OnPropertyChanged));

    public static readonly DependencyProperty SelectedMetricIndexProperty =
        DependencyProperty.Register(nameof(SelectedMetricIndex), typeof(int), typeof(StatsChartControl),
            new PropertyMetadata(0, OnPropertyChanged));

    public IEnumerable? ChartData
    {
        get => (IEnumerable?)GetValue(ChartDataProperty);
        set => SetValue(ChartDataProperty, value);
    }

    public IEnumerable? LocalChartData
    {
        get => (IEnumerable?)GetValue(LocalChartDataProperty);
        set => SetValue(LocalChartDataProperty, value);
    }

    public int ChartStyle
    {
        get => (int)GetValue(ChartStyleProperty);
        set => SetValue(ChartStyleProperty, value);
    }

    public int SelectedMetricIndex
    {
        get => (int)GetValue(SelectedMetricIndexProperty);
        set => SetValue(SelectedMetricIndexProperty, value);
    }

    private SolidColorBrush _lineBrush = new(Color.FromRgb(0, 120, 212));
    private SolidColorBrush _fillBrush = new(Color.FromArgb(50, 0, 120, 212));
    private SolidColorBrush _gridBrush = new(Color.FromArgb(60, 128, 128, 128));
    private SolidColorBrush _axisBrush = new(Color.FromArgb(100, 128, 128, 128));
    private SolidColorBrush _textBrush = new(SystemColors.GrayTextColor);
    private SolidColorBrush _highlightBrush = new(Color.FromRgb(255, 100, 50));
    private SolidColorBrush _localLineBrush = new(Color.FromRgb(249, 168, 37));

    // Stores data point positions for mouse hover hit-testing
    private List<PointData> _dataPoints = new();
    private List<ChartDataPoint>? _localDataPoints;

    // Hover labels (wrapped in Border to occlude the static axis labels)
    private Border? _hoverYContainer;
    private Border? _hoverXContainer;
    private SolidColorBrush _hoverBgBrush = new(Color.FromArgb(230, 248, 248, 248));
    private readonly List<UIElement> _hoverMarkerElements = new();
    private readonly List<UIElement> _legendElements = new();

    // Plot area parameters (used for hover hit-testing)
    private double _plotLeft;
    private double _plotTop;
    private double _plotWidth;
    private double _plotHeight;

    public StatsChartControl()
    {
        InitializeComponent();
        UpdateBrushesFromTheme();
        SizeChanged += OnSizeChanged;

        // Wire up mouse move handlers for hover detection
        ChartCanvas.MouseMove += OnCanvasMouseMove;
        ChartCanvas.MouseLeave += OnCanvasMouseLeave;

        ThemeManager.Instance.ThemeChanged += OnThemeChanged;
    }

    private void OnThemeChanged()
    {
        UpdateBrushesFromTheme();
        DrawChart();
    }

    private void UpdateBrushesFromTheme()
    {
        var isDark = ThemeManager.Instance.IsDarkTheme;

        var res = Application.Current?.Resources;
        if (res?["ChartLineBrush"] is SolidColorBrush chartLine)
            _lineBrush = chartLine;

        _fillBrush = isDark
            ? new SolidColorBrush(Color.FromArgb(50, 0, 120, 212))
            : new SolidColorBrush(Color.FromArgb(50, 0, 120, 212));

        _gridBrush = isDark
            ? new SolidColorBrush(Color.FromArgb(40, 255, 255, 255))
            : new SolidColorBrush(Color.FromArgb(60, 128, 128, 128));

        _axisBrush = isDark
            ? new SolidColorBrush(Color.FromArgb(60, 255, 255, 255))
            : new SolidColorBrush(Color.FromArgb(100, 128, 128, 128));

        _textBrush = isDark
            ? new SolidColorBrush(Color.FromRgb(170, 170, 170))
            : new SolidColorBrush(SystemColors.GrayTextColor);

        _highlightBrush = new SolidColorBrush(Color.FromRgb(255, 100, 50));
        _localLineBrush = new SolidColorBrush(Color.FromRgb(249, 168, 37));

        _hoverBgBrush = isDark
            ? new SolidColorBrush(Color.FromArgb(230, 45, 45, 45))
            : new SolidColorBrush(Color.FromArgb(230, 248, 248, 248));
    }

    private static void OnChartDataChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        if (d is StatsChartControl control)
        {
            // Unsubscribe from the old collection's change events
            if (e.OldValue is INotifyCollectionChanged oldCollection)
            {
                oldCollection.CollectionChanged -= control.OnChartDataCollectionChanged;
            }

            // Subscribe to the new collection's change events
            if (e.NewValue is INotifyCollectionChanged newCollection)
            {
                newCollection.CollectionChanged += control.OnChartDataCollectionChanged;
            }

            control.DrawChart();
        }
    }

    private void OnChartDataCollectionChanged(object? sender, NotifyCollectionChangedEventArgs e)
    {
        // Redraw the chart when the underlying collection changes
        DrawChart();
    }

    private static void OnPropertyChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
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
        _dataPoints.Clear();
        _localDataPoints = null;
        _hoverMarkerElements.Clear();
        _legendElements.Clear();
        _hoverYContainer = null;
        _hoverXContainer = null;

        var data = ChartData?.Cast<ChartDataPoint>().ToList();
        if (data == null || data.Count == 0)
        {
            DrawEmptyState();
            return;
        }

        var width = ChartCanvas.ActualWidth;
        var height = ChartCanvas.ActualHeight;

        if (width <= 0 || height <= 0) return;

        var localData = GetLocalData(data);
        _localDataPoints = localData;

        var maxValue = Math.Max(
            data.Max(d => d.Value),
            localData?.Max(d => d.Value) ?? 0);
        if (maxValue <= 0) maxValue = 1;

        // Calculate left padding dynamically based on the widest Y-axis label
        var maxLabel = CreateLabel(FormatValue(maxValue), _textBrush, 10);
        maxLabel.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        var leftPadding = Math.Max(36, maxLabel.DesiredSize.Width + 8);

        const double rightPadding = 10;
        var topPadding = localData == null ? 10 : 26;
        const double bottomPadding = 20;

        _plotLeft = leftPadding;
        _plotTop = topPadding;
        _plotWidth = width - leftPadding - rightPadding;
        _plotHeight = height - topPadding - bottomPadding;

        if (_plotWidth <= 0 || _plotHeight <= 0) return;

        // Draw grid
        DrawGrid(_plotLeft, _plotTop, _plotWidth, _plotHeight);

        // Draw axes
        DrawAxes(_plotLeft, _plotTop, _plotWidth, _plotHeight);

        // Draw axis labels
        DrawAxisLabels(_plotLeft, _plotTop, _plotWidth, _plotHeight, maxValue, data);

        // Draw chart
        if (ChartStyle == 0)
        {
            DrawLineChart(data, localData, _plotLeft, _plotTop, _plotWidth, _plotHeight, maxValue);
        }
        else
        {
            DrawBarChart(data, localData, _plotLeft, _plotTop, _plotWidth, _plotHeight, maxValue);
        }

        DrawLegend(localData, null);
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

    private List<ChartDataPoint>? GetLocalData(List<ChartDataPoint> displayData)
    {
        var localData = LocalChartData?.Cast<ChartDataPoint>().ToList();
        return localData != null && localData.Count == displayData.Count ? localData : null;
    }

    private void DrawLineChart(
        List<ChartDataPoint> data,
        List<ChartDataPoint>? localData,
        double left,
        double top,
        double width,
        double height,
        double maxValue)
    {
        DrawLineSeries(data, left, top, width, height, maxValue, _lineBrush, 2, null, 2.5, recordHoverPoints: true);

        if (localData != null)
        {
            DrawLineSeries(
                localData,
                left,
                top,
                width,
                height,
                maxValue,
                _localLineBrush,
                1.75,
                new DoubleCollection { 5, 3 },
                2,
                recordHoverPoints: false);
        }
    }

    private void DrawLineSeries(
        List<ChartDataPoint> data,
        double left,
        double top,
        double width,
        double height,
        double maxValue,
        System.Windows.Media.Brush brush,
        double strokeThickness,
        DoubleCollection? dashPattern,
        double dotRadius,
        bool recordHoverPoints)
    {
        if (data.Count == 0) return;

        var points = new PointCollection();
        var pointList = new List<Point>();
        
        for (int i = 0; i < data.Count; i++)
        {
            var x = data.Count == 1
                ? left + width / 2
                : left + (width * i / (data.Count - 1));
            var y = top + height - (height * data[i].Value / maxValue);
            var point = new Point(x, y);
            points.Add(point);
            pointList.Add(point);

            if (recordHoverPoints)
            {
                // Record the data point for later hover hit-testing
                _dataPoints.Add(new PointData
                {
                    DataPoint = data[i],
                    Position = point,
                    Index = i
                });
            }
        }

        // Draw line
        var polyline = new Polyline
        {
            Points = points,
            Stroke = brush,
            StrokeThickness = strokeThickness,
            StrokeLineJoin = PenLineJoin.Round
        };
        if (dashPattern != null)
        {
            polyline.StrokeDashArray = dashPattern;
        }
        ChartCanvas.Children.Add(polyline);

        // Draw dots
        foreach (var point in pointList)
        {
            var dot = new Ellipse
            {
                Width = dotRadius * 2,
                Height = dotRadius * 2,
                Fill = brush
            };
            Canvas.SetLeft(dot, point.X - dotRadius);
            Canvas.SetTop(dot, point.Y - dotRadius);
            ChartCanvas.Children.Add(dot);
        }
    }

    private void DrawBarChart(
        List<ChartDataPoint> data,
        List<ChartDataPoint>? localData,
        double left,
        double top,
        double width,
        double height,
        double maxValue)
    {
        var hasLocalData = localData != null;
        var stepX = width / data.Count;
        var groupWidth = Math.Min(stepX * 0.72, 26);
        var barSpacing = hasLocalData ? 2 : 0;
        var barWidth = hasLocalData ? (groupWidth - barSpacing) / 2 : Math.Min(width * 0.6 / data.Count, 22);

        for (int i = 0; i < data.Count; i++)
        {
            var barHeight = height * data[i].Value / maxValue;
            var groupX = left + (i * stepX) + (stepX - groupWidth) / 2;
            var x = hasLocalData ? groupX : left + (i * stepX) + (stepX - barWidth) / 2;
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

            if (hasLocalData && localData != null)
            {
                var localBarHeight = height * localData[i].Value / maxValue;
                var localX = groupX + barWidth + barSpacing;
                var localY = top + height - localBarHeight;
                var localBar = new Rectangle
                {
                    Width = barWidth,
                    Height = Math.Max(0, localBarHeight),
                    Fill = _localLineBrush,
                    RadiusX = 2,
                    RadiusY = 2
                };
                Canvas.SetLeft(localBar, localX);
                Canvas.SetTop(localBar, localY);
                ChartCanvas.Children.Add(localBar);
            }

            // Record the data point at the bar center for hover hit-testing
            var centerX = x + barWidth / 2;
            var centerY = y;
            _dataPoints.Add(new PointData
            {
                DataPoint = data[i],
                Position = new Point(centerX, centerY),
                Index = i
            });
        }
    }

    private void DrawLegend(List<ChartDataPoint>? localData, PointData? hoverPoint)
    {
        RemoveLegend();

        if (localData == null || localData.Count != _dataPoints.Count || _dataPoints.Count == 0)
        {
            return;
        }

        var syncedLabel = KeyStats.Properties.Strings.History_SeriesSynced;
        var localLabel = KeyStats.Properties.Strings.Sync_ThisDevice;
        if (hoverPoint != null && hoverPoint.Index >= 0 && hoverPoint.Index < localData.Count)
        {
            syncedLabel = $"{syncedLabel}: {FormatValue(hoverPoint.DataPoint.Value)}";
            localLabel = $"{localLabel}: {FormatValue(localData[hoverPoint.Index].Value)}";
        }

        var items = new[]
        {
            (Text: syncedLabel, Brush: (System.Windows.Media.Brush)_lineBrush, Dashed: false),
            (Text: localLabel, Brush: (System.Windows.Media.Brush)_localLineBrush, Dashed: true)
        };

        const double sampleWidth = 14;
        const double sampleSpacing = 4;
        const double itemSpacing = 12;
        const double fontSize = 10;
        var itemWidths = new List<double>();
        var textBlocks = new List<TextBlock>();

        foreach (var item in items)
        {
            var label = CreateLabel(item.Text, _textBrush, fontSize);
            label.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            textBlocks.Add(label);
            itemWidths.Add(sampleWidth + sampleSpacing + label.DesiredSize.Width);
        }

        var totalWidth = itemWidths.Sum() + itemSpacing;
        var x = Math.Max(_plotLeft + 8, _plotLeft + _plotWidth - totalWidth - 8);
        var textHeight = textBlocks.Max(label => label.DesiredSize.Height);
        var textY = Math.Max(4, _plotTop - textHeight - 7);
        var sampleY = textY + textHeight / 2;

        for (var i = 0; i < items.Length; i++)
        {
            UIElement sample;
            if (ChartStyle == 0)
            {
                var line = new Line
                {
                    X1 = x,
                    Y1 = sampleY,
                    X2 = x + sampleWidth,
                    Y2 = sampleY,
                    Stroke = items[i].Brush,
                    StrokeThickness = 2,
                    StrokeDashArray = items[i].Dashed ? new DoubleCollection { 4, 2 } : null
                };
                sample = line;
            }
            else
            {
                var rect = new Rectangle
                {
                    Width = sampleWidth,
                    Height = 6,
                    Fill = items[i].Brush,
                    RadiusX = 1.5,
                    RadiusY = 1.5
                };
                Canvas.SetLeft(rect, x);
                Canvas.SetTop(rect, sampleY - 3);
                sample = rect;
            }

            var label = textBlocks[i];
            Canvas.SetLeft(label, x + sampleWidth + sampleSpacing);
            Canvas.SetTop(label, textY);
            ChartCanvas.Children.Add(sample);
            ChartCanvas.Children.Add(label);
            _legendElements.Add(sample);
            _legendElements.Add(label);
            x += itemWidths[i] + itemSpacing;
        }
    }

    private void RemoveLegend()
    {
        foreach (var element in _legendElements)
        {
            ChartCanvas.Children.Remove(element);
        }
        _legendElements.Clear();
    }

    private TextBlock CreateLabel(string text, System.Windows.Media.Brush foreground, double fontSize)
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
        // Pick the formatter that matches the currently selected metric
        var metric = SelectedMetricIndex switch
        {
            0 => StatsManager.HistoryMetric.Clicks,
            1 => StatsManager.HistoryMetric.KeyPresses,
            2 => StatsManager.HistoryMetric.MouseDistance,
            3 => StatsManager.HistoryMetric.ScrollDistance,
            _ => StatsManager.HistoryMetric.Clicks
        };

        return StatsManager.Instance.FormatHistoryValue(metric, value);
    }

    private void OnCanvasMouseMove(object sender, System.Windows.Input.MouseEventArgs e)
    {
        var position = e.GetPosition(ChartCanvas);

        // Only hit-test inside the actual plot area
        if (position.X < _plotLeft || position.X > _plotLeft + _plotWidth ||
            position.Y < _plotTop || position.Y > _plotTop + _plotHeight)
        {
            HideHoverLabels();
            return;
        }

        // Find the nearest data point by X distance only (any Y inside the plot area triggers hover)
        PointData? closestPoint = null;
        double minDistanceX = double.MaxValue;

        foreach (var pointData in _dataPoints)
        {
            double distanceX = Math.Abs(pointData.Position.X - position.X);
            if (distanceX < minDistanceX)
            {
                minDistanceX = distanceX;
                closestPoint = pointData;
            }
        }

        if (closestPoint != null)
        {
            ChartCanvas.Cursor = System.Windows.Input.Cursors.Hand;
            ShowHoverLabels(closestPoint);
        }
        else
        {
            ChartCanvas.Cursor = System.Windows.Input.Cursors.Arrow;
            HideHoverLabels();
        }
    }

    private void OnCanvasMouseLeave(object sender, System.Windows.Input.MouseEventArgs e)
    {
        ChartCanvas.Cursor = System.Windows.Input.Cursors.Arrow;
        HideHoverLabels();
    }

    private void ShowHoverLabels(PointData pointData)
    {
        var plotBottom = _plotTop + _plotHeight;

        // Remove the previous hover labels
        if (_hoverYContainer != null)
            ChartCanvas.Children.Remove(_hoverYContainer);
        if (_hoverXContainer != null)
            ChartCanvas.Children.Remove(_hoverXContainer);
        RemoveHoverMarkers();
        DrawHoverMarkers(pointData);
        DrawLegend(_localDataPoints, pointData);

        // Build the Y-axis hover label (value) with a background that covers the static label
        var yLabel = CreateLabel(FormatValue(pointData.DataPoint.Value), _highlightBrush, 10);
        yLabel.FontWeight = FontWeights.Bold;
        _hoverYContainer = new Border
        {
            Background = _hoverBgBrush,
            CornerRadius = new CornerRadius(2),
            Padding = new Thickness(2, 0, 2, 0),
            Child = yLabel
        };
        _hoverYContainer.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        Canvas.SetLeft(_hoverYContainer, _plotLeft - _hoverYContainer.DesiredSize.Width - 2);
        Canvas.SetTop(_hoverYContainer, pointData.Position.Y - _hoverYContainer.DesiredSize.Height / 2);
        ChartCanvas.Children.Add(_hoverYContainer);

        // Build the X-axis hover label (date) with a background that covers the static label
        var xLabel = CreateLabel(pointData.DataPoint.Date.ToString("M/d"), _highlightBrush, 10);
        xLabel.FontWeight = FontWeights.Bold;
        _hoverXContainer = new Border
        {
            Background = _hoverBgBrush,
            CornerRadius = new CornerRadius(2),
            Padding = new Thickness(2, 0, 2, 0),
            Child = xLabel
        };
        _hoverXContainer.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        Canvas.SetLeft(_hoverXContainer, pointData.Position.X - _hoverXContainer.DesiredSize.Width / 2);
        Canvas.SetTop(_hoverXContainer, plotBottom + 2);
        ChartCanvas.Children.Add(_hoverXContainer);
    }

    private void HideHoverLabels()
    {
        if (_hoverYContainer != null)
        {
            ChartCanvas.Children.Remove(_hoverYContainer);
            _hoverYContainer = null;
        }
        if (_hoverXContainer != null)
        {
            ChartCanvas.Children.Remove(_hoverXContainer);
            _hoverXContainer = null;
        }
        RemoveHoverMarkers();
        DrawLegend(_localDataPoints, null);
    }

    private void DrawHoverMarkers(PointData pointData)
    {
        var x = pointData.Position.X;
        var y = pointData.Position.Y;

        var verticalLine = new Line
        {
            X1 = x,
            Y1 = _plotTop,
            X2 = x,
            Y2 = _plotTop + _plotHeight,
            Stroke = new SolidColorBrush(Color.FromArgb(55, _lineBrush.Color.R, _lineBrush.Color.G, _lineBrush.Color.B)),
            StrokeThickness = 1
        };
        var horizontalLine = new Line
        {
            X1 = _plotLeft,
            Y1 = y,
            X2 = _plotLeft + _plotWidth,
            Y2 = y,
            Stroke = new SolidColorBrush(Color.FromArgb(55, _lineBrush.Color.R, _lineBrush.Color.G, _lineBrush.Color.B)),
            StrokeThickness = 1
        };
        AddHoverMarker(verticalLine);
        AddHoverMarker(horizontalLine);

        AddHoverDot(x, y, _lineBrush, 5, 2);

        if (_localDataPoints != null && pointData.Index >= 0 && pointData.Index < _localDataPoints.Count)
        {
            var localValue = _localDataPoints[pointData.Index].Value;
            var localY = _plotTop + _plotHeight - (_plotHeight * localValue / GetCurrentMaxValue());
            var localRadius = Math.Abs(localY - y) < 1 ? 6 : 5;
            AddHoverDot(x, localY, _localLineBrush, localRadius, 1.5);
            if (Math.Abs(localY - y) < 1)
            {
                AddHoverDot(x, y, _lineBrush, 3, 0);
            }
        }
    }

    private double GetCurrentMaxValue()
    {
        var displayMax = ChartData?.Cast<ChartDataPoint>().Select(point => point.Value).DefaultIfEmpty(0).Max() ?? 0;
        var localMax = _localDataPoints?.Select(point => point.Value).DefaultIfEmpty(0).Max() ?? 0;
        return Math.Max(Math.Max(displayMax, localMax), 1);
    }

    private void AddHoverDot(double x, double y, System.Windows.Media.Brush fill, double radius, double strokeThickness)
    {
        var dot = new Ellipse
        {
            Width = radius * 2,
            Height = radius * 2,
            Fill = fill,
            Stroke = strokeThickness > 0 ? Brushes.White : null,
            StrokeThickness = strokeThickness
        };
        Canvas.SetLeft(dot, x - radius);
        Canvas.SetTop(dot, y - radius);
        AddHoverMarker(dot);
    }

    private void AddHoverMarker(UIElement element)
    {
        ChartCanvas.Children.Add(element);
        _hoverMarkerElements.Add(element);
    }

    private void RemoveHoverMarkers()
    {
        foreach (var element in _hoverMarkerElements)
        {
            ChartCanvas.Children.Remove(element);
        }
        _hoverMarkerElements.Clear();
    }

    private class PointData
    {
        public ChartDataPoint DataPoint { get; set; } = null!;
        public Point Position { get; set; }
        public int Index { get; set; }
    }
}
