using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Windows.Threading;
using KeyStats.Models;
using Strings = KeyStats.Properties.Strings;

namespace KeyStats.Services;

/// <summary>
/// 定时评估成就：新达成的写入设置，首次运行静默补记，之后新解锁的发通知。
/// 跑在 UI 线程的 DispatcherTimer 上，和设置窗口读写 Settings 不会并发。
/// </summary>
public sealed class AchievementService
{
    private static AchievementService? _instance;
    public static AchievementService Instance => _instance ??= new AchievementService();

    private const string DateFormat = "yyyy-MM-dd";
    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromSeconds(60) };
    private readonly DispatcherTimer _startupTimer = new() { Interval = TimeSpan.FromSeconds(3) };

    public event Action? AchievementsChanged;

    private AchievementService()
    {
        _timer.Tick += (_, _) => Evaluate();
        _startupTimer.Tick += (_, _) =>
        {
            _startupTimer.Stop();
            Evaluate();
        };
    }

    public void Start()
    {
        _startupTimer.Start();
        _timer.Start();
    }

    public void Stop()
    {
        _startupTimer.Stop();
        _timer.Stop();
    }

    public IReadOnlyList<AchievementProgress> GetProgress()
    {
        var history = StatsManager.Instance.GetLocalHistorySnapshot().Values;
        return AchievementEvaluator.Evaluate(history, StatsManager.Instance.GetMetersPerPixel());
    }

    /// <summary>已记录的解锁日期；没有记录时退回到评估出的首次达成日期。</summary>
    public DateTime? GetUnlockDate(AchievementProgress progress)
    {
        var unlocked = StatsManager.Instance.Settings.UnlockedAchievements;
        if (unlocked != null
            && unlocked.TryGetValue(progress.Definition.Id, out var text)
            && DateTime.TryParseExact(text, DateFormat, CultureInfo.InvariantCulture, DateTimeStyles.None, out var date))
        {
            return date;
        }
        return progress.ReachedOn;
    }

    public void Evaluate()
    {
        try
        {
            var settings = StatsManager.Instance.Settings;
            settings.UnlockedAchievements ??= new Dictionary<string, string>();
            var newlyUnlocked = new List<AchievementProgress>();

            foreach (var progress in GetProgress().Where(p => p.IsUnlocked))
            {
                if (settings.UnlockedAchievements.ContainsKey(progress.Definition.Id))
                {
                    continue;
                }
                settings.UnlockedAchievements[progress.Definition.Id] =
                    progress.ReachedOn!.Value.ToString(DateFormat, CultureInfo.InvariantCulture);
                newlyUnlocked.Add(progress);
            }

            var wasInitialized = settings.AchievementsInitialized;
            if (newlyUnlocked.Count == 0 && wasInitialized)
            {
                return;
            }

            settings.AchievementsInitialized = true;
            StatsManager.Instance.SaveSettings();

            if (wasInitialized && settings.AchievementNotificationsEnabled)
            {
                foreach (var progress in newlyUnlocked)
                {
                    NotificationService.Instance.SendAchievementNotification(
                        GetName(progress.Definition.Id),
                        GetDescription(progress.Definition));
                    App.CurrentApp?.TrackClick("achievement_unlocked", new Dictionary<string, object?>
                    {
                        ["achievement"] = progress.Definition.Id
                    });
                }
            }

            if (newlyUnlocked.Count > 0)
            {
                AchievementsChanged?.Invoke();
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Achievement evaluation failed: {ex.Message}");
        }
    }

    public static string GetName(string id) => id switch
    {
        "keys_100k" => Strings.Achievement_keys_100k,
        "keys_1m" => Strings.Achievement_keys_1m,
        "keys_10m" => Strings.Achievement_keys_10m,
        "day_10k" => Strings.Achievement_day_10k,
        "day_30k" => Strings.Achievement_day_30k,
        "day_50k" => Strings.Achievement_day_50k,
        "clicks_100k" => Strings.Achievement_clicks_100k,
        "clicks_1m" => Strings.Achievement_clicks_1m,
        "streak_7" => Strings.Achievement_streak_7,
        "streak_30" => Strings.Achievement_streak_30,
        "streak_100" => Strings.Achievement_streak_100,
        "active_100" => Strings.Achievement_active_100,
        "active_365" => Strings.Achievement_active_365,
        "kps_10" => Strings.Achievement_kps_10,
        "kps_15" => Strings.Achievement_kps_15,
        "marathon" => Strings.Achievement_marathon,
        _ => id
    };

    public static string GetDescription(AchievementDefinition definition)
    {
        var culture = CultureInfo.CurrentCulture;
        var target = definition.Category == AchievementCategory.MouseDistanceKm
            ? definition.Target.ToString("0.###", culture)
            : definition.Target.ToString("N0", culture);
        var format = definition.Category switch
        {
            AchievementCategory.TotalKeys => Strings.Achievement_Desc_TotalKeys,
            AchievementCategory.DailyKeys => Strings.Achievement_Desc_DailyKeys,
            AchievementCategory.TotalClicks => Strings.Achievement_Desc_TotalClicks,
            AchievementCategory.Streak => Strings.Achievement_Desc_Streak,
            AchievementCategory.ActiveDays => Strings.Achievement_Desc_ActiveDays,
            AchievementCategory.PeakKps => Strings.Achievement_Desc_PeakKps,
            AchievementCategory.MouseDistanceKm => Strings.Achievement_Desc_MouseDistance,
            _ => "{0}"
        };
        return string.Format(culture, format, target);
    }
}
