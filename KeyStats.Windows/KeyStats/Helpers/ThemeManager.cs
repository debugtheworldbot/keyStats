using System;
using System.Windows;
using System.Windows.Media;
using Microsoft.Win32;

namespace KeyStats.Helpers;

public sealed class ThemeManager : IDisposable
{
    public static ThemeManager Instance { get; } = new();

    public bool IsDarkTheme { get; private set; }

    public event Action? ThemeChanged;

    private bool _initialized;

    private ThemeManager() { }

    public void Initialize()
    {
        if (_initialized) return;
        _initialized = true;

        IsDarkTheme = DetectSystemDarkTheme();
        ApplyTheme();

        SystemEvents.UserPreferenceChanged += OnUserPreferenceChanged;
    }

    public void Dispose()
    {
        SystemEvents.UserPreferenceChanged -= OnUserPreferenceChanged;
    }

    private void OnUserPreferenceChanged(object sender, UserPreferenceChangedEventArgs e)
    {
        if (e.Category != UserPreferenceCategory.General) return;

        var isDark = DetectSystemDarkTheme();
        if (isDark == IsDarkTheme) return;

        IsDarkTheme = isDark;

        Application.Current?.Dispatcher.Invoke(() =>
        {
            ApplyTheme();
            ThemeChanged?.Invoke();
        });
    }

    private static bool DetectSystemDarkTheme()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(
                @"SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            var value = key?.GetValue("AppsUseLightTheme");
            if (value is int intVal)
                return intVal == 0;
        }
        catch
        {
            // Fall back to light theme on error.
        }
        return false;
    }

    private void ApplyTheme()
    {
        var res = Application.Current?.Resources;
        if (res == null) return;

        if (IsDarkTheme)
            ApplyDarkTheme(res);
        else
            ApplyLightTheme(res);
    }

    private static void ApplyLightTheme(ResourceDictionary res)
    {
        SetColor(res, "AccentColor", "#0067C0");
        SetColor(res, "AccentLightColor", "#60CDFF");
        SetColor(res, "TextPrimaryColor", "#1A1A1A");
        SetColor(res, "TextSecondaryColor", "#5C5C5C");
        SetColor(res, "TextTertiaryColor", "#8A8A8A");
        SetColor(res, "SurfaceColor", "#FAFAFA");
        SetColor(res, "CardColor", "#FFFFFF");
        SetColor(res, "DividerColor", "#E5E5E5");
        SetColor(res, "SubtleFillColor", "#09000000");
        SetColor(res, "SubtleHoverColor", "#12000000");

        SetBrush(res, "AccentBrush", "#0067C0");
        SetBrush(res, "AccentLightBrush", "#60CDFF");
        SetBrush(res, "TextPrimaryBrush", "#1A1A1A");
        SetBrush(res, "TextSecondaryBrush", "#5C5C5C");
        SetBrush(res, "TextTertiaryBrush", "#8A8A8A");
        SetBrush(res, "SurfaceBrush", "#FAFAFA");
        SetBrush(res, "CardBrush", "#FFFFFF");
        SetBrush(res, "DividerBrush", "#E5E5E5");
        SetBrush(res, "SubtleFillBrush", "#09000000");
        SetBrush(res, "SubtleHoverBrush", "#12000000");
        SetBrush(res, "ChartLineBrush", "#0067C0");
        SetBrush(res, "ChartFillBrush", "#200067C0");
        SetBrush(res, "ContextMenuBackgroundBrush", "#F9F9F9");
        SetBrush(res, "MenuItemHoverBrush", "#0A000000");
        SetBrush(res, "ChartAreaBrush", "#15808080");
        SetBrush(res, "SegmentedSelectedBrush", "#FFFFFF");
    }

    private static void ApplyDarkTheme(ResourceDictionary res)
    {
        SetColor(res, "AccentColor", "#0078D4");
        SetColor(res, "AccentLightColor", "#60CDFF");
        SetColor(res, "TextPrimaryColor", "#FFFFFF");
        SetColor(res, "TextSecondaryColor", "#C5C5C5");
        SetColor(res, "TextTertiaryColor", "#8A8A8A");
        SetColor(res, "SurfaceColor", "#202020");
        SetColor(res, "CardColor", "#2D2D2D");
        SetColor(res, "DividerColor", "#3D3D3D");
        SetColor(res, "SubtleFillColor", "#0FFFFFFF");
        SetColor(res, "SubtleHoverColor", "#15FFFFFF");

        SetBrush(res, "AccentBrush", "#0078D4");
        SetBrush(res, "AccentLightBrush", "#60CDFF");
        SetBrush(res, "TextPrimaryBrush", "#FFFFFF");
        SetBrush(res, "TextSecondaryBrush", "#C5C5C5");
        SetBrush(res, "TextTertiaryBrush", "#8A8A8A");
        SetBrush(res, "SurfaceBrush", "#202020");
        SetBrush(res, "CardBrush", "#2D2D2D");
        SetBrush(res, "DividerBrush", "#3D3D3D");
        SetBrush(res, "SubtleFillBrush", "#0FFFFFFF");
        SetBrush(res, "SubtleHoverBrush", "#15FFFFFF");
        SetBrush(res, "ChartLineBrush", "#0078D4");
        SetBrush(res, "ChartFillBrush", "#200078D4");
        SetBrush(res, "ContextMenuBackgroundBrush", "#2C2C2C");
        SetBrush(res, "MenuItemHoverBrush", "#15FFFFFF");
        SetBrush(res, "ChartAreaBrush", "#20808080");
        SetBrush(res, "SegmentedSelectedBrush", "#3D3D3D");
    }

    private static void SetColor(ResourceDictionary res, string key, string hex)
    {
        var color = (Color)ColorConverter.ConvertFromString(hex);
        res[key] = color;
    }

    private static void SetBrush(ResourceDictionary res, string key, string hex)
    {
        var color = (Color)ColorConverter.ConvertFromString(hex);
        res[key] = new SolidColorBrush(color);
    }
}
