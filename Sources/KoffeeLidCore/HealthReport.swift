import Foundation

// MARK: - The facts

/// Why KoffeeLid last turned itself off: one of the safety rails that end every arm.
public enum SafetyStopReason: Equatable {
    case lowBattery, thermal, externalSleep
}

/// The last time a safety rail ended an arm, since KoffeeLid started.
public struct SafetyStop: Equatable {
    public let reason: SafetyStopReason
    public let at: Date

    public init(reason: SafetyStopReason, at: Date) {
        self.reason = reason
        self.at = at
    }
}

/// What the reader of the built-in keyboard's own Fn key (Input Monitoring) says, in the page's terms.
public enum FnKeyReaderState: Equatable {
    /// Reading: only this Mac's Fn key arms the lid gesture.
    case reading
    /// No keyboard with the `Built-In` property was found.
    case noKeyboard
    /// The grant is there and the keyboard could not be opened, or has not been yet.
    case failed
}

/// The last Claude Code hook event that reached the activity journal.
public struct HookEventSeen: Equatable {
    /// The event's own name (`PostToolUse`): a detail for a bug report, never translated.
    public let name: String
    public let at: Date

    public init(name: String, at: Date) {
        self.name = name
        self.at = at
    }
}

/// Everything the Health page reports, as values. The app gathers them (the grants and the lid from the
/// Settings window's poll, KoffeeLid's own state from the coordinator, the rest from `HealthCheck` when the
/// page is shown); `HealthReport` turns them into the page's two tables, so what a fact reads as, in which
/// colour and with which sentence, is decided here and tested. A reading nobody has taken yet is nil.
public struct HealthFacts: Equatable {
    public var now: Date

    // Polled with the rest of the window.
    public var held: Set<SettingsGrant>
    public var sensorPresent: Bool
    public var lidAngle: Double?

    // The arm, from the coordinator.
    public var mode: ArmMode
    public var armed: Bool
    /// A one-close arm from the lid gesture.
    public var oneCloseArm: Bool
    /// The command line's status line: the whole arm in one line, the State reading's tooltip.
    public var statusLine: String
    /// KoffeeLid's last write of the kernel's lid-sleep flag: true while lid sleep is off.
    public var lidSleepFlagSet: Bool
    /// A clear of the flag failed and is being retried.
    public var lidSleepRestorePending: Bool
    public var sleepLockEngaged: Bool
    public var lastSafetyStop: SafetyStop?

    // What decides whether Input Monitoring is doing its job.
    public var gestureEnabled: Bool
    public var gestureUsesFn: Bool
    public var fnReader: FnKeyReaderState

    // The hooks' last word.
    public var lastClaudeEvent: HookEventSeen?
    public var lastTerminalEventAt: Date?

    // Read when the page is shown.
    /// Whether the crash watchdog runs; nil until read.
    public var watchdogRunning: Bool?
    public var agentPlistName: String
    /// How many of the Claude Code hook events point at this copy of KoffeeLid; nil until read or when the
    /// settings file could not be read.
    public var claudeHookEvents: Int?
    public var claudeSettingsUnreadable: Bool
    /// When each crash report of KoffeeLid in the last `HealthConstants.crashWindow` was written, newest first.
    public var recentCrashes: [Date]

    public init(now: Date, held: Set<SettingsGrant>, sensorPresent: Bool, lidAngle: Double?, mode: ArmMode,
                armed: Bool, oneCloseArm: Bool, statusLine: String, lidSleepFlagSet: Bool,
                lidSleepRestorePending: Bool, sleepLockEngaged: Bool, lastSafetyStop: SafetyStop?,
                gestureEnabled: Bool, gestureUsesFn: Bool, fnReader: FnKeyReaderState,
                lastClaudeEvent: HookEventSeen?, lastTerminalEventAt: Date?, watchdogRunning: Bool?,
                agentPlistName: String, claudeHookEvents: Int?, claudeSettingsUnreadable: Bool,
                recentCrashes: [Date]) {
        self.now = now
        self.held = held
        self.sensorPresent = sensorPresent
        self.lidAngle = lidAngle
        self.mode = mode
        self.armed = armed
        self.oneCloseArm = oneCloseArm
        self.statusLine = statusLine
        self.lidSleepFlagSet = lidSleepFlagSet
        self.lidSleepRestorePending = lidSleepRestorePending
        self.sleepLockEngaged = sleepLockEngaged
        self.lastSafetyStop = lastSafetyStop
        self.gestureEnabled = gestureEnabled
        self.gestureUsesFn = gestureUsesFn
        self.fnReader = fnReader
        self.lastClaudeEvent = lastClaudeEvent
        self.lastTerminalEventAt = lastTerminalEventAt
        self.watchdogRunning = watchdogRunning
        self.agentPlistName = agentPlistName
        self.claudeHookEvents = claudeHookEvents
        self.claudeSettingsUnreadable = claudeSettingsUnreadable
        self.recentCrashes = recentCrashes
    }
}

// MARK: - The lines, before their words

/// Which line of the Health table, whatever its words say. The raw value is the line's stable identity.
public enum HealthItemID: String, CaseIterable {
    case sleepLock, lidSleep, crashWatchdog, screenRecording, inputMonitoring, notifications
    case claudeHooks, zshHook, lidSensor, crashes
}

/// Which line of the Information table. The raw value is the line's stable identity.
public enum HealthReadingID: String, CaseIterable {
    case state, lidAngle, lastClaudeEvent, lastTerminalCommand, lastSafetyStop
}

/// A span of time, to the minute, in the two largest units that mean anything. The app words it.
public enum HealthDuration: Equatable {
    case lessThanAMinute
    case minutes(Int)
    case hours(Int, minutes: Int)
    case days(Int, hours: Int)

    public init(seconds: TimeInterval) {
        let total = max(0, Int(seconds))
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 {
            self = .days(days, hours: hours)
        } else if hours > 0 {
            self = .hours(hours, minutes: minutes)
        } else if minutes > 0 {
            self = .minutes(minutes)
        } else {
            self = .lessThanAMinute
        }
    }
}

/// The word at a check's trailing edge, before it is put in a language.
public enum HealthWord: Equatable {
    case granted, denied, enabled, disabled, available, missing, failed, running, stopped
    case count(Int)
}

/// A reading's value, before it is put in a language.
public enum HealthValue: Equatable {
    /// The manual mode, as the menu names it.
    case mode(ArmMode)
    case autoArmed, armedForOneClose
    case degrees(Int)
    /// This long ago.
    case ago(HealthDuration)
    case noneYet
    case safetyStop(SafetyStopReason, ago: HealthDuration)
}

/// What only a bug report needs about a line, before it is put in a language: the row's tooltip.
public enum HealthDetail: Equatable {
    /// Shown as it is: a file name, the command line's status line.
    case text(String)
    /// What the sleep lock is made of.
    case sudoersRule
    /// A moment, stamped the same in every language.
    case at(Date)
    case lastCrash(Date)
    /// A hook event's own name and when it came.
    case event(String, at: Date)
    case hookEvents(installed: Int, of: Int)
    /// `~/.claude/settings.json` exists and could not be read.
    case settingsUnreadable
}

/// How to put a line right, before it is put in a language. Each names the page or the pane it is done in.
public enum HealthFix: Equatable {
    case screenRecording, inputMonitoring, notifications
    case setUpSleepLock, sleepLockDidNotEngage, sleepLockStillOn
    case lidSleepOnWhileArmed, lidSleepRestorePending
    case backgroundActivity, crashWatchStopped
    case noBuiltInKeyboard, fnKeyUnreadable
    case setUpClaudeCode, setUpTerminal
    case noLidSensor, crashes
}

/// One line of the Health table, with everything decided but its words.
public struct HealthItem: Equatable {
    public let id: HealthItemID
    public let level: HealthLevel
    public let word: HealthWord
    public let detail: HealthDetail?
    /// Carried whatever the level; the page shows it only while the line is orange or red.
    public let fix: HealthFix?

    public init(_ id: HealthItemID, _ level: HealthLevel, _ word: HealthWord, detail: HealthDetail? = nil,
                fix: HealthFix? = nil) {
        self.id = id
        self.level = level
        self.word = word
        self.detail = detail
        self.fix = fix
    }
}

/// One line of the Information table, with everything decided but its words.
public struct HealthReading: Equatable {
    public let id: HealthReadingID
    public let value: HealthValue
    public let detail: HealthDetail?

    public init(_ id: HealthReadingID, _ value: HealthValue, detail: HealthDetail? = nil) {
        self.id = id
        self.value = value
        self.detail = detail
    }
}

// MARK: - The report

/// The Health page's two tables: the checks, green, orange or red, and the readings, blue.
///
/// **A check is something that has to be in place or running for KoffeeLid to work**: the sleep lock, the
/// kernel's lid-sleep flag while armed, the crash watchdog, the three permissions, the two hooks, the lid
/// angle sensor. Red is what stops KoffeeLid from keeping a closed Mac awake, or from doing it safely: a
/// grant the onboarding marks required (the sleep lock, Background App Activity), the lid-sleep flag not
/// held while armed, a sleep lock that did not engage. Everything that degrades a feature is orange. A
/// preference is never a check, whichever way it is set, and neither is a reading: the battery, the heat,
/// the displays, the version, the memory are on no table.
public enum HealthReport {
    /// The Health table, in page order. Every line is there always, except the lid-sleep flag and the crashes,
    /// which have nothing to say while they are fine and are a line only while they are wrong.
    public static func checks(for facts: HealthFacts) -> [HealthItem] {
        var items = [sleepLock(facts)]
        if let lidSleep = lidSleep(facts) { items.append(lidSleep) }
        items.append(crashWatchdog(facts))
        items.append(grant(.screenRecording, .screenRecording, facts: facts, yes: .granted, no: .denied,
                           fix: .screenRecording))
        items.append(inputMonitoring(facts))
        items.append(grant(.notifications, .notifications, facts: facts, yes: .granted, no: .denied,
                           fix: .notifications))
        let hookDetail: HealthDetail? = facts.claudeSettingsUnreadable ? .settingsUnreadable
            : facts.claudeHookEvents.map { .hookEvents(installed: $0, of: HookConfig.events.count) }
        items.append(grant(.claudeHooks, .claudeHooks, facts: facts, yes: .enabled, no: .disabled,
                           detail: hookDetail, fix: .setUpClaudeCode))
        items.append(grant(.zshHook, .zshHook, facts: facts, yes: .enabled, no: .disabled, fix: .setUpTerminal))
        items.append(HealthItem(.lidSensor, HealthRules.lidSensor(present: facts.sensorPresent),
                                facts.sensorPresent ? .available : .missing, fix: .noLidSensor))
        if let last = facts.recentCrashes.first {
            items.append(HealthItem(.crashes, .warning, .count(facts.recentCrashes.count), detail: .lastCrash(last),
                                    fix: .crashes))
        }
        return items
    }

    /// The Information table, in page order: what KoffeeLid is doing, the lid's angle, the last word of each
    /// hook that is set up, and the last time a safety rail ended an arm. A reading with nothing to say is
    /// left out.
    public static func readings(for facts: HealthFacts) -> [HealthReading] {
        var readings: [HealthReading] = []

        // Armed with the manual mode Off is the auto level alone.
        let state: HealthValue = !facts.armed ? .mode(.off)
            : facts.oneCloseArm ? .armedForOneClose
            : facts.mode == .off ? .autoArmed
            : .mode(facts.mode)
        readings.append(HealthReading(.state, state, detail: facts.statusLine.isEmpty ? nil : .text(facts.statusLine)))

        if facts.sensorPresent, let angle = facts.lidAngle {
            readings.append(HealthReading(.lidAngle, .degrees(Int(angle))))
        }
        if facts.held.contains(.claudeHooks) {
            readings.append(facts.lastClaudeEvent.map {
                HealthReading(.lastClaudeEvent, .ago(since($0.at, facts)), detail: .event($0.name, at: $0.at))
            } ?? HealthReading(.lastClaudeEvent, .noneYet))
        }
        if facts.held.contains(.zshHook) {
            readings.append(facts.lastTerminalEventAt.map {
                HealthReading(.lastTerminalCommand, .ago(since($0, facts)), detail: .at($0))
            } ?? HealthReading(.lastTerminalCommand, .noneYet))
        }
        if let stop = facts.lastSafetyStop {
            readings.append(HealthReading(.lastSafetyStop, .safetyStop(stop.reason, ago: since(stop.at, facts)),
                                          detail: .at(stop.at)))
        }
        return readings
    }

    private static func since(_ date: Date, _ facts: HealthFacts) -> HealthDuration {
        HealthDuration(seconds: facts.now.timeIntervalSince(date))
    }

    /// A grant's line: green while held; missing, red when the onboarding marks it required, orange otherwise.
    static func grant(_ grant: SettingsGrant, _ id: HealthItemID, facts: HealthFacts, yes: HealthWord,
                      no: HealthWord, detail: HealthDetail? = nil, fix: HealthFix) -> HealthItem {
        let held = facts.held.contains(grant)
        return HealthItem(id, HealthRules.grant(held: held, required: grant.isRequired), held ? yes : no,
                          detail: detail, fix: fix)
    }

    /// The sleep lock is a grant (a sudoers rule) that must also do its job: engaged for as long as an arm
    /// runs, released once it ends.
    static func sleepLock(_ facts: HealthFacts) -> HealthItem {
        guard facts.held.contains(.sleepLock) else {
            return grant(.sleepLock, .sleepLock, facts: facts, yes: .available, no: .missing, detail: .sudoersRule,
                         fix: .setUpSleepLock)
        }
        if facts.armed && !facts.sleepLockEngaged {
            return HealthItem(.sleepLock, .failure, .failed, detail: .sudoersRule, fix: .sleepLockDidNotEngage)
        }
        if !facts.armed && facts.sleepLockEngaged {
            return HealthItem(.sleepLock, .warning, .failed, detail: .sudoersRule, fix: .sleepLockStillOn)
        }
        return HealthItem(.sleepLock, .good, .available, detail: .sudoersRule, fix: .setUpSleepLock)
    }

    /// The kernel's lid-sleep flag, only while it disagrees with the arm: on while armed (red), still off
    /// after the arm ended (orange).
    static func lidSleep(_ facts: HealthFacts) -> HealthItem? {
        guard let level = HealthRules.lidSleep(armed: facts.armed, flagSet: facts.lidSleepFlagSet,
                                               restorePending: facts.lidSleepRestorePending) else { return nil }
        return level == .failure
            ? HealthItem(.lidSleep, level, .enabled, fix: .lidSleepOnWhileArmed)
            : HealthItem(.lidSleep, level, .disabled, fix: .lidSleepRestorePending)
    }

    /// What brings KoffeeLid back, and the Mac's normal sleep with it, after it dies: Background App Activity,
    /// which lets the agent run, and the watchdog the agent runs. One line: without the first the second
    /// cannot run, and the first is the one to fix.
    static func crashWatchdog(_ facts: HealthFacts) -> HealthItem {
        let detail = HealthDetail.text(facts.agentPlistName)
        guard facts.held.contains(.loginItems) else {
            return HealthItem(.crashWatchdog, HealthRules.grant(held: false, required: SettingsGrant.loginItems.isRequired),
                              .disabled, detail: detail, fix: .backgroundActivity)
        }
        if facts.watchdogRunning == false {
            return HealthItem(.crashWatchdog, .warning, .stopped, detail: detail, fix: .crashWatchStopped)
        }
        return HealthItem(.crashWatchdog, .good, .running, detail: detail, fix: .backgroundActivity)
    }

    /// Input Monitoring is there for one thing, reading this Mac's own Fn key for the lid gesture. Granted and
    /// that reader not reading, while the gesture uses Fn, is a grant that does not do its job.
    static func inputMonitoring(_ facts: HealthFacts) -> HealthItem {
        let line = grant(.inputMonitoring, .inputMonitoring, facts: facts, yes: .granted, no: .denied,
                         fix: .inputMonitoring)
        guard facts.held.contains(.inputMonitoring), facts.gestureEnabled, facts.gestureUsesFn else { return line }
        switch facts.fnReader {
        case .reading: return line
        case .noKeyboard: return HealthItem(.inputMonitoring, .warning, .failed, fix: .noBuiltInKeyboard)
        case .failed: return HealthItem(.inputMonitoring, .warning, .failed, fix: .fnKeyUnreadable)
        }
    }

    /// A moment as a tooltip wants it: the same in every language, sortable, to the minute, in the Mac's own
    /// time zone.
    public static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
