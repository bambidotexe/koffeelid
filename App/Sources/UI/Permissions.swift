import AppKit
import ServiceManagement
import UserNotifications
import LidPlaneKit

/// One macOS grant the app depends on: shown by the onboarding page and the Settings "Permissions" group.
struct PermissionItem {
    let title: String
    let why: String
    let required: Bool
    let granted: () -> Bool
    let buttonTitle: String
    /// Runs the grant flow; calls `done` (main thread) when the state may have changed.
    let action: (_ window: NSWindow?, _ done: @escaping () -> Void) -> Void
    /// What the row shows once `granted()` is true. "Granted" for a macOS grant; a hook says "Installed".
    var doneTitle: String = L("Granted")
    /// What the row shows while `granted()` is false. A hook says "Not set up".
    var pendingTitle: String = L("Not granted")
    /// A grant that can be undone from the app (the hooks): the button shown once `granted()` is true.
    var removeTitle: String? = nil
    var remove: ((_ window: NSWindow?, _ done: @escaping () -> Void) -> Void)? = nil
}

/// The five grants, in the order they matter. Notification authorization is asynchronous, so callers
/// refresh it with `refreshNotifications` and read the cached value through `notificationsGranted`.
@MainActor
enum PermissionCatalog {
    private(set) static var notificationsGranted = false

    static var items: [PermissionItem] {[
        PermissionItem(title: L("Sleep lock"),
                       why: L("Stops macOS from sleeping the closed Mac when the charger is plugged in or a display changes. Asks for your administrator password once."),
                       required: true,
                       granted: { KoffeeLidController.shared.sleepLockAvailable },
                       buttonTitle: L("Set up…"),
                       action: { window, done in SleepLockSetupAction.run(from: window); done() }),
        PermissionItem(title: L("Login Items"),
                       why: L("Lets the watchdog relaunch KoffeeLid after a crash and restore lid sleep. Approve KoffeeLid in System Settings › General › Login Items."),
                       required: true,
                       granted: { SMAppService.agent(plistName: "dev.rubens.koffeelid.agent.plist").status == .enabled },
                       buttonTitle: L("Open Login Items"),
                       action: { _, done in SMAppService.openSystemSettingsLoginItems(); done() }),
        PermissionItem(title: L("Screen Recording"),
                       why: L("Lets the lid effect show your desktop folding as the lid closes."),
                       required: false,
                       granted: { ScreenCapturePermission.isGranted },
                       buttonTitle: L("Allow…"),
                       action: { _, done in if !ScreenCapturePermission.request() { ScreenCapturePermission.openSystemSettings() }; done() }),
        PermissionItem(title: L("Input Monitoring"),
                       why: L("Lets KoffeeLid read the built-in keyboard's Fn key directly, so only that key arms the lid gesture and an external keyboard's Fn key does not."),
                       required: false,
                       granted: { BuiltInFnKeyReader.isGranted },
                       buttonTitle: L("Allow…"),
                       action: { _, done in
                           if BuiltInFnKeyReader.isDenied { BuiltInFnKeyReader.openSystemSettings() } else { BuiltInFnKeyReader.requestAccess() }
                           KoffeeLidController.shared.inputMonitoringChanged(); done()
                       }),
        PermissionItem(title: L("Notifications"),
                       why: L("Tells you when KoffeeLid disarms itself (low battery, thermal pressure) or cannot lock the screen."),
                       required: false,
                       granted: { notificationsGranted },
                       buttonTitle: L("Allow…"),
                       action: { _, done in requestNotifications(done) }),
    ]}

    static func refreshNotifications(_ done: @escaping () -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { s in
            DispatchQueue.main.async { notificationsGranted = s.authorizationStatus == .authorized; done() }
        }
    }

    private static func requestNotifications(_ done: @escaping () -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { s in
            DispatchQueue.main.async {
                if s.authorizationStatus == .denied, let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                    NSWorkspace.shared.open(url); done()
                } else {
                    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in Task { @MainActor in refreshNotifications(done) } }
                }
            }
        }
    }
}
