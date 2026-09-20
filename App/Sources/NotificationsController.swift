import UserNotifications

final class NotificationsController: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationsController()
    private let center = UNUserNotificationCenter.current()

    /// The update notification's Update button, or a click on the notification itself. Called on main.
    var onUpdateRequested: (() -> Void)?

    private static let updateID = "update"
    private static let updateCategory = "update"
    private static let updateAction = "update.open"

    private override init() {
        super.init()
        center.delegate = self
        // `.foreground`: the button brings the app forward, which the update window needs.
        let update = UNNotificationAction(identifier: Self.updateAction, title: L("Update"), options: [.foreground])
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.updateCategory, actions: [update], intentIdentifiers: [])])
    }

    func requestAuthorization() { center.requestAuthorization(options: [.alert, .sound]) { _, _ in } }

    func post(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent(); content.title = title; content.body = body
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
    func clear(id: String) {
        center.removeDeliveredNotifications(withIdentifiers: [id]); center.removePendingNotificationRequests(withIdentifiers: [id])
    }

    /// One at a time: a later check's notification replaces the one still in Notification Center.
    func postUpdateAvailable(version: String) {
        let content = UNMutableNotificationContent()
        content.title = String(format: L("Version %@ is available"), version)
        content.body = L("Click Update to download and install it.")
        content.categoryIdentifier = Self.updateCategory
        center.add(UNNotificationRequest(identifier: Self.updateID, content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let wanted = response.actionIdentifier == Self.updateAction || response.actionIdentifier == UNNotificationDefaultActionIdentifier
        if response.notification.request.identifier == Self.updateID, wanted {
            DispatchQueue.main.async { self.onUpdateRequested?() }
        }
        completionHandler()
    }

    /// Asked only while the app is frontmost. The update's notification shows then too (Settings may be the window
    /// in front when a check finds a release); every other message keeps what it gets without a delegate, nothing.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler(notification.request.identifier == Self.updateID ? [.banner, .list] : [])
    }
}
