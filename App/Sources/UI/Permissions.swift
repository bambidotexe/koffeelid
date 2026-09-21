import AppKit
import ServiceManagement
import UserNotifications
import KoffeeLidCore
import LidPlaneKit

/// One grant the app depends on, or one hook: what the onboarding lists and what the Settings window
/// reports. `title`, `why` and the button titles are the onboarding's words; the Settings pages have their own.
struct PermissionItem {
    /// Which grant this is, for the Settings pages, whatever its title and its place in the list.
    let id: SettingsGrant
    let title: String
    let why: String
    let required: Bool
    let granted: () -> Bool
    let buttonTitle: String
    /// Runs the grant flow; calls `done` (main thread) when the state may have changed.
    let action: (_ window: NSWindow?, _ done: @escaping () -> Void) -> Void
    /// What the onboarding shows once `granted()` is true. "Granted" for a macOS grant; a hook says "Set up".
    var doneTitle: String = L("Granted")
    /// A grant that can be undone from the app (the hooks): the button shown once `granted()` is true.
    var removeTitle: String? = nil
    var remove: ((_ window: NSWindow?, _ done: @escaping () -> Void) -> Void)? = nil
}

/// The five grants, in the order they matter. Notification authorization is asynchronous, so callers
/// refresh it with `refreshNotifications` and read the cached value through `notificationsGranted`.
///
/// A grant's action asks macOS and nothing else: the system dialog carries its own way to System Settings, so
/// the app never opens a pane beside it, nor instead of it once a grant has been refused. Login Items is the
/// one exception, because macOS offers no dialog for it: the pane *is* that grant's flow.
@MainActor
enum PermissionCatalog {
    private(set) static var notificationsGranted = false

    static var items: [PermissionItem] {[
        PermissionItem(id: .sleepLock,
                       title: L("Sleep lock"),
                       why: L("Stops macOS from sleeping the closed Mac when the charger is plugged in or a display changes. Asks for your administrator password once."),
                       required: true,
                       granted: { KoffeeLidController.shared.sleepLockAvailable },
                       buttonTitle: L("Set up…"),
                       action: { window, done in SleepLockSetupAction.run(from: window); done() }),
        PermissionItem(id: .loginItems,
                       title: L("Background App Activity"),
                       why: L("Lets KoffeeLid come back by itself after a crash and give your Mac its normal sleep back. Turn KoffeeLid on in System Settings › General › Login Items."),
                       required: true,
                       granted: { SMAppService.agent(plistName: RelaunchAgentController.plistName).status == .enabled },
                       buttonTitle: L("Open Login Items Settings"),
                       action: { _, done in SMAppService.openSystemSettingsLoginItems(); done() }),
        PermissionItem(id: .screenRecording,
                       title: L("Screen & System Audio Recording"),
                       why: L("Lets the lid effect show your desktop folding as the lid closes."),
                       required: false,
                       granted: { ScreenCapturePermission.isGranted },
                       buttonTitle: L("Allow…"),
                       action: { _, done in ScreenCapturePermission.request(); done() }),
        PermissionItem(id: .inputMonitoring,
                       title: L("Input Monitoring"),
                       why: L("Lets KoffeeLid read the built-in keyboard's Fn key directly, so only that key arms the lid gesture and an external keyboard's Fn key does not."),
                       required: false,
                       granted: { BuiltInFnKeyReader.isGranted },
                       buttonTitle: L("Allow…"),
                       action: { _, done in
                           BuiltInFnKeyReader.requestAccess()
                           KoffeeLidController.shared.inputMonitoringChanged(); done()
                       }),
        PermissionItem(id: .notifications,
                       title: L("Notifications"),
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
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
            Task { @MainActor in refreshNotifications(done) }
        }
    }
}
