using System;
using System.Globalization;
using System.Threading;

namespace KeyStats.Helpers;

public static class LocalizationManager
{
    // Must be called before any UI loads (typically at the top of App.OnStartup,
    // after settings are loaded but before any window is constructed).
    public static void ApplyAtStartup(string? languagePreference)
    {
        var culture = Resolve(languagePreference);
        Thread.CurrentThread.CurrentUICulture = culture;
        CultureInfo.DefaultThreadCurrentUICulture = culture;
        // CurrentCulture (number/date formats) is intentionally left as system default.
    }

    public static CultureInfo Resolve(string? preference)
    {
        return preference switch
        {
            "zh-Hans" => new CultureInfo("zh-Hans"),
            "en"      => new CultureInfo("en"),
            _         => DetectFromSystem(),  // "system", null, or any unknown value
        };
    }

    private static CultureInfo DetectFromSystem()
    {
        var sys = CultureInfo.CurrentUICulture;
        // Strict simplified Chinese only:
        //   zh-CN, zh-Hans, zh-Hans-CN, zh → 中文
        //   zh-TW, zh-HK, zh-Hant*, en-*, ja-*, etc. → English
        if (sys.Name.StartsWith("zh-Hans", StringComparison.OrdinalIgnoreCase) ||
            sys.Name.Equals("zh-CN", StringComparison.OrdinalIgnoreCase) ||
            sys.Name.Equals("zh", StringComparison.OrdinalIgnoreCase))
        {
            return new CultureInfo("zh-Hans");
        }
        return new CultureInfo("en");
    }
}
