import Foundation
import UserNotifications
import BudgetCore
import MangoUI

/// The app's notification center behind `NotificationCenterClient`: one calendar trigger per planned reminder, its
/// words from `NotificationCopy`, its link in `userInfo` (`NotificationScheduler.userInfo`).
struct SystemNotificationCenter: NotificationCenterClient {
    func authorizationStatus() async -> NotificationAuthorization {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: .granted
        case .denied: .denied
        default: .notDetermined
        }
    }

    func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func pendingContent() async -> [String: String] {
        let requests = await UNUserNotificationCenter.current().pendingNotificationRequests()
        return Dictionary(requests.map { ($0.identifier, PlannedNotification.content(title: $0.content.title, body: $0.content.body)) },
                          uniquingKeysWith: { first, _ in first })
    }

    func add(_ notification: PlannedNotification) async throws {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        content.userInfo = NotificationScheduler.userInfo(for: notification.link)
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: notification.fireDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
        try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: notification.id, content: content, trigger: trigger))
    }

    func remove(ids: [String]) async {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }

    func removeAllDelivered() async {
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }
}

/// A tap on a delivered reminder: hands its tab to `PhoneOutputs`, which the root opens.
final class NotificationTapDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationTapDelegate()

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let link = NotificationScheduler.link(fromUserInfo: response.notification.request.content.userInfo) else { return }
        await MainActor.run { PhoneOutputs.shared.pendingLink = link }
    }

    /// A reminder that arrives while Mango is open still shows.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}
