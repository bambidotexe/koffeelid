import Foundation
import KoffeeLidCore

/// The Health page's words. Core decides every line (which, in which colour, with which fix); this puts
/// each in the user's language, through the string catalog like every other sentence of the window. A label
/// shared with another page is the same key, so a state reads the same wherever it shows.
@MainActor
enum HealthWords {
    static func checks(_ items: [HealthItem]) -> [HealthRow] {
        items.map { item in
            HealthRow(id: item.id.rawValue, label: label(item.id), level: item.level, word: word(item.word),
                      detail: item.detail.map(detail), fix: item.fix.map(fix))
        }
    }

    static func readings(_ readings: [HealthReading]) -> [InfoRow] {
        readings.map { reading in
            InfoRow(id: reading.id.rawValue, label: label(reading.id), value: value(reading.value),
                    detail: reading.detail.map(detail))
        }
    }

    static func label(_ id: HealthItemID) -> String {
        switch id {
        case .sleepLock: L("Sleep lock")
        case .lidSleep: L("Lid sleep")
        case .crashWatchdog: L("Crash recovery")
        case .screenRecording: L("Screen Recording permission")
        case .inputMonitoring: L("Input Monitoring permission")
        case .notifications: L("Notifications permission")
        case .claudeHooks: L("Claude Code hooks")
        case .codexHooks: L("Codex hooks")
        case .zshHook: L("Terminal hook (zsh)")
        case .lidSensor: L("Lid angle sensor")
        case .crashes: String(format: L("Crashes in the last %d days"), Int(HealthConstants.crashWindow / 86_400))
        }
    }

    static func label(_ id: HealthReadingID) -> String {
        switch id {
        case .state: L("State")
        case .lidAngle: L("Lid angle now")
        case .lastClaudeEvent: L("Last Claude Code event")
        case .lastCodexEvent: L("Last Codex event")
        case .lastTerminalCommand: L("Last terminal command")
        case .lastSafetyStop: L("Last turned itself off")
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
        case .count(let count): "\(count)"
        }
    }

    static func value(_ value: HealthValue) -> String {
        switch value {
        case .mode(let mode): StatusItemController.title(for: mode)
        case .autoArmed: L("Auto-armed")
        case .armedForOneClose: L("Armed for one close")
        case .degrees(let degrees): SettingsFormat.degrees(Double(degrees))
        case .ago(let span): ago(span)
        case .noneYet: L("None yet")
        case .safetyStop(let reason, let span):
            span == .lessThanAMinute ? String(format: L("%@, just now"), stopReason(reason))
                : String(format: L("%@, %@ ago"), stopReason(reason), duration(span))
        }
    }

    static func detail(_ detail: HealthDetail) -> String {
        switch detail {
        case .text(let text): text
        case .sudoersRule: L("A sudoers rule for /usr/bin/pmset disablesleep")
        case .at(let date): HealthReport.stamp(date)
        case .lastCrash(let date): String(format: L("Last one %@"), HealthReport.stamp(date))
        // The event's own name, as the agent sends it: a detail for a bug report, in no language.
        case .event(let name, let date): "\(name), \(HealthReport.stamp(date))"
        case .hookEvents(let installed, let total):
            String(format: L("%d of %d hook events point at this copy of KoffeeLid"), installed, total)
        case .settingsUnreadable: L("~/.claude/settings.json could not be read")
        case .codexFilesUnreadable: L("~/.codex/hooks.json or ~/.codex/config.toml could not be read")
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
        case .backgroundActivity:
            L("In System Settings › General › Login Items, turn KoffeeLid on under “Background App Activity”.")
        case .crashWatchStopped:
            L("Quit and reopen KoffeeLid to start it again. Until then, a crash while armed leaves your Mac unable to sleep.")
        case .noBuiltInKeyboard:
            L("KoffeeLid cannot find this Mac's keyboard, so any keyboard's 🌐 Fn key arms the lid gesture.")
        case .fnKeyUnreadable:
            L("Quit and reopen KoffeeLid so it can read this Mac's 🌐 Fn key. Until then, any keyboard's 🌐 Fn key arms the lid gesture.")
        case .setUpClaudeCode:
            L("Set up Claude Code on the Auto-Arm page.")
        case .setUpCodex:
            L("Set up Codex on the Auto-Arm page.")
        case .setUpTerminal:
            L("Set up the terminal on the Auto-Arm page, then open a new terminal window.")
        case .noLidSensor:
            L("This Mac has no lid angle sensor, so the lid gesture and the lid effect are not available. Everything else works.")
        case .crashes:
            L("Console shows what happened, under “Crash Reports”.")
        }
    }

    // MARK: Readings

    /// How long ago, to the minute, in the two largest units that mean anything.
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
        case .thermal: L("Mac too hot")
        case .externalSleep: L("Mac put to sleep")
        }
    }
}
