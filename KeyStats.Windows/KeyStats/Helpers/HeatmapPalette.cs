using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Windows;
using System.Windows.Media;
using KeyStats.Models;
using KeyStats.Services;

namespace KeyStats.Helpers;

/// <summary>
/// 键盘热力图配色：预置色板 + 用户自定义起止色。热力图控件和设置页预览共用同一套取色逻辑。
/// </summary>
public static class HeatmapPalette
{
    private sealed class Preset
    {
        public string Id { get; }
        public Color[] LightStops { get; }
        public Color[] DarkStops { get; }

        public Preset(string id, Color[] lightStops, Color[] darkStops)
        {
            Id = id;
            LightStops = lightStops;
            DarkStops = darkStops;
        }
    }

    // 每个预置色板三个色阶：低频 → 中频 → 高频。深色模式下高频键更亮，浅色模式下更深。
    private static readonly IReadOnlyList<Preset> Presets = new[]
    {
        new Preset(AppSettings.HeatmapColorSchemeWarm,
            new[] { Rgb(255, 196, 92), Rgb(251, 140, 60), Rgb(229, 57, 53) },
            new[] { Rgb(196, 132, 40), Rgb(226, 110, 38), Rgb(222, 64, 56) }),
        new Preset(AppSettings.HeatmapColorSchemeSpectrum,
            new[] { Rgb(100, 181, 246), Rgb(255, 202, 40), Rgb(229, 57, 53) },
            new[] { Rgb(30, 136, 229), Rgb(253, 216, 53), Rgb(239, 83, 80) }),
        new Preset(AppSettings.HeatmapColorSchemeGreen,
            new[] { Rgb(129, 199, 132), Rgb(67, 160, 71), Rgb(27, 94, 32) },
            new[] { Rgb(46, 125, 50), Rgb(67, 160, 71), Rgb(129, 199, 132) }),
        new Preset(AppSettings.HeatmapColorSchemeTeal,
            new[] { Rgb(128, 222, 234), Rgb(0, 172, 193), Rgb(0, 96, 100) },
            new[] { Rgb(0, 96, 100), Rgb(0, 151, 167), Rgb(77, 208, 225) }),
        new Preset(AppSettings.HeatmapColorSchemePurple,
            new[] { Rgb(206, 147, 216), Rgb(142, 36, 170), Rgb(74, 20, 140) },
            new[] { Rgb(106, 27, 154), Rgb(156, 39, 176), Rgb(206, 147, 216) }),
        new Preset(AppSettings.HeatmapColorSchemeRose,
            new[] { Rgb(248, 187, 208), Rgb(236, 64, 122), Rgb(173, 20, 87) },
            new[] { Rgb(136, 14, 79), Rgb(216, 27, 96), Rgb(244, 143, 177) }),
    };

    public static readonly Color DefaultCustomLowColor = Rgb(255, 224, 130);
    public static readonly Color DefaultCustomHighColor = Rgb(198, 40, 40);

    public static event Action? SchemeChanged;

    public static void NotifySchemeChanged()
    {
        SchemeChanged?.Invoke();
    }

    /// <summary>按键次数为 0 时的底色。</summary>
    public static Color NeutralColor(bool isDarkMode)
    {
        var surface = ResolveColor("SurfaceBrush", isDarkMode ? Color.FromRgb(32, 32, 32) : Color.FromRgb(250, 250, 250));
        var divider = ResolveColor("DividerBrush", isDarkMode ? Color.FromRgb(61, 61, 61) : Color.FromRgb(229, 229, 229));
        return Blend(surface, divider, isDarkMode ? 0.22 : 0.10);
    }

    /// <summary>按当前设置取色，intensity 为 0~1 的热度。</summary>
    public static Color ColorFor(double intensity, bool isDarkMode)
    {
        var settings = StatsManager.Instance.Settings;
        return ColorFor(
            settings.HeatmapColorScheme,
            ParseColor(settings.HeatmapCustomLowColor, DefaultCustomLowColor),
            ParseColor(settings.HeatmapCustomHighColor, DefaultCustomHighColor),
            intensity,
            isDarkMode);
    }

    public static Color ColorFor(string? scheme, Color customLow, Color customHigh, double intensity, bool isDarkMode)
    {
        var neutral = NeutralColor(isDarkMode);

        if (string.Equals(scheme, AppSettings.HeatmapColorSchemeCustom, StringComparison.Ordinal))
        {
            return ThreeStopColor(neutral, customLow, Blend(customLow, customHigh, 0.5), customHigh, intensity, isDarkMode);
        }

        var preset = Presets.FirstOrDefault(p => string.Equals(p.Id, scheme, StringComparison.Ordinal));
        if (preset != null)
        {
            var stops = isDarkMode ? preset.DarkStops : preset.LightStops;
            return ThreeStopColor(neutral, stops[0], stops[1], stops[2], intensity, isDarkMode);
        }

        // 默认：跟随系统强调色（保持原有配色不变）
        var accent = ResolveColor("AccentBrush", isDarkMode ? Color.FromRgb(0, 120, 212) : Color.FromRgb(0, 103, 192));
        var low = Blend(neutral, accent, isDarkMode ? 0.34 : 0.24);
        var high = Blend(accent, isDarkMode ? Colors.White : Colors.Black, isDarkMode ? 0.18 : 0.10);
        return Blend(low, high, intensity);
    }

    /// <summary>设置页下拉项里的色条缩略图。</summary>
    public static Brush CreatePreviewBrush(string scheme, Color customLow, Color customHigh, bool isDarkMode)
    {
        var brush = new LinearGradientBrush { StartPoint = new Point(0, 0.5), EndPoint = new Point(1, 0.5) };
        const int steps = 6;
        for (var i = 0; i <= steps; i++)
        {
            var t = i / (double)steps;
            brush.GradientStops.Add(new GradientStop(ColorFor(scheme, customLow, customHigh, Math.Max(0.05, t), isDarkMode), t));
        }
        brush.Freeze();
        return brush;
    }

    public static Color ParseColor(string? hex, Color fallback)
    {
        if (string.IsNullOrWhiteSpace(hex))
        {
            return fallback;
        }

        try
        {
            return ColorConverter.ConvertFromString(hex) is Color color ? color : fallback;
        }
        catch (FormatException)
        {
            return fallback;
        }
    }

    /// <summary>为实际键帽底色选择对比度更高的黑色或白色文字。</summary>
    public static Color LegendColor(Color background)
    {
        double Linear(byte component)
        {
            var value = component / 255.0;
            return value <= 0.04045 ? value / 12.92 : Math.Pow((value + 0.055) / 1.055, 2.4);
        }

        var luminance = 0.2126 * Linear(background.R)
            + 0.7152 * Linear(background.G)
            + 0.0722 * Linear(background.B);
        var blackContrast = (luminance + 0.05) / 0.05;
        var whiteContrast = 1.05 / (luminance + 0.05);
        return blackContrast >= whiteContrast ? Colors.Black : Colors.White;
    }

    public static string ToHex(Color color)
    {
        return string.Format(CultureInfo.InvariantCulture, "#{0:X2}{1:X2}{2:X2}", color.R, color.G, color.B);
    }

    public static Color Blend(Color from, Color to, double t)
    {
        var progress = Math.Max(0, Math.Min(1, t));
        return Color.FromArgb(
            (byte)Math.Round(from.A + (to.A - from.A) * progress),
            (byte)Math.Round(from.R + (to.R - from.R) * progress),
            (byte)Math.Round(from.G + (to.G - from.G) * progress),
            (byte)Math.Round(from.B + (to.B - from.B) * progress));
    }

    public static Color ResolveColor(string key, Color fallback)
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

    private static Color ThreeStopColor(Color neutral, Color lowStop, Color midStop, Color highStop, double intensity, bool isDarkMode)
    {
        // 低频键与底色混合，避免只按过一两次的键过于抢眼
        var low = Blend(neutral, lowStop, isDarkMode ? 0.45 : 0.40);
        return intensity < 0.5
            ? Blend(low, midStop, intensity / 0.5)
            : Blend(midStop, highStop, (intensity - 0.5) / 0.5);
    }

    private static Color Rgb(byte r, byte g, byte b) => Color.FromRgb(r, g, b);
}
