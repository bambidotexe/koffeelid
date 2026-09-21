import Foundation
import KoffeeLidCore

/// The Health page's words. Core decides every line (which, in which colour, with which fix); this puts
/// each in the user's language, through the string catalog like every other sentence of the window. A label
/// shared with another page is the same key, so a state reads the same wherever it shows.
@MainActor
enum HealthWords {
    static func groups(_ sections: [HealthSection]) -> [HealthGroup] {
        sections.map { section in
            HealthGroup(id: section.id.rawValue, title: title(section.id), rows: section.items.map { item in
                HealthRow(id: item.id.rawValue, label: label(item.id), level: item.level, word: word(item.word),
                          detail: item.detail.map(detail), fix: item.fix.map(fix))
            })
        }
    }

    /// The first row's word: everything works, how many lines to look at, or how many stop KoffeeLid.
    static func summary(_ summary: HealthSummary) -> String {
        switch summary.level {
        case .failure:
            summary.blocking == 1 ? L("Not working: 1 problem")
                : String(format: L("Not working: %d problems"), summary.blocking)
        case .warning:
            summary.toLookAt == 1 ? L("1 thing to look at") : String(format: L("%d things to look at"), summary.toLookAt)
        case .good, .info:
            L("Everything works")
        }
    }

    static func title(_ id: HealthSectionID) -> String {
        switch id {
        case .permissions: L("Permissions")
        case .stayingAwake: L("Staying awake safely")
        case .power: L("Battery and heat")
        case .afterCrash: L("After a crash")
        case .lid: L("Lid gesture and effect")
        case .autoArm: L("While you work")
        case .compatibility: L("Compatibility")
        case .app: L("App")
        }
    }

    static func label(_ id: HealthItemID) -> String {
        switch id {
        case .screenRecording: L("Screen Recording permission")
        case .inputMonitoring: L("Input Monitoring permission")
        case .notifications: L("Notifications permission")
        case .mode: L("Mode")
        case .lidSleep: L("Lid sleep")
        case .sleepLock: L("Sleep lock")
        case .displays: L("External displays")
        case .lastSafetyStop: L("Last turned itself off")
        case .battery: L("Battery")
        case .thermal: L("Thermal pressure")
        case .backgroundActivity: L("KoffeeLid in “Background App Activity”")
        case .crashWatch: L("Crash recovery")
        case .lastRelaunch: L("Last reopened after a crash")
        case .lidGesture: L("Lid gesture")
        case .builtInFnKey: L("This Mac's own 🌐 Fn key")
        case .lidEffect: L("Lid effect")
        case .autoArm: L("Auto-arm")
        case .claudeHooks: L("Claude Code hooks")
        case .lastClaudeEvent: L("Last Claude Code event")
        case .zshHook: L("Terminal hook (zsh)")
        case .lastTerminalCommand: L("Last terminal command")
        case .workNow: L("Work running now")
        case .lidSensor: L("Lid angle sensor")
        case .lidAngle: L("Lid angle now")
        case .launchAtLogin: L("Launch at login")
        case .runningFor: L("Running for")
        case .memory: L("Memory used")
        case .crashes: String(format: L("Crashes in the last %d days"), Int(HealthConstants.crashWindow / 86_400))
        case .location: L("Installed in")
        }
    }

    static func word(_ word: HealthWord) -> String {
        switch word {
        case .granted: L("Granted")
        case .denied: L("Denied")
        case .enabled: L("Enabled")
        case .disabled: L("Disabled")
        case .available: L("Available")
        case .missing: L("Missing")
        case .failed: L("Failed")
        case .running: L("Running")
        case .stopped: L("Stopped")
        case .none: L("None")
        case .noneYet: L("None yet")
        case .mode(let mode): StatusItemController.title(for: mode)
        case .autoArmed: L("Auto-armed")
        case .armedForOneClose: L("Armed for one close")
        case .displaysConnected(let count):
            count == 1 ? L("1 connected") : String(format: L("%d connected"), count)
        case .ago(let span): ago(span)
        case .safetyStop(let reason, let span):
            span == .lessThanAMinute ? String(format: L("%@, just now"), stopReason(reason))
                : String(format: L("%@, %@ ago"), stopReason(reason), duration(span))
        case .battery(let percent, let pluggedIn):
            String(format: pluggedIn ? L("%d%%, plugged in") : L("%d%%, on battery"), percent)
        case .thermal(let level): thermal(level)
        case .degrees(let degrees): SettingsFormat.degrees(Double(degrees))
        case .duration(let span): duration(span)
        case .megabytes(let count): String(format: L("%d MB"), count)
        case .count(let count): "\(count)"
        case .location(let location): self.location(location)
        case .work(let sessions, let commands): String(format: L("Claude Code: %d, commands: %d"), sessions, commands)
        }
    }

    static func detail(_ detail: HealthDetail) -> String {
        switch detail {
        case .text(let text): text
        case .sudoersRule: L("A sudoers rule for /usr/bin/pmset disablesleep")
        case .at(let date): HealthReport.stamp(date)
        case .lastCrash(let date): String(format: L("Last one %@"), HealthReport.stamp(date))
        // The event's own name, as Claude Code sends it: a detail for a bug report, in no language.
        case .event(let name, let date): "\(name), \(HealthReport.stamp(date))"
        case .hookEvents(let installed, let total):
            String(format: L("%d of %d hook events point at this copy of KoffeeLid"), installed, total)
        case .settingsUnreadable: L("~/.claude/settings.json could not be read")
        }
    }

    static func fix(_ fix: HealthFix) -> String {
        switch fix {
        case .screenRecording:
            L("In System Settings › Privacy & Security › Screen Recording, turn KoffeeLid on.")
        case .inputMonitoring:
            L("In System Settings › Privacy & Security › Input Monitoring, turn KoffeeLid on.")
        case .notifications:
            L("In System Settings › Notifications › KoffeeLid, turn on “Allow notifications”.")
        case .setUpSleepLock:
            L("Set up the sleep lock on the System page. It asks for your administrator password once.")
        case .sleepLockDidNotEngage:
            L("The sleep lock did not turn on for this arm, so plugging in the charger or a display change can still sleep your closed Mac. Turn KoffeeLid off, then arm it again.")
        case .sleepLockStillOn:
            L("KoffeeLid could not run pmset to allow sleep again. Run `sudo pmset disablesleep 0` in Terminal.")
        case .lidSleepOnWhileArmed:
            L("KoffeeLid is armed but lid sleep is on, so your Mac sleeps when the lid closes. Turn KoffeeLid off, then arm it again.")
        case .lidSleepRestorePending:
            L("KoffeeLid is retrying. Until the warning icon clears, open the lid before leaving your Mac; restarting the Mac always resets this setting.")
        case .displaysUnreadable:
            L("KoffeeLid could not verify the display setup. Disconnect any additional displays and try again.")
        case .lowBattery:
            L("On battery at this level, KoffeeLid does not arm. Plug in your Mac, or lower the battery level on the Arming page.")
        case .thermal:
            L("Your Mac is too hot for KoffeeLid to arm. Let it cool down.")
        case .backgroundActivity:
            L("In System Settings › General › Login Items, turn KoffeeLid on under “Background App Activity”.")
        case .crashWatchStopped:
            L("Quit and reopen KoffeeLid to start it again. Until then, a crash while armed leaves your Mac unable to sleep.")
        case .noBuiltInKeyboard:
            L("KoffeeLid cannot find this Mac's keyboard, so any keyboard's 🌐 Fn key arms the lid gesture.")
        case .fnKeyUnreadable:
            L("Quit and reopen KoffeeLid so it can read this Mac's 🌐 Fn key. Until then, any keyboard's 🌐 Fn key arms the lid gesture.")
        case .activityDisabledByEnvironment:
            L("KoffeeLid was started with auto-arm turned off. Quit it and open it again from the Applications folder.")
        case .setUpClaudeCode:
            L("Set up Claude Code on the Auto-Arm page.")
        case .setUpTerminal:
            L("Set up the terminal on the Auto-Arm page, then open a new terminal window.")
        case .noLidSensor:
            L("This Mac has no lid angle sensor, so the lid gesture and the lid effect are not available. Everything else works.")
        case .loginItemNeedsApproval:
            L("In System Settings › General › Login Items, turn KoffeeLid on under “Open at Login”.")
        case .crashes:
            L("Console shows what happened, under “Crash Reports”. Copy the report below to send it along.")
        case .location:
            L("Quit KoffeeLid, drag it to the Applications folder, and open it from there. Where it runs now, it cannot update itself.")
        }
    }

    // MARK: Readings

    /// How long something has run, to the minute, in the two largest units that mean anything.
    static func duration(_ span: HealthDuration) -> String {
        switch span {
        case .lessThanAMinute: L("Less than a minute")
        case .minutes(let minutes): String(format: L("%d min"), minutes)
        case .hours(let hours, let minutes): String(format: L("%d h %d min"), hours, minutes)
        case .days(let days, let hours): String(format: L("%d d %d h"), days, hours)
        }
    }

    static func ago(_ span: HealthDuration) -> String {
        span == .lessThanAMinute ? L("Just now") : String(format: L("%@ ago"), duration(span))
    }

    static func stopReason(_ reason: SafetyStopReason) -> String {
        switch reason {
        case .lowBattery: L("Low battery")
        case .thermal: L("Thermal pressure")
        case .externalSleep: L("Mac put to sleep")
        }
    }

    static func thermal(_ level: ThermalLevel) -> String {
        switch level {
        case .nominal: L("Normal")
        case .fair: L("Moderate")
        case .serious: L("Serious")
        case .critical: L("Critical")
        }
    }

    static func location(_ location: AppLocation) -> String {
        switch location {
        // The folder's own name, which Finder does not translate.
        case .applications: "Applications"
        case .elsewhere(let folder): folder
        case .diskImage: L("Disk image")
        case .temporaryCopy: L("Temporary copy")
        }
    }
}
