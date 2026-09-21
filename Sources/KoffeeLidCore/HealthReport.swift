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
/// page is shown); `HealthReport.sections(for:)` turns them into the page's lines, so what a fact reads as,
/// in which colour and with which sentence, is decided here and tested. A reading nobody has taken yet is
/// nil, and its line is left out.
public struct HealthFacts: Equatable {
    public var now: Date

    // Polled with the rest of the window.
    public var held: Set<SettingsGrant>
    public var loginItem: LoginItemState
    public var sensorPresent: Bool
    public var lidAngle: Double?
    public var workingSessions: Int
    public var runningJobs: Int

    // The arm, from the coordinator.
    public var mode: ArmMode
    public var armed: Bool
    /// A one-close arm from the lid gesture.
    public var oneCloseArm: Bool
    /// The command line's status line: the whole arm in one line, for a bug report.
    public var statusLine: String
    /// KoffeeLid's last write of the kernel's lid-sleep flag: true while lid sleep is off.
    public var lidSleepFlagSet: Bool
    /// A clear of the flag failed and is being retried.
    public var lidSleepRestorePending: Bool
    public var sleepLockEngaged: Bool
    public var lastSafetyStop: SafetyStop?

    // Settings the lines depend on.
    public var gestureEnabled: Bool
    public var gestureUsesFn: Bool
    public var effectEnabled: Bool
    public var autoArmEnabled: Bool
    public var lowBatteryRail: Bool
    public var lowBatteryPercent: Int

    // Readings of KoffeeLid's own.
    public var fnReader: FnKeyReaderState
    /// `KOFFEELID_DISABLE_ACTIVITY=1` in the app's environment: auto-arm is off whatever the switch says.
    public var activityDisabledByEnvironment: Bool
    public var lastClaudeEvent: HookEventSeen?
    public var lastTerminalEventAt: Date?

    // Read when the page is shown.
    public var displays: DisplayTopology?
    public var battery: BatteryState?
    public var thermal: ThermalLevel?
    /// Whether the crash watchdog runs; nil until read.
    public var watchdogRunning: Bool?
    public var watchdogPath: String
    public var agentPlistName: String
    /// When the watchdog last reopened KoffeeLid after it died.
    public var lastRelaunch: Date?
    /// How many of the Claude Code hook events point at this copy of KoffeeLid; nil until read or when the
    /// settings file could not be read.
    public var claudeHookEvents: Int?
    public var claudeSettingsUnreadable: Bool
    /// How long this process has been running, nil when the system would not say.
    public var runningSeconds: TimeInterval?
    /// The memory this process holds, as Activity Monitor counts it; nil when the system would not say.
    public var memoryBytes: UInt64?
    /// When each crash report of KoffeeLid in the last `HealthConstants.crashWindow` was written, newest first.
    public var recentCrashes: [Date]
    public var location: AppLocation?
    /// Where the running bundle is, for the location row's tooltip and the report.
    public var bundlePath: String

    public init(now: Date, held: Set<SettingsGrant>, loginItem: LoginItemState, sensorPresent: Bool,
                lidAngle: Double?, workingSessions: Int, runningJobs: Int, mode: ArmMode, armed: Bool,
                oneCloseArm: Bool, statusLine: String, lidSleepFlagSet: Bool, lidSleepRestorePending: Bool,
                sleepLockEngaged: Bool, lastSafetyStop: SafetyStop?, gestureEnabled: Bool, gestureUsesFn: Bool,
                effectEnabled: Bool, autoArmEnabled: Bool, lowBatteryRail: Bool, lowBatteryPercent: Int,
                fnReader: FnKeyReaderState, activityDisabledByEnvironment: Bool, lastClaudeEvent: HookEventSeen?,
                lastTerminalEventAt: Date?, displays: DisplayTopology?, battery: BatteryState?,
                thermal: ThermalLevel?, watchdogRunning: Bool?, watchdogPath: String, agentPlistName: String,
                lastRelaunch: Date?, claudeHookEvents: Int?, claudeSettingsUnreadable: Bool,
                runningSeconds: TimeInterval?, memoryBytes: UInt64?, recentCrashes: [Date],
                location: AppLocation?, bundlePath: String) {
        self.now = now
        self.held = held
        self.loginItem = loginItem
        self.sensorPresent = sensorPresent
        self.lidAngle = lidAngle
        self.workingSessions = workingSessions
        self.runningJobs = runningJobs
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
        self.effectEnabled = effectEnabled
        self.autoArmEnabled = autoArmEnabled
        self.lowBatteryRail = lowBatteryRail
        self.lowBatteryPercent = lowBatteryPercent
        self.fnReader = fnReader
        self.activityDisabledByEnvironment = activityDisabledByEnvironment
        self.lastClaudeEvent = lastClaudeEvent
        self.lastTerminalEventAt = lastTerminalEventAt
        self.displays = displays
        self.battery = battery
        self.thermal = thermal
        self.watchdogRunning = watchdogRunning
        self.watchdogPath = watchdogPath
        self.agentPlistName = agentPlistName
        self.lastRelaunch = lastRelaunch
        self.claudeHookEvents = claudeHookEvents
        self.claudeSettingsUnreadable = claudeSettingsUnreadable
        self.runningSeconds = runningSeconds
        self.memoryBytes = memoryBytes
        self.recentCrashes = recentCrashes
        self.location = location
        self.bundlePath = bundlePath
    }
}

// MARK: - The lines, before their words

/// The page's groups, in page order. The raw value is the group's stable identity.
public enum HealthSectionID: String, CaseIterable {
    case permissions, stayingAwake, power, afterCrash, lid, autoArm, compatibility, app
}

/// Which line of the Health page, whatever its words say. The raw value is the line's stable identity.
public enum HealthItemID: String, CaseIterable {
    case screenRecording, inputMonitoring, notifications
    case mode, lidSleep, sleepLock, displays, lastSafetyStop
    case battery, thermal
    case backgroundActivity, crashWatch, lastRelaunch
    case lidGesture, builtInFnKey, lidEffect
    case autoArm, claudeHooks, lastClaudeEvent, zshHook, lastTerminalCommand, workNow
    case lidSensor, lidAngle
    case launchAtLogin, runningFor, memory, crashes, location
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

/// The word at a line's trailing edge, before it is put in a language.
public enum HealthWord: Equatable {
    case granted, denied, enabled, disabled, available, missing, failed, running, stopped, none, noneYet
    /// The manual mode, as the menu names it.
    case mode(ArmMode)
    case autoArmed, armedForOneClose
    case displaysConnected(Int)
    /// This long ago.
    case ago(HealthDuration)
    case safetyStop(SafetyStopReason, ago: HealthDuration)
    case battery(percent: Int, pluggedIn: Bool)
    case thermal(ThermalLevel)
    case degrees(Int)
    case duration(HealthDuration)
    case megabytes(Int)
    case count(Int)
    case location(AppLocation)
    case work(sessions: Int, commands: Int)
}

/// What only a bug report needs about a line, before it is put in a language.
public enum HealthDetail: Equatable {
    /// Shown as it is: a path, an identifier, the command line's status line.
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
    case displaysUnreadable
    case lowBattery, thermal
    case backgroundActivity, crashWatchStopped
    case noBuiltInKeyboard, fnKeyUnreadable
    case activityDisabledByEnvironment, setUpClaudeCode, setUpTerminal
    case noLidSensor
    case loginItemNeedsApproval, crashes, location
}

/// One line of the page, with everything decided but its words.
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

/// One group of the page, with everything decided but its words. A group with no line is not drawn.
public struct HealthSection: Equatable {
    public let id: HealthSectionID
    public let items: [HealthItem]

    public init(_ id: HealthSectionID, _ items: [HealthItem]) {
        self.id = id
        self.items = items
    }
}

// MARK: - The report

/// The Health page's lines, and the text Copy Report puts on the clipboard.
///
/// **Red is what stops KoffeeLid from keeping a closed Mac awake, or from doing it safely**: a grant the
/// onboarding marks required (the sleep lock, Background App Activity), the lid-sleep flag not held while
/// armed, a sleep lock that did not engage, and a display list that cannot be read, which refuses every arm.
/// Everything that degrades a feature without stopping that is orange, and so is a safety rail refusing an
/// arm for now (a battery under the rail, serious thermal pressure): the rail is doing its job and clears on
/// its own. A reading, or a switch the user turned off, is blue.
public enum HealthReport {
    /// The groups under the overview, in page order. A group none of whose lines applies is left out.
    public static func sections(for facts: HealthFacts) -> [HealthSection] {
        [
            HealthSection(.permissions, permissions(facts)),
            HealthSection(.stayingAwake, stayingAwake(facts)),
            HealthSection(.power, power(facts)),
            HealthSection(.afterCrash, afterCrash(facts)),
            HealthSection(.lid, lid(facts)),
            HealthSection(.autoArm, autoArm(facts)),
            HealthSection(.compatibility, compatibility(facts)),
            HealthSection(.app, app(facts)),
        ].filter { !$0.items.isEmpty }
    }

    /// A grant's line: green while held; missing, red when the onboarding marks it required, orange
    /// otherwise.
    static func grant(_ grant: SettingsGrant, _ id: HealthItemID, facts: HealthFacts, yes: HealthWord,
                      no: HealthWord, detail: HealthDetail? = nil, fix: HealthFix) -> HealthItem {
        let held = facts.held.contains(grant)
        return HealthItem(id, HealthRules.grant(held: held, required: grant.isRequired), held ? yes : no,
                          detail: detail, fix: fix)
    }

    static func permissions(_ facts: HealthFacts) -> [HealthItem] {
        [grant(.screenRecording, .screenRecording, facts: facts, yes: .granted, no: .denied, fix: .screenRecording),
         grant(.inputMonitoring, .inputMonitoring, facts: facts, yes: .granted, no: .denied, fix: .inputMonitoring),
         grant(.notifications, .notifications, facts: facts, yes: .granted, no: .denied, fix: .notifications)]
    }

    /// The mechanism: what KoffeeLid is doing, whether the kernel flag and the sleep lock hold it, and the
    /// displays the arm depends on.
    static func stayingAwake(_ facts: HealthFacts) -> [HealthItem] {
        var items: [HealthItem] = []

        // Armed with the manual mode Off is the auto level alone.
        let mode: HealthWord = !facts.armed ? .mode(.off)
            : facts.oneCloseArm ? .armedForOneClose
            : facts.mode == .off ? .autoArmed
            : .mode(facts.mode)
        items.append(HealthItem(.mode, .info, mode, detail: facts.statusLine.isEmpty ? nil : .text(facts.statusLine)))

        let lidSleepOff = facts.lidSleepFlagSet || facts.lidSleepRestorePending
        let lidSleepFix: HealthFix? = facts.armed && !facts.lidSleepFlagSet && !facts.lidSleepRestorePending
            ? .lidSleepOnWhileArmed : .lidSleepRestorePending
        items.append(HealthItem(.lidSleep,
                                HealthRules.lidSleep(armed: facts.armed, flagSet: facts.lidSleepFlagSet,
                                                     restorePending: facts.lidSleepRestorePending),
                                lidSleepOff ? .disabled : .enabled, fix: lidSleepFix))

        items.append(sleepLock(facts))

        if let displays = facts.displays {
            let word: HealthWord = !displays.verified ? .failed
                : displays.externalCount == 0 ? .none : .displaysConnected(displays.externalCount)
            items.append(HealthItem(.displays, HealthRules.displays(displays), word, fix: .displaysUnreadable))
        }

        if let stop = facts.lastSafetyStop {
            items.append(HealthItem(.lastSafetyStop, .info,
                                    .safetyStop(stop.reason, ago: HealthDuration(seconds: facts.now.timeIntervalSince(stop.at))),
                                    detail: .at(stop.at)))
        }
        return items
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

    /// The two rails that refuse an arm by themselves: the battery against the level the user chose, and heat.
    static func power(_ facts: HealthFacts) -> [HealthItem] {
        var items: [HealthItem] = []
        if let battery = facts.battery {
            items.append(HealthItem(.battery,
                                    HealthRules.battery(battery, railOn: facts.lowBatteryRail,
                                                        railPercent: facts.lowBatteryPercent),
                                    .battery(percent: battery.percent, pluggedIn: !battery.onBattery), fix: .lowBattery))
        }
        if let thermal = facts.thermal {
            items.append(HealthItem(.thermal, HealthRules.thermal(thermal), .thermal(thermal), fix: .thermal))
        }
        return items
    }

    /// What brings KoffeeLid back, and the Mac's normal sleep with it, after it dies.
    static func afterCrash(_ facts: HealthFacts) -> [HealthItem] {
        var items = [grant(.loginItems, .backgroundActivity, facts: facts, yes: .enabled, no: .disabled,
                           detail: .text(facts.agentPlistName), fix: .backgroundActivity)]
        // Without the agent the watchdog cannot run, and the line above already says so.
        if facts.held.contains(.loginItems), let running = facts.watchdogRunning {
            items.append(HealthItem(.crashWatch, running ? .good : .warning, running ? .running : .stopped,
                                    detail: .text(facts.watchdogPath), fix: .crashWatchStopped))
        }
        if let relaunch = facts.lastRelaunch {
            items.append(HealthItem(.lastRelaunch, .info, .ago(HealthDuration(seconds: facts.now.timeIntervalSince(relaunch))),
                                    detail: .at(relaunch)))
        }
        return items
    }

    /// The lid gesture and the lid effect. Without the sensor neither exists, and Compatibility says so.
    static func lid(_ facts: HealthFacts) -> [HealthItem] {
        guard facts.sensorPresent else { return [] }
        var items = [HealthItem(.lidGesture, HealthRules.preference(on: facts.gestureEnabled),
                                facts.gestureEnabled ? .enabled : .disabled)]
        // Only the Fn gesture reads the built-in keyboard, and only with the grant; without it the permission
        // line above is the one to fix.
        if facts.gestureEnabled, facts.gestureUsesFn, facts.held.contains(.inputMonitoring) {
            switch facts.fnReader {
            case .reading: items.append(HealthItem(.builtInFnKey, .good, .available))
            case .noKeyboard: items.append(HealthItem(.builtInFnKey, .warning, .missing, fix: .noBuiltInKeyboard))
            case .failed: items.append(HealthItem(.builtInFnKey, .warning, .failed, fix: .fnKeyUnreadable))
            }
        }
        items.append(HealthItem(.lidEffect, HealthRules.preference(on: facts.effectEnabled),
                                facts.effectEnabled ? .enabled : .disabled))
        return items
    }

    /// Auto-arm: the switch, each of the two hooks with the last thing it reported, and the work it counts.
    static func autoArm(_ facts: HealthFacts) -> [HealthItem] {
        var items: [HealthItem] = []
        if facts.autoArmEnabled && facts.activityDisabledByEnvironment {
            items.append(HealthItem(.autoArm, .warning, .disabled, detail: .text("KOFFEELID_DISABLE_ACTIVITY=1"),
                                    fix: .activityDisabledByEnvironment))
        } else {
            items.append(HealthItem(.autoArm, HealthRules.preference(on: facts.autoArmEnabled),
                                    facts.autoArmEnabled ? .enabled : .disabled))
        }

        let hookDetail: HealthDetail? = facts.claudeSettingsUnreadable ? .settingsUnreadable
            : facts.claudeHookEvents.map { .hookEvents(installed: $0, of: HookConfig.events.count) }
        items.append(grant(.claudeHooks, .claudeHooks, facts: facts, yes: .enabled, no: .disabled,
                           detail: hookDetail, fix: .setUpClaudeCode))
        if facts.held.contains(.claudeHooks) {
            if let event = facts.lastClaudeEvent {
                items.append(HealthItem(.lastClaudeEvent, .info, .ago(HealthDuration(seconds: facts.now.timeIntervalSince(event.at))),
                                        detail: .event(event.name, at: event.at)))
            } else {
                items.append(HealthItem(.lastClaudeEvent, .info, .noneYet))
            }
        }

        items.append(grant(.zshHook, .zshHook, facts: facts, yes: .enabled, no: .disabled, fix: .setUpTerminal))
        if facts.held.contains(.zshHook) {
            if let at = facts.lastTerminalEventAt {
                items.append(HealthItem(.lastTerminalCommand, .info, .ago(HealthDuration(seconds: facts.now.timeIntervalSince(at))),
                                        detail: .at(at)))
            } else {
                items.append(HealthItem(.lastTerminalCommand, .info, .noneYet))
            }
        }

        let idle = facts.workingSessions == 0 && facts.runningJobs == 0
        items.append(HealthItem(.workNow, .info,
                                idle ? .none : .work(sessions: facts.workingSessions, commands: facts.runningJobs)))
        return items
    }

    static func compatibility(_ facts: HealthFacts) -> [HealthItem] {
        var items = [HealthItem(.lidSensor, HealthRules.lidSensor(present: facts.sensorPresent),
                                facts.sensorPresent ? .available : .missing, fix: .noLidSensor)]
        // Nothing to report until the sensor has been read once.
        if facts.sensorPresent, let angle = facts.lidAngle {
            items.append(HealthItem(.lidAngle, .info, .degrees(Int(angle))))
        }
        return items
    }

    /// What every app of the family reports about itself: whether it comes back at login, how long it has
    /// been up, what it holds, whether it has crashed, and whether it is installed at all.
    static func app(_ facts: HealthFacts) -> [HealthItem] {
        var items = [HealthItem(.launchAtLogin, HealthRules.loginItem(facts.loginItem),
                                facts.loginItem == .enabled ? .enabled : .disabled, fix: .loginItemNeedsApproval)]
        if let seconds = facts.runningSeconds {
            items.append(HealthItem(.runningFor, .info, .duration(HealthDuration(seconds: seconds))))
        }
        if let bytes = facts.memoryBytes {
            items.append(HealthItem(.memory, .info, .megabytes(Int((Double(bytes) / 1_048_576).rounded()))))
        }
        let crashes = facts.recentCrashes.count
        items.append(HealthItem(.crashes, HealthRules.crashes(crashes), crashes == 0 ? .none : .count(crashes),
                                detail: facts.recentCrashes.first.map { .lastCrash($0) }, fix: .crashes))
        if let location = facts.location {
            items.append(HealthItem(.location, HealthRules.location(location), .location(location),
                                    detail: .text(facts.bundlePath), fix: .location))
        }
        return items
    }

    // MARK: The copied report

    /// The copied report: which app and which system, the summary, then every group of the page with one
    /// line per row, its level, its word and its detail. Written for a bug report, so nothing in it is a
    /// secret: no prompt, no command, no file's contents reach the page.
    public static func text(appName: String, version: String, system: String, summary: String,
                            groups: [HealthGroup]) -> String {
        var lines = ["\(appName) \(version), \(system)", summary]
        for group in groups {
            lines.append("")
            lines.append(group.title)
            for row in group.rows {
                var line = "\(tag(row.level)) \(row.label): \(row.word)"
                if let detail = row.detail, !detail.isEmpty { line += " (\(detail))" }
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func tag(_ level: HealthLevel) -> String {
        switch level {
        case .info: "[INFO]"
        case .good: "[OK]  "
        case .warning: "[WARN]"
        case .failure: "[FAIL]"
        }
    }

    /// A moment as a bug report wants it: the same in every language, sortable, to the minute, in the Mac's
    /// own time zone.
    public static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
