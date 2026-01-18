using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using DrawingColor = System.Drawing.Color;
using DrawingPen = System.Drawing.Pen;
using DrawingRectangle = System.Drawing.Rectangle;
using DrawingSolidBrush = System.Drawing.SolidBrush;
using PixelFormat = System.Drawing.Imaging.PixelFormat;

namespace KeyStats.Helpers;

public static class IconGenerator
{
    private const string TrayFontFamily = "Segoe UI";
    private const float TrayFontScale = 2.2f; // 增大到 2.2，使字号更大
    private const float TrayTextPaddingRatio = 0.08f;
    private const float TrayLineSpacingRatio = 0.04f;

    /// <summary>
    /// Creates a tray icon with two lines of stats (keys on top, clicks on bottom)
    /// </summary>
    public static Icon CreateTrayIcon(DrawingColor? tintColor = null, string? keysText = null, string? clicksText = null)
    {
        // Get system tray icon size based on DPI
        int size = GetSystemTrayIconSize();

        using var bitmap = new Bitmap(size, size, PixelFormat.Format32bppArgb);
        using var g = Graphics.FromImage(bitmap);

        // 清除背景为完全透明
        g.Clear(DrawingColor.Transparent);

        g.SmoothingMode = SmoothingMode.HighQuality;
        g.InterpolationMode = InterpolationMode.HighQualityBicubic;
        g.PixelOffsetMode = PixelOffsetMode.Half; // 使用 Half 确保文字对齐到像素边界，提高清晰�?
        // 使用 AntiAlias 而不是 ClearType，因为 ClearType 在透明背景上效果不佳，颜色覆盖不完整
        g.TextRenderingHint = TextRenderingHint.AntiAlias;
        g.CompositingQuality = CompositingQuality.HighQuality;
        // 使用 SourceOver 合成模式，确保颜色完全覆盖
        g.CompositingMode = CompositingMode.SourceOver;

        var iconColor = tintColor ?? DrawingColor.Black;

        bool hasKeys = !string.IsNullOrEmpty(keysText);
        bool hasClicks = !string.IsNullOrEmpty(clicksText);

        if (hasKeys || hasClicks)
        {
            DrawTwoLineStats(g, keysText, clicksText, iconColor, size);
        }
        else
        {
            DrawKeyboardIconScaled(g, iconColor, size);
        }

        // Convert to icon
        var iconHandle = bitmap.GetHicon();
        var icon = Icon.FromHandle(iconHandle);
        // Clone the icon before destroying the handle - Icon.FromHandle wraps the handle
        // without copying, so we must clone first to get an independent copy
        var clonedIcon = (Icon)icon.Clone();
        NativeInterop.DestroyIcon(iconHandle);
        return clonedIcon;
    }

    private static int GetSystemTrayIconSize()
    {
        // Get DPI scale factor
        using var screen = Graphics.FromHwnd(IntPtr.Zero);
        var dpiX = screen.DpiX;

        // Base size is 16 at 96 DPI (100%)
        // Scale proportionally: 16 * (dpi / 96)
        int size = (int)(16 * dpiX / 96);

        // Clamp to reasonable sizes and round to common icon sizes
        if (size <= 16) return 16;
        if (size <= 20) return 20;
        if (size <= 24) return 24;
        if (size <= 32) return 32;
        if (size <= 48) return 48;
        return 64;
    }

    private static void DrawTwoLineStats(Graphics g, string? keysText, string? clicksText, DrawingColor color, int size)
    {
        using var brush = new DrawingSolidBrush(color);

        var keysDisplay = !string.IsNullOrEmpty(keysText) ? FormatIconNumber(keysText) : "";
        var clicksDisplay = !string.IsNullOrEmpty(clicksText) ? FormatIconNumber(clicksText) : "";

        if (string.IsNullOrEmpty(keysDisplay) && string.IsNullOrEmpty(clicksDisplay))
        {
            return;
        }

        float scale = size / 32f;
        var maxLen = Math.Max(keysDisplay.Length, clicksDisplay.Length);

        float baseFontSize = maxLen switch
        {
            1 => 30f,  // 增大字号
            2 => 28f,  // 增大字号
            3 => 26f,  // 增大字号
            _ => 24f   // 增大字号
        };

        float fontSize = baseFontSize * scale * TrayFontScale;
        float padding = MathF.Max(1f, size * TrayTextPaddingRatio);
        float lineSpacing = MathF.Max(0f, size * TrayLineSpacingRatio);

        using var format = (StringFormat)StringFormat.GenericTypographic.Clone();
        format.FormatFlags |= StringFormatFlags.NoWrap;
        format.Trimming = StringTrimming.None;

        using var measureFont = new Font(TrayFontFamily, fontSize, FontStyle.Regular, GraphicsUnit.Pixel);
        var lineCount = 0;
        var maxTextWidth = 0f;
        if (!string.IsNullOrEmpty(keysDisplay))
        {
            lineCount++;
            maxTextWidth = MathF.Max(maxTextWidth, g.MeasureString(keysDisplay, measureFont, int.MaxValue, format).Width);
        }
        if (!string.IsNullOrEmpty(clicksDisplay))
        {
            lineCount++;
            maxTextWidth = MathF.Max(maxTextWidth, g.MeasureString(clicksDisplay, measureFont, int.MaxValue, format).Width);
        }

        float lineHeight = measureFont.GetHeight(g);
        float totalHeight = (lineHeight * lineCount) + (lineSpacing * Math.Max(0, lineCount - 1));
        float maxWidth = size - (padding * 2f);

        float fitScale = 1f;
        if (maxTextWidth > maxWidth && maxTextWidth > 0f)
        {
            fitScale = MathF.Min(fitScale, maxWidth / maxTextWidth);
        }
        if (fitScale < 1f)
        {
            fontSize *= fitScale;
        }

        using var font = new Font(TrayFontFamily, fontSize, FontStyle.Regular, GraphicsUnit.Pixel);
        lineHeight = font.GetHeight(g);
        totalHeight = (lineHeight * lineCount) + (lineSpacing * Math.Max(0, lineCount - 1));
        var startY = AlignToPixel((size - totalHeight) / 2f);

        if (!string.IsNullOrEmpty(keysDisplay))
        {
            var textWidth = g.MeasureString(keysDisplay, font, int.MaxValue, format).Width;
            var x = AlignToPixel((size - textWidth) / 2f);
            var y = AlignToPixel(startY);
            g.DrawString(keysDisplay, font, brush, x, y, format);
            startY += lineHeight + lineSpacing;
        }

        if (!string.IsNullOrEmpty(clicksDisplay))
        {
            var textWidth = g.MeasureString(clicksDisplay, font, int.MaxValue, format).Width;
            var x = AlignToPixel((size - textWidth) / 2f);
            var y = AlignToPixel(startY);
            g.DrawString(clicksDisplay, font, brush, x, y, format);
        }
    }

    private static void DrawKeyboardIconScaled(Graphics g, DrawingColor color, int size)
    {
        float scale = size / 16f;

        using var pen = new DrawingPen(color, 1.5f * scale);
        using var brush = new DrawingSolidBrush(color);

        // Draw keyboard outline
        var keyboardRect = new RectangleF(1 * scale, 4 * scale, 14 * scale, 9 * scale);
        g.DrawRoundedRectangle(pen, keyboardRect, 1.5f * scale);

        // Draw keys (3x2 grid)
        for (int row = 0; row < 2; row++)
        {
            for (int col = 0; col < 3; col++)
            {
                var keyRect = new RectangleF(
                    (3 + col * 4) * scale,
                    (6 + row * 3) * scale,
                    2.5f * scale,
                    2f * scale
                );
                g.FillRectangle(brush, keyRect);
            }
        }
    }

    private static string FormatIconNumber(string text)
    {
        // Try to parse and format the number compactly
        if (int.TryParse(text.Replace(",", "").Replace(".", ""), out int num))
        {
            if (num >= 1_000_000)
                return $"{num / 1_000_000.0:F2}M";
            if (num >= 1_000)
                return $"{num / 1_000.0:F2}k";
            return num.ToString();
        }
        return text.Length > 4 ? text[..4] : text;
    }

    private static void DrawKeyboardIcon(Graphics g, DrawingColor color)
    {
        using var pen = new DrawingPen(color, 1.5f);
        using var brush = new DrawingSolidBrush(color);

        // Draw keyboard outline
        var keyboardRect = new RectangleF(1, 4, 14, 9);
        g.DrawRoundedRectangle(pen, keyboardRect, 1.5f);

        // Draw keys (3x2 grid)
        for (int row = 0; row < 2; row++)
        {
            for (int col = 0; col < 3; col++)
            {
                var keyRect = new RectangleF(
                    3 + col * 4,
                    6 + row * 3,
                    2.5f,
                    2f
                );
                g.FillRectangle(brush, keyRect);
            }
        }
    }

    private static void DrawKeyboardIcon32(Graphics g, DrawingColor color)
    {
        using var pen = new DrawingPen(color, 2.5f);
        using var brush = new DrawingSolidBrush(color);

        // Draw keyboard outline (scaled for 32x32)
        var keyboardRect = new RectangleF(2, 8, 28, 18);
        g.DrawRoundedRectangle(pen, keyboardRect, 3f);

        // Draw keys (3x2 grid)
        for (int row = 0; row < 2; row++)
        {
            for (int col = 0; col < 3; col++)
            {
                var keyRect = new RectangleF(
                    6 + col * 8,
                    12 + row * 6,
                    5f,
                    4f
                );
                g.FillRectangle(brush, keyRect);
            }
        }
    }

    public static Icon CreateTrayIconKeyboard(DrawingColor? tintColor = null)
    {
        return CreateTrayIcon(tintColor, null);
    }

    public static ImageSource CreateTrayIconImageSource(DrawingColor? tintColor = null)
    {
        using var icon = CreateTrayIcon(tintColor);
        using var bitmap = icon.ToBitmap();
        return BitmapToImageSource(bitmap);
    }

    public static ImageSource BitmapToImageSource(Bitmap bitmap)
    {
        var bitmapData = bitmap.LockBits(
            new DrawingRectangle(0, 0, bitmap.Width, bitmap.Height),
            System.Drawing.Imaging.ImageLockMode.ReadOnly,
            bitmap.PixelFormat);

        var bitmapSource = BitmapSource.Create(
            bitmapData.Width, bitmapData.Height,
            bitmap.HorizontalResolution, bitmap.VerticalResolution,
            PixelFormats.Bgra32, null,
            bitmapData.Scan0, bitmapData.Stride * bitmapData.Height, bitmapData.Stride);

        bitmap.UnlockBits(bitmapData);
        bitmapSource.Freeze();
        return bitmapSource;
    }

    private static void DrawRoundedRectangle(this Graphics g, DrawingPen pen, RectangleF rect, float radius)
    {
        using var path = CreateRoundedRectanglePath(rect, radius);
        g.DrawPath(pen, path);
    }

    private static GraphicsPath CreateRoundedRectanglePath(RectangleF rect, float radius)
    {
        var path = new GraphicsPath();
        var diameter = radius * 2;

        path.AddArc(rect.X, rect.Y, diameter, diameter, 180, 90);
        path.AddArc(rect.Right - diameter, rect.Y, diameter, diameter, 270, 90);
        path.AddArc(rect.Right - diameter, rect.Bottom - diameter, diameter, diameter, 0, 90);
        path.AddArc(rect.X, rect.Bottom - diameter, diameter, diameter, 90, 90);
        path.CloseFigure();

        return path;
    }

    public static DrawingColor GetRateColor(double ratePerSecond)
    {
        var apm = ratePerSecond * 60;
        double[] thresholds = { 0, 80, 160, 240 };

        if (apm < thresholds[1])
        {
            return DrawingColor.Empty;
        }

        if (apm >= thresholds[3])
        {
            return DrawingColor.FromArgb(255, 59, 48); // System red
        }

        if (apm <= thresholds[2])
        {
            var progress = (apm - thresholds[1]) / (thresholds[2] - thresholds[1]);
            var lightGreen = LightenColor(DrawingColor.FromArgb(52, 199, 89), 0.6); // System green
            return InterpolateColor(lightGreen, DrawingColor.FromArgb(52, 199, 89), progress);
        }

        var progressYellowToRed = (apm - thresholds[2]) / (thresholds[3] - thresholds[2]);
        return InterpolateColor(DrawingColor.FromArgb(255, 204, 0), DrawingColor.FromArgb(255, 59, 48), progressYellowToRed);
    }

    private static DrawingColor InterpolateColor(DrawingColor from, DrawingColor to, double progress)
    {
        progress = Math.Clamp(progress, 0, 1);
        return DrawingColor.FromArgb(
            (int)(from.A + (to.A - from.A) * progress),
            (int)(from.R + (to.R - from.R) * progress),
            (int)(from.G + (to.G - from.G) * progress),
            (int)(from.B + (to.B - from.B) * progress)
        );
    }

    private static DrawingColor LightenColor(DrawingColor color, double fraction)
    {
        fraction = Math.Clamp(fraction, 0, 1);
        return DrawingColor.FromArgb(
            color.A,
            (int)(color.R + (255 - color.R) * fraction),
            (int)(color.G + (255 - color.G) * fraction),
            (int)(color.B + (255 - color.B) * fraction)
        );
    }

    private static float AlignToPixel(float value)
    {
        return (float)Math.Round(value);
    }
}
