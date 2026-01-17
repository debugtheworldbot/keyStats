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
    /// <summary>
    /// Creates a tray icon with two lines of stats (keys on top, clicks on bottom)
    /// </summary>
    public static Icon CreateTrayIcon(DrawingColor? tintColor = null, string? keysText = null, string? clicksText = null)
    {
        // Get system tray icon size based on DPI
        int size = GetSystemTrayIconSize();

        using var bitmap = new Bitmap(size, size, PixelFormat.Format32bppArgb);
        using var g = Graphics.FromImage(bitmap);

        g.SmoothingMode = SmoothingMode.HighQuality;
        g.InterpolationMode = InterpolationMode.HighQualityBicubic;
        g.PixelOffsetMode = PixelOffsetMode.HighQuality;
        g.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;
        g.CompositingQuality = CompositingQuality.HighQuality;

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
        return Icon.FromHandle(iconHandle);
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

        // Scale factor based on size (base is 32)
        float scale = size / 32f;
        var maxLen = Math.Max(keysDisplay.Length, clicksDisplay.Length);

        // Base font sizes for 32px, scaled up
        float baseFontSize = maxLen switch
        {
            1 => 18f,
            2 => 16f,
            3 => 14f,
            _ => 12f
        };

        float fontSize = baseFontSize * scale;
        using var font = new Font("Arial", fontSize, FontStyle.Regular, GraphicsUnit.Pixel);

        var lineHeight = fontSize + (2 * scale); // 行间距
        var totalHeight = lineHeight * 2;
        var startY = (size - totalHeight) / 2;

        // Draw top line (keys)
        if (!string.IsNullOrEmpty(keysDisplay))
        {
            var textSize = g.MeasureString(keysDisplay, font);
            var x = (size - textSize.Width) / 2;
            g.DrawString(keysDisplay, font, brush, x, startY);
        }

        // Draw bottom line (clicks)
        if (!string.IsNullOrEmpty(clicksDisplay))
        {
            var textSize = g.MeasureString(clicksDisplay, font);
            var x = (size - textSize.Width) / 2;
            g.DrawString(clicksDisplay, font, brush, x, startY + lineHeight);
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
}
