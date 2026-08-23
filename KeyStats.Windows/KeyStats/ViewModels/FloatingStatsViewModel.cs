using System;
using System.Collections.Generic;
using System.Globalization;
using System.Windows;
using KeyStats.Services;

namespace KeyStats.ViewModels;

public sealed class FloatingStatsViewModel : ViewModelBase
{
    private static event Action? MetricSettingsChanged;

    public const string KeyPressesMetric = "keyPresses";
    public const string TotalClicksMetric = "totalClicks";
    public const string LeftClicksMetric = "leftClicks";
    public const string RightClicksMetric = "rightClicks";
    public const string MiddleClicksMetric = "middleClicks";
    public const string MouseDistanceMetric = "mouseDistance";
    public const string ScrollDistanceMetric = "scrollDistance";
    public const string PeakKpsMetric = "peakKps";
    public const string PeakCpsMetric = "peakCps";

    private static readonly string[] MetricIds =
    {
        KeyPressesMetric,
        TotalClicksMetric,
        LeftClicksMetric,
        RightClicksMetric,
        MiddleClicksMetric,
        MouseDistanceMetric,
        ScrollDistanceMetric,
        PeakKpsMetric,
        PeakCpsMetric
    };

    private string _primaryLabel = string.Empty;
    private string _primaryIcon = string.Empty;
    private string _primaryValue = "0";
    private string _primaryFullValue = "0";
    private string _secondaryLabel = string.Empty;
    private string _secondaryIcon = string.Empty;
    private string _secondaryValue = "0";
    private string _secondaryFullValue = "0";
    private bool _isCleanedUp;

    public FloatingStatsViewModel()
    {
        NormalizeMetricSettings();
        Refresh();
        StatsManager.Instance.StatsChanged += OnStatsChanged;
        MetricSettingsChanged += OnMetricSettingsChanged;
    }

    public static IReadOnlyList<string> AvailableMetricIds => MetricIds;

    public string PrimaryLabel
    {
        get => _primaryLabel;
        private set => SetProperty(ref _primaryLabel, value);
    }

    public string PrimaryIcon
    {
        get => _primaryIcon;
        private set => SetProperty(ref _primaryIcon, value);
    }

    public string PrimaryValue
    {
        get => _primaryValue;
        private set => SetProperty(ref _primaryValue, value);
    }

    public string PrimaryFullValue
    {
        get => _primaryFullValue;
        private set => SetProperty(ref _primaryFullValue, value);
    }

    public string SecondaryLabel
    {
        get => _secondaryLabel;
        private set => SetProperty(ref _secondaryLabel, value);
    }

    public string SecondaryIcon
    {
        get => _secondaryIcon;
        private set => SetProperty(ref _secondaryIcon, value);
    }

    public string SecondaryValue
    {
        get => _secondaryValue;
        private set => SetProperty(ref _secondaryValue, value);
    }

    public string SecondaryFullValue
    {
        get => _secondaryFullValue;
        private set => SetProperty(ref _secondaryFullValue, value);
    }

    public string PrimaryMetricId => StatsManager.Instance.Settings.FloatingStatsPrimaryMetric;

    public string SecondaryMetricId => StatsManager.Instance.Settings.FloatingStatsSecondaryMetric;

    public static bool IsValidMetric(string? metricId)
    {
        if (string.IsNullOrWhiteSpace(metricId))
        {
            return false;
        }

        foreach (var candidate in MetricIds)
        {
            if (string.Equals(candidate, metricId, StringComparison.Ordinal))
            {
                return true;
            }
        }

        return false;
    }

    public static string GetMetricLabel(string metricId)
    {
        return metricId switch
        {
            KeyPressesMetric => KeyStats.Properties.Strings.Stats_KeyPresses,
            TotalClicksMetric => KeyStats.Properties.Strings.Stats_MouseClicks,
            LeftClicksMetric => KeyStats.Properties.Strings.Click_Left,
            RightClicksMetric => KeyStats.Properties.Strings.Click_Right,
            MiddleClicksMetric => KeyStats.Properties.Strings.Click_Middle,
            MouseDistanceMetric => KeyStats.Properties.Strings.Stats_MouseDistance,
            ScrollDistanceMetric => KeyStats.Properties.Strings.Stats_ScrollDistance,
            PeakKpsMetric => KeyStats.Properties.Strings.Stats_PeakKpsTooltipLabel,
            PeakCpsMetric => KeyStats.Properties.Strings.Stats_PeakCpsTooltipLabel,
            _ => KeyStats.Properties.Strings.Stats_KeyPresses
        };
    }

    public bool SetMetric(bool isPrimary, string metricId)
    {
        return UpdateMetricSetting(isPrimary, metricId);
    }

    public static bool UpdateMetricSetting(bool isPrimary, string metricId)
    {
        if (!IsValidMetric(metricId))
        {
            return false;
        }

        var settings = StatsManager.Instance.Settings;
        var otherMetric = isPrimary
            ? settings.FloatingStatsSecondaryMetric
            : settings.FloatingStatsPrimaryMetric;
        if (string.Equals(metricId, otherMetric, StringComparison.Ordinal))
        {
            return false;
        }

        if (isPrimary)
        {
            if (string.Equals(settings.FloatingStatsPrimaryMetric, metricId, StringComparison.Ordinal))
            {
                return false;
            }

            settings.FloatingStatsPrimaryMetric = metricId;
        }
        else
        {
            if (string.Equals(settings.FloatingStatsSecondaryMetric, metricId, StringComparison.Ordinal))
            {
                return false;
            }

            settings.FloatingStatsSecondaryMetric = metricId;
        }

        StatsManager.Instance.SaveSettings();
        MetricSettingsChanged?.Invoke();
        return true;
    }

    public void Cleanup()
    {
        if (_isCleanedUp)
        {
            return;
        }

        _isCleanedUp = true;
        StatsManager.Instance.StatsChanged -= OnStatsChanged;
        MetricSettingsChanged -= OnMetricSettingsChanged;
    }

    private void NormalizeMetricSettings()
    {
        var settings = StatsManager.Instance.Settings;
        var changed = false;

        if (!IsValidMetric(settings.FloatingStatsPrimaryMetric))
        {
            settings.FloatingStatsPrimaryMetric = KeyPressesMetric;
            changed = true;
        }

        if (!IsValidMetric(settings.FloatingStatsSecondaryMetric) ||
            string.Equals(
                settings.FloatingStatsPrimaryMetric,
                settings.FloatingStatsSecondaryMetric,
                StringComparison.Ordinal))
        {
            settings.FloatingStatsSecondaryMetric = TotalClicksMetric;
            if (string.Equals(
                    settings.FloatingStatsPrimaryMetric,
                    settings.FloatingStatsSecondaryMetric,
                    StringComparison.Ordinal))
            {
                settings.FloatingStatsSecondaryMetric = LeftClicksMetric;
            }

            changed = true;
        }

        if (changed)
        {
            StatsManager.Instance.SaveSettings();
        }
    }

    private void OnStatsChanged(StatsManager.StatsUpdateKind _)
    {
        var dispatcher = Application.Current?.Dispatcher;
        if (dispatcher == null || dispatcher.CheckAccess())
        {
            Refresh();
            return;
        }

        dispatcher.BeginInvoke(new Action(Refresh));
    }

    private void OnMetricSettingsChanged()
    {
        var dispatcher = Application.Current?.Dispatcher;
        if (dispatcher == null || dispatcher.CheckAccess())
        {
            Refresh();
            return;
        }

        dispatcher.BeginInvoke(new Action(Refresh));
    }

    private void Refresh()
    {
        if (_isCleanedUp)
        {
            return;
        }

        var manager = StatsManager.Instance;
        var stats = manager.GetCurrentStatsSnapshot();
        var primary = CreatePresentation(PrimaryMetricId, stats, manager);
        var secondary = CreatePresentation(SecondaryMetricId, stats, manager);

        PrimaryLabel = primary.Label;
        PrimaryIcon = primary.Icon;
        PrimaryValue = primary.CompactValue;
        PrimaryFullValue = primary.FullValue;
        SecondaryLabel = secondary.Label;
        SecondaryIcon = secondary.Icon;
        SecondaryValue = secondary.CompactValue;
        SecondaryFullValue = secondary.FullValue;
    }

    private static (string Label, string Icon, string CompactValue, string FullValue) CreatePresentation(
        string metricId,
        StatsManager.CurrentStatsSnapshot stats,
        StatsManager manager)
    {
        var label = GetMetricLabel(metricId);
        var icon = metricId is KeyPressesMetric or PeakKpsMetric ? "\uE765" : "\uE8B0";
        string compactValue;
        string fullValue;

        switch (metricId)
        {
            case TotalClicksMetric:
                compactValue = manager.FormatNumber(stats.TotalClicks);
                fullValue = stats.TotalClicks.ToString("N0", CultureInfo.CurrentCulture);
                break;
            case LeftClicksMetric:
                compactValue = manager.FormatNumber(stats.LeftClicks);
                fullValue = stats.LeftClicks.ToString("N0", CultureInfo.CurrentCulture);
                break;
            case RightClicksMetric:
                compactValue = manager.FormatNumber(stats.RightClicks);
                fullValue = stats.RightClicks.ToString("N0", CultureInfo.CurrentCulture);
                break;
            case MiddleClicksMetric:
                compactValue = manager.FormatNumber(stats.MiddleClicks);
                fullValue = stats.MiddleClicks.ToString("N0", CultureInfo.CurrentCulture);
                break;
            case MouseDistanceMetric:
                compactValue = manager.FormatMouseDistance(stats.MouseDistance);
                fullValue = compactValue;
                break;
            case ScrollDistanceMetric:
                compactValue = manager.FormatScrollDistance(stats.ScrollDistance);
                fullValue = compactValue;
                break;
            case PeakKpsMetric:
                compactValue = Math.Round(stats.PeakKPS, MidpointRounding.AwayFromZero)
                    .ToString("N0", CultureInfo.CurrentCulture);
                fullValue = compactValue;
                break;
            case PeakCpsMetric:
                compactValue = Math.Round(stats.PeakCPS, MidpointRounding.AwayFromZero)
                    .ToString("N0", CultureInfo.CurrentCulture);
                fullValue = compactValue;
                break;
            default:
                compactValue = manager.FormatNumber(stats.KeyPresses);
                fullValue = stats.KeyPresses.ToString("N0", CultureInfo.CurrentCulture);
                break;
        }

        return (label, icon, compactValue, $"{label}: {fullValue}");
    }
}
