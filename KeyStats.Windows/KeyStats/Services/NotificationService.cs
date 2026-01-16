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
            Metric.KeyPresses => $"Today's key presses reached {formattedCount}!",
            Metric.Clicks => $"Today's clicks reached {formattedCount}!",
            _ => ""
        };

        try
        {
            new ToastContentBuilder()
                .AddText("KeyStats")
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
