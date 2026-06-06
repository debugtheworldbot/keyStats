using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Windows;
using System.Windows.Media;
using KeyStats.Helpers;

namespace KeyStats.Views.Controls;

public class KeyboardHeatmapControl : FrameworkElement
{
    private sealed class KeySpec
    {
        public string Id { get; }
        public string Label { get; }
        public Rect FrameUnits { get; }

        public KeySpec(string id, string label, Rect frameUnits)
        {
            Id = id;
            Label = label;
            FrameUnits = frameUnits;
        }
    }

    private sealed class RenderMetrics
    {
        public double Scale { get; }
        public Point Origin { get; }

        public RenderMetrics(double scale, Point origin)
        {
            Scale = scale;
            Origin = origin;
        }
    }

    private const double LayoutInset = 8;

    private static readonly HashSet<string> NumberKeyIds = new(Enumerable.Range(0, 10).Select(i => i.ToString(CultureInfo.InvariantCulture)));
    private static readonly IReadOnlyList<KeySpec> Layout = BuildLayout();
    private static readonly Rect LayoutBounds = ComputeLayoutBounds(Layout);

    public static readonly HashSet<string> SupportedKeyIds = new(Layout.Select(item => item.Id), StringComparer.Ordinal);

    private Dictionary<string, int> _keyCounts = new(StringComparer.Ordinal);
    private int _maxCount;

    public KeyboardHeatmapControl()
    {
        SnapsToDevicePixels = true;
        UseLayoutRounding = true;
        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
    }

    public void Apply(IDictionary<string, int>? keyCounts)
    {
        _keyCounts = keyCounts == null
            ? new Dictionary<string, int>(StringComparer.Ordinal)
            : keyCounts.ToDictionary(kvp => kvp.Key, kvp => Math.Max(0, kvp.Value), StringComparer.Ordinal);
        _maxCount = _keyCounts.Count == 0 ? 0 : _keyCounts.Values.Max();
        InvalidateVisual();
    }

    protected override void OnRender(DrawingContext drawingContext)
    {
        base.OnRender(drawingContext);

        var metrics = ComputeRenderMetrics();
        if (metrics == null)
        {
            return;
        }

        var isDarkMode = ThemeManager.Instance.IsDarkTheme;
        var defaultTextColor = isDarkMode ? Colors.White : ResolveColor("TextPrimaryBrush", Colors.Black);
        var textBrush = CreateBrush(defaultTextColor);
        var borderColor = isDarkMode
            ? Color.FromArgb(36, 255, 255, 255)
            : Color.FromArgb(23, 0, 0, 0);
        var borderPen = new Pen(CreateBrush(borderColor), 0.8);
        borderPen.Freeze();

        foreach (var key in Layout)
        {
            var frame = KeyFrame(key, metrics);
            var count = _keyCounts.TryGetValue(key.Id, out var value) ? value : 0;
            var fillColor = ColorForCount(count, isDarkMode);
            var radius = Math.Max(4, metrics.Scale * 0.14);

            drawingContext.DrawRoundedRectangle(CreateBrush(fillColor), borderPen, frame, radius, radius);
            DrawKeyLegend(drawingContext, key, frame, metrics.Scale, textBrush, defaultTextColor);
            DrawCountBadge(drawingContext, count, frame, metrics.Scale, isDarkMode);
        }
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        ThemeManager.Instance.ThemeChanged += OnThemeChanged;
    }

    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        ThemeManager.Instance.ThemeChanged -= OnThemeChanged;
    }

    private void OnThemeChanged()
    {
        Dispatcher.BeginInvoke(new Action(InvalidateVisual));
    }

    private RenderMetrics? ComputeRenderMetrics()
    {
        if (Layout.Count == 0 || ActualWidth <= 0 || ActualHeight <= 0)
        {
            return null;
        }

        var available = new Rect(
            LayoutInset,
            LayoutInset,
            Math.Max(0, ActualWidth - LayoutInset * 2),
            Math.Max(0, ActualHeight - LayoutInset * 2));
        if (available.Width <= 0 || available.Height <= 0)
        {
            return null;
        }

        var scaleX = available.Width / LayoutBounds.Width;
        var scaleY = available.Height / LayoutBounds.Height;
        var scale = Math.Min(scaleX, scaleY);
        var width = LayoutBounds.Width * scale;
        var height = LayoutBounds.Height * scale;
        var origin = new Point(
            available.Left + (available.Width - width) / 2 - LayoutBounds.X * scale,
            available.Top + (available.Height - height) / 2 - LayoutBounds.Y * scale);

        return new RenderMetrics(scale, origin);
    }

    private static Rect KeyFrame(KeySpec key, RenderMetrics metrics)
    {
        return new Rect(
            metrics.Origin.X + key.FrameUnits.X * metrics.Scale,
            metrics.Origin.Y + key.FrameUnits.Y * metrics.Scale,
            key.FrameUnits.Width * metrics.Scale,
            key.FrameUnits.Height * metrics.Scale);
    }

    private void DrawKeyLegend(DrawingContext drawingContext, KeySpec key, Rect frame, double scale, Brush textBrush, Color textColor)
    {
        if (string.IsNullOrEmpty(key.Label))
        {
            return;
        }

        if (key.Label.Contains('\n'))
        {
            DrawDualLineLegend(drawingContext, key, frame, scale, textColor);
            return;
        }

        var fontSize = Math.Max(9, Math.Min(13, scale * 0.28));
        var text = CreateText(key.Label, fontSize, FontWeights.Medium, textBrush, "Segoe UI");

        var horizontalInset = Math.Max(4, scale * 0.16);
        var verticalInset = Math.Max(3, scale * 0.14);
        var point = new Point(
            frame.Right - text.Width - horizontalInset,
            frame.Bottom - text.Height - verticalInset);

        drawingContext.DrawText(text, point);
    }

    private void DrawDualLineLegend(DrawingContext drawingContext, KeySpec key, Rect frame, double scale, Color textColor)
    {
        var parts = key.Label.Split(new[] { '\n' }, 2, StringSplitOptions.None);
        if (parts.Length != 2)
        {
            return;
        }

        var upper = parts[0];
        var lower = parts[1];

        var upperColor = Color.FromArgb(
            (byte)Math.Round(255 * 0.84),
            textColor.R,
            textColor.G,
            textColor.B);
        var upperBrush = CreateBrush(upperColor);
        var lowerBrush = CreateBrush(textColor);

        var upperSize = Math.Max(8, Math.Min(11, scale * 0.23));
        var lowerSize = Math.Max(9.5, Math.Min(13, scale * 0.28));
        var upperText = CreateText(upper, upperSize, FontWeights.Regular, upperBrush, "Segoe UI");
        var lowerText = CreateText(lower, lowerSize, FontWeights.Medium, lowerBrush, "Segoe UI");

        var horizontalInset = Math.Max(4, scale * 0.16);
        var bottomInset = Math.Max(2.5, scale * 0.11);
        var lineSpacing = Math.Max(1.5, scale * 0.05);

        var lowerPoint = new Point(
            frame.Right - lowerText.Width - horizontalInset,
            frame.Bottom - lowerText.Height - bottomInset);

        if (NumberKeyIds.Contains(key.Id))
        {
            drawingContext.DrawText(lowerText, lowerPoint);
            return;
        }

        var upperPoint = new Point(
            frame.Right - upperText.Width - horizontalInset,
            Math.Max(frame.Top + 2, lowerPoint.Y - upperText.Height - lineSpacing));

        drawingContext.DrawText(upperText, upperPoint);
        drawingContext.DrawText(lowerText, lowerPoint);
    }

    private void DrawCountBadge(DrawingContext drawingContext, int count, Rect frame, double scale, bool isDarkMode)
    {
        if (count <= 0)
        {
            return;
        }

        var inset = Math.Max(3, scale * 0.08);
        var horizontalPadding = Math.Max(4, scale * 0.10);
        var verticalPadding = Math.Max(1.5, scale * 0.05);
        var maxBadgeWidth = Math.Max(14, frame.Width - inset * 2);
        if (maxBadgeWidth <= 10)
        {
            return;
        }

        var textColor = isDarkMode
            ? Color.FromArgb((byte)Math.Round(255 * 0.95), 255, 255, 255)
            : Color.FromArgb((byte)Math.Round(255 * 0.95), 31, 31, 31);
        var brush = CreateBrush(textColor);

        var fontSize = Math.Max(7, Math.Min(10.5, scale * 0.20));
        var text = count.ToString("N0", CultureInfo.CurrentCulture);
        var formatted = CreateText(text, fontSize, FontWeights.SemiBold, brush, "Consolas");

        var fullWidth = formatted.Width + horizontalPadding * 2;
        if (fullWidth > maxBadgeWidth)
        {
            text = CompactCountText(count);
            formatted = CreateText(text, fontSize, FontWeights.SemiBold, brush, "Consolas");
        }

        var badgeHeight = Math.Max(Math.Max(12, scale * 0.30), formatted.Height + verticalPadding * 2);
        var badgeWidth = Math.Max(badgeHeight, formatted.Width + horizontalPadding * 2);
        if (badgeWidth > maxBadgeWidth)
        {
            badgeWidth = maxBadgeWidth;
            text = CompactCountText(count, 3);
            formatted = CreateText(text, fontSize, FontWeights.SemiBold, brush, "Consolas");
        }

        var badgeRect = new Rect(
            frame.Left + inset,
            frame.Top + inset,
            badgeWidth,
            badgeHeight);

        var background = isDarkMode
            ? Color.FromArgb((byte)Math.Round(255 * 0.38), 0, 0, 0)
            : Color.FromArgb((byte)Math.Round(255 * 0.84), 255, 255, 255);
        var border = isDarkMode
            ? Color.FromArgb((byte)Math.Round(255 * 0.22), 255, 255, 255)
            : Color.FromArgb((byte)Math.Round(255 * 0.14), 0, 0, 0);

        var radius = badgeHeight * 0.5;
        drawingContext.DrawRoundedRectangle(CreateBrush(background), new Pen(CreateBrush(border), 0.7), badgeRect, radius, radius);

        var textPoint = new Point(
            badgeRect.Left + (badgeRect.Width - formatted.Width) / 2,
            badgeRect.Top + (badgeRect.Height - formatted.Height) / 2);
        drawingContext.DrawText(formatted, textPoint);
    }

    private string CompactCountText(int count, int maximumLength = 4)
    {
        string compact;
        if (count >= 1_000_000_000)
        {
            compact = CompactUnit(count / 1_000_000_000.0, "B");
        }
        else if (count >= 1_000_000)
        {
            compact = CompactUnit(count / 1_000_000.0, "M");
        }
        else if (count >= 1_000)
        {
            compact = CompactUnit(count / 1_000.0, "K");
        }
        else
        {
            compact = count.ToString(CultureInfo.InvariantCulture);
        }

        if (compact.Length <= maximumLength)
        {
            return compact;
        }

        if (count >= 1_000_000_000)
        {
            return $"{Math.Round(count / 1_000_000_000.0, MidpointRounding.AwayFromZero):0}B";
        }
        if (count >= 1_000_000)
        {
            return $"{Math.Round(count / 1_000_000.0, MidpointRounding.AwayFromZero):0}M";
        }
        if (count >= 1_000)
        {
            return $"{Math.Round(count / 1_000.0, MidpointRounding.AwayFromZero):0}K";
        }
        return compact;
    }

    private static string CompactUnit(double value, string suffix)
    {
        var rounded = Math.Round(value * 10.0, MidpointRounding.AwayFromZero) / 10.0;
        var numberText = Math.Abs(Math.Round(rounded) - rounded) < 0.05
            ? Math.Round(rounded).ToString("0", CultureInfo.InvariantCulture)
            : rounded.ToString("0.0", CultureInfo.InvariantCulture);
        return numberText + suffix;
    }

    private Color ColorForCount(int count, bool isDarkMode)
    {
        var surface = ResolveColor("SurfaceBrush", isDarkMode ? Color.FromRgb(32, 32, 32) : Color.FromRgb(250, 250, 250));
        var divider = ResolveColor("DividerBrush", isDarkMode ? Color.FromRgb(61, 61, 61) : Color.FromRgb(229, 229, 229));
        var neutral = Blend(surface, divider, isDarkMode ? 0.22 : 0.10);

        if (count <= 0)
        {
            return neutral;
        }

        var normalized = _maxCount > 0
            ? Math.Log(count + 1.0) / Math.Log(_maxCount + 1.0)
            : 0;
        var eased = Math.Pow(normalized, 0.82);

        var accent = ResolveColor("AccentBrush", isDarkMode ? Color.FromRgb(0, 120, 212) : Color.FromRgb(0, 103, 192));
        var low = Blend(neutral, accent, isDarkMode ? 0.34 : 0.24);
        var high = Blend(accent, isDarkMode ? Colors.White : Colors.Black, isDarkMode ? 0.18 : 0.10);

        return Blend(low, high, eased);
    }

    private static Color ResolveColor(string key, Color fallback)
    {
        var resource = Application.Current?.Resources[key];
        if (resource is SolidColorBrush brush)
        {
            return brush.Color;
        }
        if (resource is Color color)
        {
            return color;
        }
        return fallback;
    }

    private static Color Blend(Color from, Color to, double t)
    {
        var progress = Math.Max(0, Math.Min(1, t));
        return Color.FromArgb(
            (byte)Math.Round(from.A + (to.A - from.A) * progress),
            (byte)Math.Round(from.R + (to.R - from.R) * progress),
            (byte)Math.Round(from.G + (to.G - from.G) * progress),
            (byte)Math.Round(from.B + (to.B - from.B) * progress));
    }

    private static SolidColorBrush CreateBrush(Color color)
    {
        var brush = new SolidColorBrush(color);
        brush.Freeze();
        return brush;
    }

    private FormattedText CreateText(string value, double fontSize, FontWeight weight, Brush brush, string fontFamily)
    {
        var typeface = new Typeface(new FontFamily(fontFamily), FontStyles.Normal, weight, FontStretches.Normal);
        return new FormattedText(
            value,
            CultureInfo.CurrentUICulture,
            FlowDirection.LeftToRight,
            typeface,
            fontSize,
            brush,
            VisualTreeHelper.GetDpi(this).PixelsPerDip);
    }

    private static Rect ComputeLayoutBounds(IReadOnlyList<KeySpec> keys)
    {
        if (keys.Count == 0)
        {
            return Rect.Empty;
        }

        var left = keys.Min(item => item.FrameUnits.Left);
        var top = keys.Min(item => item.FrameUnits.Top);
        var right = keys.Max(item => item.FrameUnits.Right);
        var bottom = keys.Max(item => item.FrameUnits.Bottom);
        return new Rect(left, top, right - left, bottom - top);
    }

    private static IReadOnlyList<KeySpec> BuildLayout()
    {
        const double keyGap = 0.15;
        const double rowGap = keyGap;
        var rowStep = 1.0 + rowGap;
        var functionClusterGap = keyGap;
        var backspaceWidth = 2.38 - keyGap;
        var backslashWidth = 1.93 - keyGap;
        var rightShiftWidth = 2.93 + keyGap;

        var items = new List<KeySpec>();

        void AppendRow(double y, double startX, IEnumerable<(string id, string label, double width)> keys)
        {
            var x = startX;
            foreach (var key in keys)
            {
                items.Add(new KeySpec(key.id, key.label, new Rect(x, y, key.width, 1.0)));
                x += key.width + keyGap;
            }
        }

        var functionKeys = new[] { "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12" };
        var numberRowWidths = Enumerable.Repeat(1.0, 13).Concat(new[] { backspaceWidth }).ToArray();
        var keyboardRightEdge = numberRowWidths.Sum() + (numberRowWidths.Length - 1) * keyGap;

        var yFunction = 0.0;
        var xFunction = 0.0;
        var escWidth = 1.45;
        var functionGapTotal = functionClusterGap + (functionKeys.Length - 1) * keyGap;
        var functionKeyWidth = (keyboardRightEdge - escWidth - functionGapTotal) / functionKeys.Length;

        items.Add(new KeySpec("Esc", "esc", new Rect(xFunction, yFunction, escWidth, 1.0)));
        xFunction += escWidth + functionClusterGap;
        foreach (var key in functionKeys)
        {
            items.Add(new KeySpec(key, key, new Rect(xFunction, yFunction, functionKeyWidth, 1.0)));
            xFunction += functionKeyWidth + keyGap;
        }

        var y1 = rowStep;
        AppendRow(y1, 0, new[]
        {
            ("`", "~\n`", 1.0), ("1", "!\n1", 1.0), ("2", "@\n2", 1.0), ("3", "#\n3", 1.0), ("4", "$\n4", 1.0),
            ("5", "%\n5", 1.0), ("6", "^\n6", 1.0), ("7", "&\n7", 1.0), ("8", "*\n8", 1.0), ("9", "(\n9", 1.0),
            ("0", ")\n0", 1.0), ("-", "_\n-", 1.0), ("=", "+\n=", 1.0), ("Backspace", "backspace", backspaceWidth)
        });

        var y2 = y1 + rowStep;
        AppendRow(y2, 0, new[]
        {
            ("Tab", "tab", 1.45), ("Q", "Q", 1.0), ("W", "W", 1.0), ("E", "E", 1.0), ("R", "R", 1.0),
            ("T", "T", 1.0), ("Y", "Y", 1.0), ("U", "U", 1.0), ("I", "I", 1.0), ("O", "O", 1.0),
            ("P", "P", 1.0), ("[", "{\n[", 1.0), ("]", "}\n]", 1.0), ("\\", "|\n\\", backslashWidth)
        });

        var y3 = y2 + rowStep;
        AppendRow(y3, 0, new[]
        {
            ("CapsLock", "caps lock", 1.8), ("A", "A", 1.0), ("S", "S", 1.0), ("D", "D", 1.0), ("F", "F", 1.0),
            ("G", "G", 1.0), ("H", "H", 1.0), ("J", "J", 1.0), ("K", "K", 1.0), ("L", "L", 1.0),
            (";", ":\n;", 1.0), ("'", "\"\n'", 1.0), ("Return", "return", 2.58)
        });

        var y4 = y3 + rowStep;
        AppendRow(y4, 0, new[]
        {
            ("Shift", "shift", 2.45), ("Z", "Z", 1.0), ("X", "X", 1.0), ("C", "C", 1.0), ("V", "V", 1.0),
            ("B", "B", 1.0), ("N", "N", 1.0), ("M", "M", 1.0), (",", "<\n,", 1.0), (".", ">\n.", 1.0),
            ("/", "?\n/", 1.0), ("Shift", "shift", rightShiftWidth)
        });

        var y5 = y4 + rowStep;
        var bottomX = 0.0;
        var leftCtrlWidth = 1.35;
        var leftWinWidth = 1.3;
        var leftAltWidth = 1.3;
        var rightAltWidth = 1.3;
        var rightWinWidth = 1.3;
        var rightCtrlWidth = 2.0;
        var bottomNonSpaceWidth = leftCtrlWidth + leftWinWidth + leftAltWidth + rightAltWidth + rightWinWidth + rightCtrlWidth;
        var bottomGapCount = 6; // 7 keys on this row => 6 gaps
        var spaceWidth = Math.Max(3.8, keyboardRightEdge - bottomNonSpaceWidth - bottomGapCount * keyGap);
        var bottomKeys = new[]
        {
            ("LCtrl", "ctrl", leftCtrlWidth), ("LWin", "win", leftWinWidth), ("LAlt", "alt", leftAltWidth),
            ("Space", "space", spaceWidth), ("RAlt", "alt", rightAltWidth), ("RWin", "win", rightWinWidth),
            ("RCtrl", "ctrl", rightCtrlWidth)
        };
        foreach (var key in bottomKeys)
        {
            items.Add(new KeySpec(key.Item1, key.Item2, new Rect(bottomX, y5, key.Item3, 1.0)));
            bottomX += key.Item3 + keyGap;
        }

        var navKeyWidth = 1.0;
        var navRowGap = rowGap;
        var navStepX = navKeyWidth + keyGap;
        var navColumnGap = 0.55;
        var navStartX = keyboardRightEdge + navColumnGap;
        var yNavTop = y1;
        var yNavBottom = y1 + 1.0 + navRowGap;

        items.Add(new KeySpec("PrintScreen", "prt\nsc", new Rect(navStartX, yFunction, navKeyWidth, 1.0)));
        items.Add(new KeySpec("ScrollLock", "scroll\nlock", new Rect(navStartX + navStepX, yFunction, navKeyWidth, 1.0)));
        items.Add(new KeySpec("Pause", "pause", new Rect(navStartX + navStepX * 2, yFunction, navKeyWidth, 1.0)));

        items.Add(new KeySpec("Insert", "ins", new Rect(navStartX, yNavTop, navKeyWidth, 1.0)));
        items.Add(new KeySpec("Home", "home", new Rect(navStartX + navStepX, yNavTop, navKeyWidth, 1.0)));
        items.Add(new KeySpec("PageUp", "pg up", new Rect(navStartX + navStepX * 2, yNavTop, navKeyWidth, 1.0)));
        items.Add(new KeySpec("Delete", "del", new Rect(navStartX, yNavBottom, navKeyWidth, 1.0)));
        items.Add(new KeySpec("End", "end", new Rect(navStartX + navStepX, yNavBottom, navKeyWidth, 1.0)));
        items.Add(new KeySpec("PageDown", "pg dn", new Rect(navStartX + navStepX * 2, yNavBottom, navKeyWidth, 1.0)));

        var arrowWidth = 1.0;
        var arrowStep = arrowWidth + keyGap;
        var arrowStartX = navStartX;
        var yArrowTop = y4;
        var yArrowBottom = y5;
        items.Add(new KeySpec("Up", "up", new Rect(arrowStartX + arrowStep, yArrowTop, arrowWidth, 1.0)));
        items.Add(new KeySpec("Left", "left", new Rect(arrowStartX, yArrowBottom, arrowWidth, 1.0)));
        items.Add(new KeySpec("Down", "down", new Rect(arrowStartX + arrowStep, yArrowBottom, arrowWidth, 1.0)));
        items.Add(new KeySpec("Right", "right", new Rect(arrowStartX + arrowStep * 2, yArrowBottom, arrowWidth, 1.0)));

        var numpadGap = 0.55;
        var numStartX = navStartX + navStepX * 3 + numpadGap;
        var numKeyWidth = 1.0;
        var numStep = numKeyWidth + keyGap;
        var tallKeyHeight = 2.0 + rowGap;
        var wideKeyWidth = 2.0 + keyGap;

        items.Add(new KeySpec("NumLock", "num\nlock", new Rect(numStartX, y1, numKeyWidth, 1.0)));
        items.Add(new KeySpec("Num/", "/", new Rect(numStartX + numStep, y1, numKeyWidth, 1.0)));
        items.Add(new KeySpec("Num*", "*", new Rect(numStartX + numStep * 2, y1, numKeyWidth, 1.0)));
        items.Add(new KeySpec("Num-", "-", new Rect(numStartX + numStep * 3, y1, numKeyWidth, 1.0)));

        items.Add(new KeySpec("Num7", "7", new Rect(numStartX, y2, numKeyWidth, 1.0)));
        items.Add(new KeySpec("Num8", "8", new Rect(numStartX + numStep, y2, numKeyWidth, 1.0)));
        items.Add(new KeySpec("Num9", "9", new Rect(numStartX + numStep * 2, y2, numKeyWidth, 1.0)));
        items.Add(new KeySpec("Num+", "+", new Rect(numStartX + numStep * 3, y2, numKeyWidth, tallKeyHeight)));

        items.Add(new KeySpec("Num4", "4", new Rect(numStartX, y3, numKeyWidth, 1.0)));
        items.Add(new KeySpec("Num5", "5", new Rect(numStartX + numStep, y3, numKeyWidth, 1.0)));
        items.Add(new KeySpec("Num6", "6", new Rect(numStartX + numStep * 2, y3, numKeyWidth, 1.0)));

        items.Add(new KeySpec("Num1", "1", new Rect(numStartX, y4, numKeyWidth, 1.0)));
        items.Add(new KeySpec("Num2", "2", new Rect(numStartX + numStep, y4, numKeyWidth, 1.0)));
        items.Add(new KeySpec("Num3", "3", new Rect(numStartX + numStep * 2, y4, numKeyWidth, 1.0)));
        items.Add(new KeySpec("NumEnter", "enter", new Rect(numStartX + numStep * 3, y4, numKeyWidth, tallKeyHeight)));

        items.Add(new KeySpec("Num0", "0", new Rect(numStartX, y5, wideKeyWidth, 1.0)));
        items.Add(new KeySpec("Num.", ".", new Rect(numStartX + numStep * 2, y5, numKeyWidth, 1.0)));

        return items;
    }
}
