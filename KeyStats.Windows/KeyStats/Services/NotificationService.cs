using System;
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
        var body = metric switch
        {
            Metric.KeyPresses => string.Format(KeyStats.Properties.Strings.Notif_KeyThresholdReachedFormat, count),
            Metric.Clicks => string.Format(KeyStats.Properties.Strings.Notif_ClickThresholdReachedFormat, count),
            _ => ""
        };

        try
        {
            new ToastContentBuilder()
                .AddText(KeyStats.Properties.Strings.Notif_ThresholdTitle)
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
