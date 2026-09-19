import AppKit
import ServiceManagement
import KoffeeLidCore
import LidPlaneKit

/// The one Settings page. Everything a first-time user needs; the rest lives behind "Advanced settings…".
final class SettingsViewController: PaneViewController {
    private let prefs = Preferences.shared
    var onOpenAdvanced: (() -> Void)?
    private var permissionRows: [(item: PermissionItem, value: NSTextField, button: NSButton, remove: NSButton?)] = []
    private var keyObserver: NSObjectProtocol?
    /// A hook action taken from the Hooks group below can flip `armOnActivity` on; kept so
    /// `refreshPermissions()` can reflect that back onto this switch without rebuilding the page.
    private var armOnActivitySwitch: NSSwitch?

    override func build(_ f: SettingsForm) {
        f.header(L("App"))
        // SMAppService is the source of truth: the user can revoke the login item in
        // System Settings without the app ever hearing about it.
        let loginItemEnabled = SMAppService.mainApp.status == .enabled
        prefs.launchAtLogin = loginItemEnabled
        f.group { g in
            g.row(L("Launch at login"), SettingsForm.switch(loginItemEnabled) { [prefs] on in
                do {
                    if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    prefs.launchAtLogin = on
                } catch {
                    DiagnosticLog.shared.log("launch at login \(on ? "register" : "unregister") failed: \(error.localizedDescription)")
                }
            })
        }

        f.header(L("Arm with"))
        let sensor = LidAngleSensor.isPresent
        f.group { g in
            g.row(prefs.gestureModifier.gestureName, SettingsForm.switch(prefs.armWithOption && sensor) { [prefs] in prefs.armWithOption = $0 })
            g.row(L("Right-click menu bar icon"), SettingsForm.switch(prefs.armWithRightClick) { [prefs] in prefs.armWithRightClick = $0 })
            g.row(L("Armed shortcut"), SettingsForm.switch(prefs.armWithShortcut) { [prefs] in prefs.armWithShortcut = $0 },
                  detail: HotKeyController.describe(code: prefs.hotKeyCode, modifiers: prefs.hotKeyModifiers))
            g.row(L("Armed + screen on shortcut"), SettingsForm.switch(prefs.armWithCaffeinateShortcut) { [prefs] in prefs.armWithCaffeinateShortcut = $0 },
                  detail: HotKeyController.describe(code: prefs.caffeinateHotKeyCode, modifiers: prefs.caffeinateHotKeyModifiers))
            let activitySwitch = SettingsForm.switch(prefs.armOnActivity) { [prefs] in prefs.armOnActivity = $0 }
            armOnActivitySwitch = activitySwitch
            g.row(L("While Claude Code or a terminal command is running"), activitySwitch)
        }
        f.note(sensor ? String(format: L("%@ arms one close. Menu bar and keyboard shortcut arming stay on until you turn KoffeeLid off. Armed + screen on also keeps the display from sleeping."), prefs.gestureModifier.gestureName)
                      : L("The lid gesture needs a Mac with a lid-angle sensor. Right-click arming and the keyboard shortcut still work."))

        f.header(L("While KoffeeLid is armed"))
        let names = LidCloseSoundPlayer.soundNames
        f.group { g in
            g.row(L("Lid effect"), SettingsForm.switch(prefs.effect.enabled) { [prefs] in var e = prefs.effect; e.enabled = $0; prefs.effect = e })
            g.row(L("Lid-close sound"),
                  SettingsForm.popup([L("Blip pop"), L("Bloop"), L("Chime blip"), L("Enter"), L("Notification"), L("Tick")], selected: names.firstIndex(of: prefs.lidCloseSoundName) ?? 0) { [prefs] i in
                      prefs.lidCloseSoundName = names[i]; KoffeeLidController.shared.soundPlayer.preview(named: names[i])
                  },
                  SettingsForm.switch(prefs.lidCloseSoundEnabled) { [prefs] in prefs.lidCloseSoundEnabled = $0 })
            g.row(L("Force volume for lid-close sound"), SettingsForm.switch(prefs.forceVolumeEnabled) { [prefs] in prefs.forceVolumeEnabled = $0 })
            g.sliderRow(min: 0, max: 1, value: Double(prefs.forceVolumeLevel), ticks: 11, fmt: { "\(Int(($0 * 100).rounded()))%" }) { [prefs] in prefs.forceVolumeLevel = Float($0) }
            g.row(L("Low-battery disarm"), SettingsForm.switch(prefs.lowBatteryDisarm) { [prefs] in prefs.lowBatteryDisarm = $0 })
            g.sliderRow(min: 5, max: 50, value: Double(prefs.lowBatteryDisarmPercent), ticks: 10, fmt: { "\(Int($0.rounded()))%" }) { [prefs] in prefs.lowBatteryDisarmPercent = Int($0.rounded()) }
        }
        f.note(L("Forced volume unmutes and sets the output level only while the sound plays, then restores your volume. Your Mac locks whenever the lid reopens."))

        f.header(L("Permissions"))
        f.group { g in
            for item in PermissionCatalog.items {
                let value = SettingsForm.value("")
                let button = SettingsForm.button(item.buttonTitle, { [weak self] in
                    item.action(self?.view.window) { self?.refreshPermissions() }
                })
                permissionRows.append((item, value, button, nil))
                g.row(item.title, value, button)
            }
        }
        f.note(L("The sleep lock and Login Items are required for a closed Mac to stay awake safely. The lid effect needs Screen Recording; after allowing it, quit and reopen KoffeeLid. Input Monitoring makes the lid gesture ignore an external keyboard's Fn key."))

        f.header(L("Hooks"))
        f.group { g in
            for item in HookCatalog.items {
                let value = SettingsForm.value("")
                let button = SettingsForm.button(item.buttonTitle, { [weak self] in
                    item.action(self?.view.window) { self?.refreshPermissions() }
                })
                let remove = item.remove.map { action in
                    SettingsForm.button(item.removeTitle ?? L("Remove"), { [weak self] in action(self?.view.window) { self?.refreshPermissions() } })
                }
                if let remove { g.row(item.title, value, button, remove) } else { g.row(item.title, value, button) }
                permissionRows.append((item, value, button, remove))
            }
        }
        f.note(L("Auto-arm arms only from Off, never shows in the menu bar and ends on its own once the work is over: half an hour after Claude Code, a minute after a command (Advanced). \"Disarm once finished\" in the menu ends your own arm a minute after the work is over."))
        refreshPermissions()

        f.link(L("Advanced settings…"), { [weak self] in self?.onOpenAdvanced?() })
    }

    /// Every row re-reads its grant; notifications are asynchronous and come in a second pass. A hook
    /// action can also have flipped `armOnActivity` on, so the switch above is brought back in sync too.
    private func refreshPermissions() {
        for (item, value, button, remove) in permissionRows {
            let granted = item.granted()
            value.stringValue = granted ? item.doneTitle : (item.required ? "⚠︎ " + item.pendingTitle : item.pendingTitle)
            value.textColor = granted ? .secondaryLabelColor : .systemOrange
            button.isHidden = granted
            remove?.isHidden = !granted
        }
        armOnActivitySwitch?.state = prefs.armOnActivity ? .on : .off
    }
    override func viewWillAppear() {
        super.viewWillAppear()
        refreshPermissions()
        PermissionCatalog.refreshNotifications { [weak self] in self?.refreshPermissions() }
        // Coming back from System Settings or the password dialog: re-read the grants.
        if keyObserver == nil, let w = view.window {
            keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: w, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshPermissions()
                    PermissionCatalog.refreshNotifications { self?.refreshPermissions() }
                }
            }
        }
    }
}
