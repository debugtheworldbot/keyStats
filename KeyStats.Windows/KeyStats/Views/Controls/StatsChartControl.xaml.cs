using System.Collections;
using System.Collections.Specialized;
using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;
using KeyStats.Services;
using KeyStats.ViewModels;

namespace KeyStats.Views.Controls;

public partial class StatsChartControl : System.Windows.Controls.UserControl
{
    public static readonly DependencyProperty ChartDataProperty =
        DependencyProperty.Register(nameof(ChartData), typeof(IEnumerable), typeof(StatsChartControl),
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

    private readonly SolidColorBrush _lineBrush = new(Color.FromRgb(0, 120, 212));
    private readonly SolidColorBrush _fillBrush = new(Color.FromArgb(50, 0, 120, 212));
    private readonly SolidColorBrush _gridBrush = new(Color.FromArgb(60, 128, 128, 128));
    private readonly SolidColorBrush _axisBrush = new(Color.FromArgb(100, 128, 128, 128));
    private readonly SolidColorBrush _textBrush;
    private readonly SolidColorBrush _highlightBrush = new(Color.FromRgb(255, 100, 50));
    
    // 存储数据点位置信息，用于鼠标悬停检测
    private List<PointData> _dataPoints = new();
    
    // 悬停标签
    private TextBlock? _hoverYLabel;
    private TextBlock? _hoverXLabel;
    
    // 绘图区域参数（用于 hover 检测）
    private double _plotLeft;
    private double _plotTop;
    private double _plotWidth;
    private double _plotHeight;

    public StatsChartControl()
    {
        InitializeComponent();
        // 使用 SystemColors 直接获取颜色，更安全
        var grayTextColor = SystemColors.GrayTextColor;
        _textBrush = new SolidColorBrush(grayTextColor);
        SizeChanged += OnSizeChanged;
        
        // 添加鼠标移动事件处理
        ChartCanvas.MouseMove += OnCanvasMouseMove;
        ChartCanvas.MouseLeave += OnCanvasMouseLeave;
    }

    private static void OnChartDataChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        if (d is StatsChartControl control)
        {
            // 取消订阅旧集合的变化事件
            if (e.OldValue is INotifyCollectionChanged oldCollection)
            {
                oldCollection.CollectionChanged -= control.OnChartDataCollectionChanged;
            }

            // 订阅新集合的变化事件
            if (e.NewValue is INotifyCollectionChanged newCollection)
            {
                newCollection.CollectionChanged += control.OnChartDataCollectionChanged;
            }

            control.DrawChart();
        }
    }

    private void OnChartDataCollectionChanged(object? sender, NotifyCollectionChangedEventArgs e)
    {
        // 当集合内容变化时，重新绘制图表
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
        _hoverYLabel = null;
        _hoverXLabel = null;

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

        _plotLeft = leftPadding;
        _plotTop = topPadding;
        _plotWidth = width - leftPadding - rightPadding;
        _plotHeight = height - topPadding - bottomPadding;

        if (_plotWidth <= 0 || _plotHeight <= 0) return;

        var maxValue = data.Max(d => d.Value);
        if (maxValue <= 0) maxValue = 1;

        // Draw grid
        DrawGrid(_plotLeft, _plotTop, _plotWidth, _plotHeight);

        // Draw axes
        DrawAxes(_plotLeft, _plotTop, _plotWidth, _plotHeight);

        // Draw axis labels
        DrawAxisLabels(_plotLeft, _plotTop, _plotWidth, _plotHeight, maxValue, data);

        // Draw chart
        if (ChartStyle == 0)
        {
            DrawLineChart(data, _plotLeft, _plotTop, _plotWidth, _plotHeight, maxValue);
        }
        else
        {
            DrawBarChart(data, _plotLeft, _plotTop, _plotWidth, _plotHeight, maxValue);
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
        var pointList = new List<Point>();
        
        for (int i = 0; i < data.Count; i++)
        {
            var x = left + (width * i / (data.Count - 1));
            var y = top + height - (height * data[i].Value / maxValue);
            var point = new Point(x, y);
            points.Add(point);
            pointList.Add(point);
            
            // 存储数据点信息
            _dataPoints.Add(new PointData
            {
                DataPoint = data[i],
                Position = point,
                Index = i
            });
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
        foreach (var point in pointList)
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
            
            // 存储数据点信息（柱状图的中心位置）
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
        // 根据当前选择的指标类型使用不同的格式化方法
        var metric = SelectedMetricIndex switch
        {
            0 => StatsManager.HistoryMetric.KeyPresses,
            1 => StatsManager.HistoryMetric.Clicks,
            2 => StatsManager.HistoryMetric.MouseDistance,
            3 => StatsManager.HistoryMetric.ScrollDistance,
            _ => StatsManager.HistoryMetric.KeyPresses
        };

        return StatsManager.Instance.FormatHistoryValue(metric, value);
    }

    private void OnCanvasMouseMove(object sender, System.Windows.Input.MouseEventArgs e)
    {
        var position = e.GetPosition(ChartCanvas);
        
        // 只在实际绘图区域内检测
        if (position.X < _plotLeft || position.X > _plotLeft + _plotWidth ||
            position.Y < _plotTop || position.Y > _plotTop + _plotHeight)
        {
            HideHoverLabels();
            return;
        }
        
        // 扩大悬停区域：在数据点的横坐标或纵坐标周围都可以触发
        const double xHitDistance = 40; // X轴方向触发距离
        const double yHitDistance = 40; // Y轴方向触发距离
        
        PointData? closestPoint = null;
        double minDistance = double.MaxValue;
        
        foreach (var pointData in _dataPoints)
        {
            double distanceX = Math.Abs(pointData.Position.X - position.X);
            double distanceY = Math.Abs(pointData.Position.Y - position.Y);
            
            // 如果鼠标在X或Y坐标线附近（扩大区域），则认为悬停在此点上
            if (distanceX <= xHitDistance || distanceY <= yHitDistance)
            {
                // 计算到点的距离，选择最近的点
                double distance = Math.Sqrt(Math.Pow(distanceX, 2) + Math.Pow(distanceY, 2));
                if (distance < minDistance)
                {
                    minDistance = distance;
                    closestPoint = pointData;
                }
            }
        }

        if (closestPoint != null)
        {
            ShowHoverLabels(closestPoint);
        }
        else
        {
            HideHoverLabels();
        }
    }

    private void OnCanvasMouseLeave(object sender, System.Windows.Input.MouseEventArgs e)
    {
        HideHoverLabels();
    }

    private void ShowHoverLabels(PointData pointData)
    {
        var plotBottom = _plotTop + _plotHeight;

        // 移除旧的标签
        if (_hoverYLabel != null)
        {
            ChartCanvas.Children.Remove(_hoverYLabel);
        }
        if (_hoverXLabel != null)
        {
            ChartCanvas.Children.Remove(_hoverXLabel);
        }

        // 创建 Y 轴标签（显示数值）
        var yValueText = FormatValue(pointData.DataPoint.Value);
        _hoverYLabel = CreateLabel(yValueText, _highlightBrush, 10);
        _hoverYLabel.FontWeight = FontWeights.Bold;
        _hoverYLabel.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        Canvas.SetLeft(_hoverYLabel, _plotLeft - _hoverYLabel.DesiredSize.Width - 4);
        Canvas.SetTop(_hoverYLabel, pointData.Position.Y - _hoverYLabel.DesiredSize.Height / 2);
        ChartCanvas.Children.Add(_hoverYLabel);

        // 创建 X 轴标签（显示日期）
        var xValueText = pointData.DataPoint.Date.ToString("M/d");
        _hoverXLabel = CreateLabel(xValueText, _highlightBrush, 10);
        _hoverXLabel.FontWeight = FontWeights.Bold;
        _hoverXLabel.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        Canvas.SetLeft(_hoverXLabel, pointData.Position.X - _hoverXLabel.DesiredSize.Width / 2);
        Canvas.SetTop(_hoverXLabel, plotBottom + 4);
        ChartCanvas.Children.Add(_hoverXLabel);
    }

    private void HideHoverLabels()
    {
        if (_hoverYLabel != null)
        {
            ChartCanvas.Children.Remove(_hoverYLabel);
            _hoverYLabel = null;
        }
        if (_hoverXLabel != null)
        {
            ChartCanvas.Children.Remove(_hoverXLabel);
            _hoverXLabel = null;
        }
    }

    private class PointData
    {
        public ChartDataPoint DataPoint { get; set; } = null!;
        public Point Position { get; set; }
        public int Index { get; set; }
    }
}
