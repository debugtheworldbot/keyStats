using Microsoft.Toolkit.Uwp.Notifications;

namespace KeyStats.Services;

public class NotificationService
{
    private static NotificationService? _instance;
    public static NotificationService Instance => _instance ??= new NotificationService();

    public enum Metric
    {
        KeyPresses,
        Clicks
    }

    private NotificationService() { }

    public void SendThresholdNotification(Metric metric, int count)
    {
        var formattedCount = count.ToString("N0");
        var body = metric switch
        {
            Metric.KeyPresses => $"今日按键次数已达到 {formattedCount}！",
            Metric.Clicks => $"今日点击次数已达到 {formattedCount}！",
            _ => ""
        };

        try
        {
            new ToastContentBuilder()
                .AddText("按键统计")
                .AddText(body)
                .Show();
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"Error showing notification: {ex.Message}");
        }
    }

    public void ClearNotifications()
    {
        try
        {
            ToastNotificationManagerCompat.History.Clear();
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"Error clearing notifications: {ex.Message}");
        }
    }
}
