import Foundation
import UserNotifications

final class NotificationManager {
    static let shared = NotificationManager()

    enum Metric {
        case keyPresses
        case clicks
    }

    private let center = UNUserNotificationCenter.current()

    private init() {}

    func requestAuthorizationIfNeeded() {
        center.getNotificationSettings { [weak self] settings in
            guard let self = self else { return }
            guard settings.authorizationStatus == .notDetermined else { return }
            self.center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    func sendThresholdNotification(metric: Metric, count: Int, threshold: Int) {
        guard threshold > 0 else { return }

        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("notification.threshold.title", comment: "")
        content.body = thresholdBody(for: metric, count: count)
        content.sound = .default

        let identifier = "threshold.\(metricIdentifier(for: metric)).\(count)"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        center.add(request, withCompletionHandler: nil)
    }

    private func thresholdBody(for metric: Metric, count: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let formattedCount = formatter.string(from: NSNumber(value: count)) ?? "\(count)"
        let key: String
        switch metric {
        case .keyPresses:
            key = "notification.threshold.body.keys"
        case .clicks:
            key = "notification.threshold.body.clicks"
        }
        return String(format: NSLocalizedString(key, comment: ""), formattedCount)
    }

    private func metricIdentifier(for metric: Metric) -> String {
        switch metric {
        case .keyPresses:
            return "keys"
        case .clicks:
            return "clicks"
        }
    }
}
