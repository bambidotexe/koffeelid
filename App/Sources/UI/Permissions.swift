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
    let granted: () -> Bool
    let buttonTitle: String
    /// Runs the grant flow; calls `done` (main thread) when the state may have changed.
    let action: (_ window: NSWindow?, _ done: @escaping () -> Void) -> Void
    /// Whether the flow puts up its own dialog and blocks until it is answered. macOS does not reactivate an
    /// accessory app when such a dialog closes, so a flow that owned one takes activation back when it ends.
    /// A flow that hands over to System Settings or to a system prompt leaves it false: taking activation
    /// there is what used to drop the window on top of what it had just opened.
    var returnsFocus: Bool = false
    /// The app this flow can send the user to, if any: System Settings for every macOS grant, whether the
    /// button opens the pane itself or the system dialog offers to. macOS gives an ordinary app the front
    /// back when the app it handed over to quits, and leaves an accessory app out of that, so the caller
    /// waits for this app to quit and does it itself. Nil for a flow that stays inside KoffeeLid.
    var mayOpen: String? = nil
    /// What the onboarding shows once `granted()` is true. "Granted" for a macOS grant; a hook says "Set up".
    var doneTitle: String = L("Granted")
    /// A grant that can be undone from the app (the hooks): the button shown once `granted()` is true.
    var removeTitle: String? = nil
    var remove: ((_ window: NSWindow?, _ done: @escaping () -> Void) -> Void)? = nil

    /// Whether the onboarding marks the row required. Core decides it (`SettingsGrant.isRequired`), so the
    /// wizard's mark and the colour a missing grant takes on every page cannot disagree.
    var required: Bool { id.isRequired }
}

/// Gives the front back after the user has been sent to another app, the way macOS does for an ordinary
/// app by itself. One of these waits for a named app to quit and then brings its window forward, once.
///
/// The wait is bounded: a user who dismisses the dialog and never goes to System Settings would otherwise
/// leave it armed, and an unrelated visit there much later would pull the window forward out of nowhere.
@MainActor
final class FocusReturnWatch {
    private var observer: NSObjectProtocol?
    private weak var target: NSWindow?
    /// How long a wait stays honoured. Long enough to grant a permission, short enough not to linger.
    private static let window: TimeInterval = 300

    deinit { if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) } }

    /// Waits for `bundleID` to quit, then brings `window` to the front. Replaces any earlier wait, and does
    /// nothing if the window has gone away or been closed by then.
    func whenQuit(_ bundleID: String, bringBack window: NSWindow?) {
        stop()
        guard let window else { return }
        target = window
        let deadline = Date().addingTimeInterval(Self.window)
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self,
                      let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.bundleIdentifier == bundleID
                else { return }
                let target = self.target
                self.stop()
                guard Date() < deadline, let target, target.isVisible else { return }
                NSApp.activate(ignoringOtherApps: true)
                target.makeKeyAndOrderFront(nil)
            }
        }
    }

    func stop() {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
        target = nil
    }
}

extension PermissionItem {
    /// Activation back to `window` once a flow that owned a modal dialog has ended, and only then.
    @MainActor func reclaimFocusIfNeeded(_ window: NSWindow?) {
        guard returnsFocus, let window, window.isVisible else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
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
                       granted: { KoffeeLidController.shared.sleepLockAvailable },
                       buttonTitle: L("Set up…"),
                       action: { window, done in SleepLockSetupAction.run(from: window); done() },
                       returnsFocus: true),
        PermissionItem(id: .loginItems,
                       title: L("Background App Activity"),
                       why: L("Lets KoffeeLid come back by itself after a crash and give your Mac its normal sleep back. Turn KoffeeLid on in System Settings › General › Login Items."),
                       granted: { SMAppService.agent(plistName: RelaunchAgentController.plistName).status == .enabled },
                       buttonTitle: L("Open Login Items Settings"),
                       action: { _, done in SMAppService.openSystemSettingsLoginItems(); done() },
                       mayOpen: "com.apple.systempreferences"),
        PermissionItem(id: .screenRecording,
                       title: L("Screen Recording"),
                       why: L("Lets the lid effect show your desktop folding as the lid closes."),
                       granted: { ScreenCapturePermission.isGranted },
                       buttonTitle: L("Allow…"),
                       action: { _, done in ScreenCapturePermission.request(); done() },
                       mayOpen: "com.apple.systempreferences"),
        PermissionItem(id: .inputMonitoring,
                       title: L("Input Monitoring"),
                       why: L("Lets KoffeeLid read the built-in keyboard's Fn key directly, so only that key arms the lid gesture and an external keyboard's Fn key does not."),
                       granted: { BuiltInFnKeyReader.isGranted },
                       buttonTitle: L("Allow…"),
                       action: { _, done in
                           BuiltInFnKeyReader.requestAccess()
                           KoffeeLidController.shared.inputMonitoringChanged(); done()
                       },
                       mayOpen: "com.apple.systempreferences"),
        PermissionItem(id: .notifications,
                       title: L("Notifications"),
                       why: L("Tells you when KoffeeLid disarms itself (low battery, thermal pressure) or cannot lock the screen."),
                       granted: { notificationsGranted },
                       buttonTitle: L("Allow…"),
                       action: { _, done in requestNotifications(done) },
                       mayOpen: "com.apple.systempreferences"),
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
