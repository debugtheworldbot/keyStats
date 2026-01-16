using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Color = System.Drawing.Color;
using Pen = System.Drawing.Pen;
using PixelFormat = System.Drawing.Imaging.PixelFormat;

namespace KeyStats.Helpers;

public static class IconGenerator
{
    public static Icon CreateTrayIcon(Color? tintColor = null)
    {
        const int size = 16;
        using var bitmap = new Bitmap(size, size, PixelFormat.Format32bppArgb);
        using var g = Graphics.FromImage(bitmap);

        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.InterpolationMode = InterpolationMode.HighQualityBicubic;
        g.PixelOffsetMode = PixelOffsetMode.HighQuality;
        g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;

        // Draw keyboard icon
        var keyColor = tintColor ?? Color.White;
        using var pen = new Pen(keyColor, 1.5f);
        using var brush = new SolidBrush(keyColor);

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

        // Convert to icon
        var iconHandle = bitmap.GetHicon();
        return Icon.FromHandle(iconHandle);
    }

    public static ImageSource CreateTrayIconImageSource(Color? tintColor = null)
    {
        using var icon = CreateTrayIcon(tintColor);
        using var bitmap = icon.ToBitmap();
        return BitmapToImageSource(bitmap);
    }

    public static ImageSource BitmapToImageSource(Bitmap bitmap)
    {
        var bitmapData = bitmap.LockBits(
            new Rectangle(0, 0, bitmap.Width, bitmap.Height),
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

    private static void DrawRoundedRectangle(this Graphics g, Pen pen, RectangleF rect, float radius)
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

    public static Color GetRateColor(double ratePerSecond)
    {
        var apm = ratePerSecond * 60;
        double[] thresholds = { 0, 80, 160, 240 };

        if (apm < thresholds[1])
        {
            return Color.Empty;
        }

        if (apm >= thresholds[3])
        {
            return Color.FromArgb(255, 59, 48); // System red
        }

        if (apm <= thresholds[2])
        {
            var progress = (apm - thresholds[1]) / (thresholds[2] - thresholds[1]);
            var lightGreen = LightenColor(Color.FromArgb(52, 199, 89), 0.6); // System green
            return InterpolateColor(lightGreen, Color.FromArgb(52, 199, 89), progress);
        }

        var progressYellowToRed = (apm - thresholds[2]) / (thresholds[3] - thresholds[2]);
        return InterpolateColor(Color.FromArgb(255, 204, 0), Color.FromArgb(255, 59, 48), progressYellowToRed);
    }

    private static Color InterpolateColor(Color from, Color to, double progress)
    {
        progress = Math.Clamp(progress, 0, 1);
        return Color.FromArgb(
            (int)(from.A + (to.A - from.A) * progress),
            (int)(from.R + (to.R - from.R) * progress),
            (int)(from.G + (to.G - from.G) * progress),
            (int)(from.B + (to.B - from.B) * progress)
        );
    }

    private static Color LightenColor(Color color, double fraction)
    {
        fraction = Math.Clamp(fraction, 0, 1);
        return Color.FromArgb(
            color.A,
            (int)(color.R + (255 - color.R) * fraction),
            (int)(color.G + (255 - color.G) * fraction),
            (int)(color.B + (255 - color.B) * fraction)
        );
    }
}
