using System;
using System.Collections;
using System.Collections.Specialized;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;
using KeyStats.ViewModels;

namespace KeyStats.Views.Controls;

public partial class KeyDistributionPieChartControl : UserControl
{
    public static readonly DependencyProperty ItemsSourceProperty =
        DependencyProperty.Register(
            nameof(ItemsSource),
            typeof(IEnumerable),
            typeof(KeyDistributionPieChartControl),
            new PropertyMetadata(null, OnItemsSourceChanged));

    public IEnumerable? ItemsSource
    {
        get => (IEnumerable?)GetValue(ItemsSourceProperty);
        set => SetValue(ItemsSourceProperty, value);
    }

    public KeyDistributionPieChartControl()
    {
        InitializeComponent();
        SizeChanged += (_, _) => Draw();
        MouseLeave += OnControlMouseLeave;
    }

    private static void OnItemsSourceChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        if (d is not KeyDistributionPieChartControl control)
        {
            return;
        }

        if (e.OldValue is INotifyCollectionChanged oldCollection)
        {
            oldCollection.CollectionChanged -= control.OnCollectionChanged;
        }

        if (e.NewValue is INotifyCollectionChanged newCollection)
        {
            newCollection.CollectionChanged += control.OnCollectionChanged;
        }

        control.Draw();
    }

    private void OnCollectionChanged(object? sender, NotifyCollectionChangedEventArgs e)
    {
        Draw();
    }

    private void OnControlMouseLeave(object sender, MouseEventArgs e)
    {
        ResetCenterContent();
    }

    private void Draw()
    {
        PieCanvas.Children.Clear();
        ResetCenterContent();

        var items = ItemsSource?.Cast<KeyHistoryChartItem>()
            .Where(x => x.Count > 0 && x.SweepAngle > 0)
            .ToList();

        if (items == null || items.Count == 0)
        {
            DrawEmptyState();
            return;
        }

        var width = PieCanvas.ActualWidth;
        var height = PieCanvas.ActualHeight;
        if (width <= 0 || height <= 0)
        {
            return;
        }

        var outerRadius = Math.Max(10.0, Math.Min(width, height) / 2.0 - 8.0);
        var innerRadius = Math.Max(28.0, outerRadius * 0.42);
        var center = new Point(width / 2.0, height / 2.0);
        var separatorBrush = Application.Current?.Resources["SurfaceBrush"] as Brush ?? Brushes.White;

        CenterHole.Width = innerRadius * 2;
        CenterHole.Height = innerRadius * 2;
        CenterHole.CornerRadius = new CornerRadius(innerRadius);

        foreach (var item in items)
        {
            var shape = new Path
            {
                Fill = item.Brush,
                Stroke = separatorBrush,
                StrokeThickness = 1,
                Data = BuildRingGeometry(center, outerRadius, innerRadius, item.StartAngle, item.SweepAngle),
                Cursor = Cursors.Hand
            };
            shape.MouseEnter += (_, _) => ShowCenterContent(item);
            PieCanvas.Children.Add(shape);
        }
    }

    private void ShowCenterContent(KeyHistoryChartItem item)
    {
        CenterKeyText.Text = item.Key;
        CenterCountText.Text = string.Format(KeyStats.Properties.Strings.PieChart_CountFormat, item.CountText);
        CenterPercentText.Text = string.Format(KeyStats.Properties.Strings.PieChart_PercentFormat, item.PercentageText);
    }

    private void ResetCenterContent()
    {
        CenterKeyText.Text = string.Empty;
        CenterCountText.Text = string.Empty;
        CenterPercentText.Text = string.Empty;
    }

    private static Geometry BuildRingGeometry(Point center, double outerRadius, double innerRadius, double startAngle, double sweepAngle)
    {
        if (sweepAngle >= 359.999)
        {
            return new CombinedGeometry(
                GeometryCombineMode.Exclude,
                new EllipseGeometry(center, outerRadius, outerRadius),
                new EllipseGeometry(center, innerRadius, innerRadius));
        }

        var startRad = startAngle * Math.PI / 180.0;
        var endRad = (startAngle + sweepAngle) * Math.PI / 180.0;

        var outerStart = new Point(
            center.X + outerRadius * Math.Cos(startRad),
            center.Y + outerRadius * Math.Sin(startRad));
        var outerEnd = new Point(
            center.X + outerRadius * Math.Cos(endRad),
            center.Y + outerRadius * Math.Sin(endRad));
        var innerStart = new Point(
            center.X + innerRadius * Math.Cos(startRad),
            center.Y + innerRadius * Math.Sin(startRad));
        var innerEnd = new Point(
            center.X + innerRadius * Math.Cos(endRad),
            center.Y + innerRadius * Math.Sin(endRad));

        var largeArc = sweepAngle > 180.0;

        var figure = new PathFigure
        {
            StartPoint = outerStart,
            IsClosed = true
        };
        figure.Segments.Add(new ArcSegment(
            outerEnd,
            new Size(outerRadius, outerRadius),
            0,
            largeArc,
            SweepDirection.Clockwise,
            true));
        figure.Segments.Add(new LineSegment(innerEnd, true));
        figure.Segments.Add(new ArcSegment(
            innerStart,
            new Size(innerRadius, innerRadius),
            0,
            largeArc,
            SweepDirection.Counterclockwise,
            true));

        return new PathGeometry(new[] { figure });
    }

    private void DrawEmptyState()
    {
        CenterKeyText.Text = KeyStats.Properties.Strings.PieChart_Empty;
        CenterCountText.Text = string.Empty;
        CenterPercentText.Text = string.Empty;

        var text = new TextBlock
        {
            Text = KeyStats.Properties.Strings.PieChart_Empty,
            FontSize = 12,
            Foreground = Application.Current?.Resources["TextSecondaryBrush"] as Brush ?? Brushes.Gray
        };
        text.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        Canvas.SetLeft(text, (Math.Max(0, PieCanvas.ActualWidth - text.DesiredSize.Width)) / 2);
        Canvas.SetTop(text, (Math.Max(0, PieCanvas.ActualHeight - text.DesiredSize.Height)) / 2);
        PieCanvas.Children.Add(text);
    }
}
