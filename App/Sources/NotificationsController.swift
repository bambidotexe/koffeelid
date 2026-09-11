import UserNotifications

final class NotificationsController {
    static let shared = NotificationsController()
    private let center = UNUserNotificationCenter.current()

    func requestAuthorization() { center.requestAuthorization(options: [.alert, .sound]) { _, _ in } }

    func post(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent(); content.title = title; content.body = body
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
    func clear(id: String) {
        center.removeDeliveredNotifications(withIdentifiers: [id]); center.removePendingNotificationRequests(withIdentifiers: [id])
    }
}
