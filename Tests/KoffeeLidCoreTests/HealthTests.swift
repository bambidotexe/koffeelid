import XCTest
import KoffeeLidCore

/// The Health page's rules: which line shows, in which colour, with which word and which fix; what the
/// overview sums up; which files are KoffeeLid's crash reports; and what the copied report says.
final class HealthTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    /// A Mac on which everything is as it should be, KoffeeLid idle.
    private func healthy() -> HealthFacts {
        HealthFacts(now: now, held: Set(SettingsGrant.allCases), loginItem: .enabled, sensorPresent: true,
                    lidAngle: 112, workingSessions: 0, runningJobs: 0, mode: .off, armed: false, oneCloseArm: false,
                    statusLine: "mode: off · lid: open", lidSleepFlagSet: false, lidSleepRestorePending: false,
                    sleepLockEngaged: false, lastSafetyStop: nil, gestureEnabled: true, gestureUsesFn: true,
                    effectEnabled: true, autoArmEnabled: true, lowBatteryRail: true, lowBatteryPercent: 10,
                    fnReader: .reading, activityDisabledByEnvironment: false,
                    lastClaudeEvent: HookEventSeen(name: "Stop", at: now.addingTimeInterval(-600)),
                    lastTerminalEventAt: now.addingTimeInterval(-30),
                    displays: DisplayTopology(builtInCount: 1, externalCount: 0, verified: true),
                    battery: BatteryState(percent: 80, onBattery: false), thermal: .nominal, watchdogRunning: true,
                    watchdogPath: "/Applications/KoffeeLid.app/Contents/MacOS/KoffeeLidWatchdog",
                    agentPlistName: "dev.rubens.koffeelid.agent.plist", lastRelaunch: nil, claudeHookEvents: 15,
                    claudeSettingsUnreadable: false, runningSeconds: 3_720, memoryBytes: 48 * 1_048_576,
                    recentCrashes: [], location: .applications, bundlePath: "/Applications/KoffeeLid.app")
    }

    private func items(_ facts: HealthFacts) -> [HealthItem] {
        HealthReport.sections(for: facts).flatMap(\.items)
    }

    private func item(_ id: HealthItemID, _ facts: HealthFacts) -> HealthItem? {
        items(facts).first { $0.id == id }
    }

    private func summary(_ facts: HealthFacts) -> HealthSummary {
        HealthSummary(sections: HealthReport.sections(for: facts))
    }

    // MARK: The whole page

    func testAHealthyMacReadsGreenAndBlue() {
        let facts = healthy()
        XCTAssertEqual(summary(facts).level, .good)
        XCTAssertTrue(items(facts).allSatisfy { $0.level == .good || $0.level == .info })
        XCTAssertEqual(HealthReport.sections(for: facts).map(\.id),
                       [.permissions, .stayingAwake, .power, .afterCrash, .lid, .autoArm, .compatibility, .app])
    }

    func testEveryLineHasAStableIdentityOnce() {
        let ids = items(healthy()).map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
    }

    // MARK: Grants: red when the onboarding marks them required, orange otherwise, never blue

    func testEveryMissingGrantFollowsTheOnboardingsRequiredMark() {
        let lines: [SettingsGrant: HealthItemID] = [
            .sleepLock: .sleepLock, .loginItems: .backgroundActivity, .screenRecording: .screenRecording,
            .inputMonitoring: .inputMonitoring, .notifications: .notifications, .claudeHooks: .claudeHooks,
            .zshHook: .zshHook,
        ]
        for (grant, id) in lines {
            var facts = healthy()
            facts.held.remove(grant)
            let line = item(id, facts)
            XCTAssertEqual(line?.level, grant.isRequired ? .failure : .warning, grant.rawValue)
            XCTAssertNotNil(line?.fix, grant.rawValue)
            XCTAssertEqual(summary(facts).level, grant.isRequired ? .failure : .warning, grant.rawValue)
        }
    }

    func testAPermissionReadsGrantedOrDenied() {
        var facts = healthy()
        facts.held.remove(.screenRecording)
        XCTAssertEqual(item(.screenRecording, facts)?.word, .denied)
        XCTAssertEqual(item(.screenRecording, facts)?.fix, .screenRecording)
        XCTAssertEqual(item(.inputMonitoring, facts)?.word, .granted)
    }

    func testAMissingSleepLockIsRedAndSaysWhereToSetItUp() {
        var facts = healthy()
        facts.held.remove(.sleepLock)
        let line = item(.sleepLock, facts)
        XCTAssertEqual(line?.level, .failure)
        XCTAssertEqual(line?.word, .missing)
        XCTAssertEqual(line?.fix, .setUpSleepLock)
        XCTAssertEqual(line?.detail, .sudoersRule)
    }

    // MARK: Staying awake safely

    func testTheModeIsAReading() {
        var facts = healthy()
        XCTAssertEqual(item(.mode, facts)?.word, .mode(.off))
        facts.armed = true
        facts.mode = .caffeinate
        XCTAssertEqual(item(.mode, facts)?.word, .mode(.caffeinate))
        facts.mode = .off
        XCTAssertEqual(item(.mode, facts)?.word, .autoArmed)
        facts.mode = .armed
        facts.oneCloseArm = true
        XCTAssertEqual(item(.mode, facts)?.word, .armedForOneClose)
        XCTAssertEqual(item(.mode, facts)?.level, .info)
        XCTAssertEqual(item(.mode, facts)?.detail, .text("mode: off · lid: open"))
    }

    func testLidSleepFollowsTheArm() {
        XCTAssertEqual(HealthRules.lidSleep(armed: false, flagSet: false, restorePending: false), .good)
        XCTAssertEqual(HealthRules.lidSleep(armed: true, flagSet: true, restorePending: false), .good)
        XCTAssertEqual(HealthRules.lidSleep(armed: true, flagSet: false, restorePending: false), .failure)
        XCTAssertEqual(HealthRules.lidSleep(armed: false, flagSet: true, restorePending: false), .warning)
        XCTAssertEqual(HealthRules.lidSleep(armed: false, flagSet: true, restorePending: true), .warning)

        var facts = healthy()
        XCTAssertEqual(item(.lidSleep, facts)?.word, .enabled)
        facts.armed = true
        facts.mode = .armed
        facts.sleepLockEngaged = true
        facts.lidSleepFlagSet = true
        XCTAssertEqual(item(.lidSleep, facts)?.word, .disabled)
        XCTAssertEqual(item(.lidSleep, facts)?.level, .good)
        facts.lidSleepFlagSet = false
        XCTAssertEqual(item(.lidSleep, facts)?.level, .failure)
        XCTAssertEqual(item(.lidSleep, facts)?.fix, .lidSleepOnWhileArmed)
    }

    func testALidSleepThatCouldNotBeGivenBackIsOrangeLikeTheCup() {
        var facts = healthy()
        facts.lidSleepFlagSet = true
        facts.lidSleepRestorePending = true
        let line = item(.lidSleep, facts)
        XCTAssertEqual(line?.level, .warning)
        XCTAssertEqual(line?.word, .disabled)
        XCTAssertEqual(line?.fix, .lidSleepRestorePending)
    }

    func testTheSleepLockMustHoldWhileArmedAndLetGoAfterwards() {
        var facts = healthy()
        facts.armed = true
        facts.mode = .armed
        facts.lidSleepFlagSet = true
        facts.sleepLockEngaged = true
        XCTAssertEqual(item(.sleepLock, facts)?.level, .good)
        XCTAssertEqual(item(.sleepLock, facts)?.word, .available)

        facts.sleepLockEngaged = false
        XCTAssertEqual(item(.sleepLock, facts)?.level, .failure)
        XCTAssertEqual(item(.sleepLock, facts)?.word, .failed)
        XCTAssertEqual(item(.sleepLock, facts)?.fix, .sleepLockDidNotEngage)

        facts = healthy()
        facts.sleepLockEngaged = true
        XCTAssertEqual(item(.sleepLock, facts)?.level, .warning)
        XCTAssertEqual(item(.sleepLock, facts)?.fix, .sleepLockStillOn)
    }

    func testAnUnreadableDisplayListRefusesEveryArm() {
        var facts = healthy()
        facts.displays = DisplayTopology(builtInCount: 0, externalCount: 0, verified: false)
        XCTAssertEqual(item(.displays, facts)?.level, .failure)
        XCTAssertEqual(item(.displays, facts)?.fix, .displaysUnreadable)

        facts.displays = DisplayTopology(builtInCount: 1, externalCount: 2, verified: true)
        XCTAssertEqual(item(.displays, facts)?.level, .info)
        XCTAssertEqual(item(.displays, facts)?.word, .displaysConnected(2))

        XCTAssertEqual(item(.displays, healthy())?.word, HealthWord.none)
        facts.displays = nil
        XCTAssertNil(item(.displays, facts), "not read yet: no line")
    }

    func testTheLastSafetyStopIsAReadingWithItsReason() {
        var facts = healthy()
        XCTAssertNil(item(.lastSafetyStop, facts))
        facts.lastSafetyStop = SafetyStop(reason: .lowBattery, at: now.addingTimeInterval(-300))
        let line = item(.lastSafetyStop, facts)
        XCTAssertEqual(line?.level, .info)
        XCTAssertEqual(line?.word, .safetyStop(.lowBattery, ago: .minutes(5)))
        XCTAssertEqual(line?.detail, .at(now.addingTimeInterval(-300)))
    }

    // MARK: Battery and heat

    /// The rail doing its job is not KoffeeLid failing: orange, and it clears once plugged in.
    func testABatteryUnderTheRailOnBatteryRefusesEveryArm() {
        let low = BatteryState(percent: 8, onBattery: true)
        XCTAssertEqual(HealthRules.battery(low, railOn: true, railPercent: 10), .warning)
        XCTAssertEqual(HealthRules.battery(BatteryState(percent: 10, onBattery: true), railOn: true, railPercent: 10), .warning)
        XCTAssertEqual(HealthRules.battery(BatteryState(percent: 11, onBattery: true), railOn: true, railPercent: 10), .info)
        XCTAssertEqual(HealthRules.battery(BatteryState(percent: 8, onBattery: false), railOn: true, railPercent: 10), .info)
        XCTAssertEqual(HealthRules.battery(low, railOn: false, railPercent: 10), .info)

        var facts = healthy()
        facts.battery = low
        XCTAssertEqual(item(.battery, facts)?.word, .battery(percent: 8, pluggedIn: false))
        XCTAssertEqual(item(.battery, facts)?.fix, .lowBattery)
        XCTAssertEqual(summary(facts).level, .warning)
    }

    func testSeriousHeatRefusesEveryArm() {
        XCTAssertEqual(HealthRules.thermal(.nominal), .good)
        XCTAssertEqual(HealthRules.thermal(.fair), .good)
        XCTAssertEqual(HealthRules.thermal(.serious), .warning)
        XCTAssertEqual(HealthRules.thermal(.critical), .warning)
        var facts = healthy()
        facts.thermal = .critical
        XCTAssertEqual(item(.thermal, facts)?.word, .thermal(.critical))
        XCTAssertEqual(item(.thermal, facts)?.fix, .thermal)
    }

    // MARK: After a crash

    func testAStoppedWatchdogIsWorthALook() {
        var facts = healthy()
        facts.watchdogRunning = false
        let line = item(.crashWatch, facts)
        XCTAssertEqual(line?.level, .warning)
        XCTAssertEqual(line?.word, .stopped)
        XCTAssertEqual(line?.fix, .crashWatchStopped)
        XCTAssertEqual(item(.crashWatch, healthy())?.word, .running)
    }

    func testWithoutTheAgentOnlyTheAgentsLineSpeaks() {
        var facts = healthy()
        facts.held.remove(.loginItems)
        facts.watchdogRunning = false
        XCTAssertNil(item(.crashWatch, facts))
        XCTAssertEqual(item(.backgroundActivity, facts)?.level, .failure)
        XCTAssertEqual(summary(facts).blocking, 1)
        XCTAssertEqual(summary(facts).toLookAt, 0)
    }

    func testTheLastRelaunchIsAReading() {
        var facts = healthy()
        XCTAssertNil(item(.lastRelaunch, facts))
        facts.lastRelaunch = now.addingTimeInterval(-(2 * 86_400 + 3 * 3_600))
        XCTAssertEqual(item(.lastRelaunch, facts)?.level, .info)
        XCTAssertEqual(item(.lastRelaunch, facts)?.word, .ago(.days(2, hours: 3)))
    }

    // MARK: The lid

    func testWithoutASensorTheLidFeaturesAreNotListed() {
        var facts = healthy()
        facts.sensorPresent = false
        XCTAssertFalse(HealthReport.sections(for: facts).map(\.id).contains(.lid))
        XCTAssertEqual(item(.lidSensor, facts)?.level, .warning)
        XCTAssertEqual(item(.lidSensor, facts)?.fix, .noLidSensor)
        XCTAssertNil(item(.lidAngle, facts))
    }

    func testASwitchTurnedOffIsTheUsersChoice() {
        var facts = healthy()
        facts.gestureEnabled = false
        facts.effectEnabled = false
        facts.autoArmEnabled = false
        for id in [HealthItemID.lidGesture, .lidEffect, .autoArm] {
            XCTAssertEqual(item(id, facts)?.level, .info, id.rawValue)
            XCTAssertEqual(item(id, facts)?.word, .disabled, id.rawValue)
        }
        XCTAssertEqual(summary(facts).level, .good)
    }

    func testTheBuiltInFnKeyIsReportedOnlyWhereItIsRead() {
        var facts = healthy()
        XCTAssertEqual(item(.builtInFnKey, facts)?.level, .good)

        facts.fnReader = .failed
        XCTAssertEqual(item(.builtInFnKey, facts)?.level, .warning)
        XCTAssertEqual(item(.builtInFnKey, facts)?.fix, .fnKeyUnreadable)
        facts.fnReader = .noKeyboard
        XCTAssertEqual(item(.builtInFnKey, facts)?.fix, .noBuiltInKeyboard)

        var option = facts
        option.gestureUsesFn = false
        XCTAssertNil(item(.builtInFnKey, option))
        var off = facts
        off.gestureEnabled = false
        XCTAssertNil(item(.builtInFnKey, off))
        var denied = facts
        denied.held.remove(.inputMonitoring)
        XCTAssertNil(item(.builtInFnKey, denied), "the permission line is the one to fix")
    }

    func testTheLidAngleIsAReading() {
        XCTAssertEqual(item(.lidAngle, healthy())?.word, .degrees(112))
        var facts = healthy()
        facts.lidAngle = nil
        XCTAssertNil(item(.lidAngle, facts), "nothing read yet")
    }

    // MARK: While you work

    func testAutoArmSwitchedOnButStoppedByTheEnvironmentIsWorthALook() {
        var facts = healthy()
        facts.activityDisabledByEnvironment = true
        XCTAssertEqual(item(.autoArm, facts)?.level, .warning)
        XCTAssertEqual(item(.autoArm, facts)?.fix, .activityDisabledByEnvironment)
        facts.autoArmEnabled = false
        XCTAssertEqual(item(.autoArm, facts)?.level, .info)
    }

    func testEachHookShowsTheLastThingItReported() {
        let facts = healthy()
        XCTAssertEqual(item(.lastClaudeEvent, facts)?.word, .ago(.minutes(10)))
        XCTAssertEqual(item(.lastClaudeEvent, facts)?.detail, .event("Stop", at: now.addingTimeInterval(-600)))
        XCTAssertEqual(item(.lastTerminalCommand, facts)?.word, .ago(.lessThanAMinute))
        XCTAssertEqual(item(.claudeHooks, facts)?.detail, .hookEvents(installed: 15, of: HookConfig.events.count))

        var quiet = facts
        quiet.lastClaudeEvent = nil
        quiet.lastTerminalEventAt = nil
        XCTAssertEqual(item(.lastClaudeEvent, quiet)?.word, .noneYet)
        XCTAssertEqual(item(.lastTerminalCommand, quiet)?.word, .noneYet)

        var unset = facts
        unset.held.subtract([.claudeHooks, .zshHook])
        XCTAssertNil(item(.lastClaudeEvent, unset))
        XCTAssertNil(item(.lastTerminalCommand, unset))
        XCTAssertEqual(item(.claudeHooks, unset)?.fix, .setUpClaudeCode)
        XCTAssertEqual(item(.zshHook, unset)?.fix, .setUpTerminal)
    }

    func testAnUnreadableClaudeSettingsFileIsSaidInTheDetail() {
        var facts = healthy()
        facts.claudeHookEvents = nil
        facts.claudeSettingsUnreadable = true
        facts.held.remove(.claudeHooks)
        XCTAssertEqual(item(.claudeHooks, facts)?.detail, .settingsUnreadable)
    }

    func testWorkRunningNowIsAReading() {
        var facts = healthy()
        XCTAssertEqual(item(.workNow, facts)?.word, HealthWord.none)
        facts.workingSessions = 2
        facts.runningJobs = 1
        XCTAssertEqual(item(.workNow, facts)?.word, .work(sessions: 2, commands: 1))
        XCTAssertEqual(item(.workNow, facts)?.level, .info)
    }

    // MARK: The App group

    func testALoginItemSwitchedOffHereIsOnlyWorthKnowing() {
        XCTAssertEqual(HealthRules.loginItem(.enabled), .good)
        XCTAssertEqual(HealthRules.loginItem(.disabled), .info)
        XCTAssertEqual(HealthRules.loginItem(.needsApproval), .warning)
        var facts = healthy()
        facts.loginItem = .needsApproval
        XCTAssertEqual(item(.launchAtLogin, facts)?.word, .disabled)
        XCTAssertEqual(item(.launchAtLogin, facts)?.fix, .loginItemNeedsApproval)
    }

    func testTheAppGroupReadsItsNumbers() {
        let facts = healthy()
        XCTAssertEqual(item(.runningFor, facts)?.word, .duration(.hours(1, minutes: 2)))
        XCTAssertEqual(item(.memory, facts)?.word, .megabytes(48))
        XCTAssertEqual(item(.crashes, facts)?.word, HealthWord.none)
        XCTAssertEqual(item(.location, facts)?.word, .location(.applications))
        XCTAssertEqual(item(.location, facts)?.detail, .text("/Applications/KoffeeLid.app"))
    }

    func testACrashIsCountedAndDated() {
        var facts = healthy()
        let crash = now.addingTimeInterval(-3_600)
        facts.recentCrashes = [crash, now.addingTimeInterval(-7_200)]
        let line = item(.crashes, facts)
        XCTAssertEqual(line?.level, .warning)
        XCTAssertEqual(line?.word, .count(2))
        XCTAssertEqual(line?.detail, .lastCrash(crash))
        XCTAssertEqual(HealthRules.crashes(0), .good)
    }

    func testAnAppThatIsNotInstalledIsWorthALook() {
        XCTAssertEqual(HealthRules.location(.applications), .good)
        XCTAssertEqual(HealthRules.location(.elsewhere(folder: "Tools")), .info)
        XCTAssertEqual(HealthRules.location(.diskImage), .warning)
        XCTAssertEqual(HealthRules.location(.temporaryCopy), .warning)
    }

    func testWhereTheBundleIs() {
        XCTAssertEqual(HealthRules.location(bundlePath: "/Applications/KoffeeLid.app", home: "/Users/a",
                                            readOnlyVolume: false), .applications)
        XCTAssertEqual(HealthRules.location(bundlePath: "/Users/a/Applications/KoffeeLid.app", home: "/Users/a",
                                            readOnlyVolume: false), .applications)
        XCTAssertEqual(HealthRules.location(bundlePath: "/Volumes/KoffeeLid/KoffeeLid.app", home: "/Users/a",
                                            readOnlyVolume: true), .diskImage)
        XCTAssertEqual(HealthRules.location(bundlePath: "/private/var/folders/x/AppTranslocation/1/d/KoffeeLid.app",
                                            home: "/Users/a", readOnlyVolume: true), .temporaryCopy)
        XCTAssertEqual(HealthRules.location(bundlePath: "/Users/a/Tools/KoffeeLid.app", home: "/Users/a",
                                            readOnlyVolume: false), .elsewhere(folder: "Tools"))
    }

    // MARK: The overview and the warnings

    func testRedWinsOverOrangeInTheOverview() {
        let rows = [HealthRow(id: "a", label: "A", level: .warning, word: "x"),
                    HealthRow(id: "b", label: "B", level: .failure, word: "x"),
                    HealthRow(id: "c", label: "C", level: .info, word: "x")]
        let summary = HealthSummary(groups: [HealthGroup(id: "g", title: "G", rows: rows)])
        XCTAssertEqual(summary.blocking, 1)
        XCTAssertEqual(summary.toLookAt, 1)
        XCTAssertEqual(summary.level, .failure)
    }

    func testBlueRowsCountForNothing() {
        XCTAssertEqual(HealthSummary(levels: [.info, .good, .info]).level, .good)
    }

    func testAFixIsShownOnlyWhileItsRowIsOrangeOrRed() {
        let fine = HealthRow(id: "a", label: "A", level: .good, word: "x", fix: "Do this.")
        let wrong = HealthRow(id: "b", label: "B", level: .warning, word: "x", fix: "Do that.")
        let twice = HealthRow(id: "c", label: "C", level: .failure, word: "x", fix: "Do that.")
        XCTAssertEqual(HealthGroup(id: "g", title: "G", rows: [fine, wrong, twice]).warnings, ["Do that."])
        XCTAssertEqual(HealthGroup(id: "g", title: "G", rows: [fine]).warnings, [])
    }

    func testEveryOrangeOrRedLineSaysHowToPutItRight() {
        var facts = healthy()
        facts.held = []
        facts.loginItem = .needsApproval
        facts.armed = true
        facts.mode = .armed
        facts.lidSleepFlagSet = false
        facts.displays = DisplayTopology(builtInCount: 0, externalCount: 0, verified: false)
        facts.battery = BatteryState(percent: 5, onBattery: true)
        facts.thermal = .serious
        facts.activityDisabledByEnvironment = true
        facts.recentCrashes = [now]
        facts.location = .diskImage
        let wrong = items(facts).filter { $0.level >= .warning }
        XCTAssertGreaterThan(wrong.count, 10)
        for line in wrong { XCTAssertNotNil(line.fix, line.id.rawValue) }
    }

    // MARK: Crash reports

    func testOnlyThisProcesssCrashReportsAreCounted() {
        XCTAssertTrue(HealthRules.isCrashReport(fileName: "KoffeeLid-2026-09-21-101010.ips", process: "KoffeeLid"))
        XCTAssertTrue(HealthRules.isCrashReport(fileName: "KoffeeLid-2026-09-21-101010.crash", process: "KoffeeLid"))
        XCTAssertTrue(HealthRules.isCrashReport(fileName: "KoffeeLid-2026-09-21-101010-1.ips", process: "KoffeeLid"))
        XCTAssertFalse(HealthRules.isCrashReport(fileName: "ExcUserFault_KoffeeLid-2026-09-21-101010.ips",
                                                  process: "KoffeeLid"))
        XCTAssertFalse(HealthRules.isCrashReport(fileName: "KoffeeLidWatchdog-2026-09-21-101010.ips",
                                                  process: "KoffeeLid"))
        XCTAssertFalse(HealthRules.isCrashReport(fileName: "KoffeeLid-notes.ips", process: "KoffeeLid"))
        XCTAssertFalse(HealthRules.isCrashReport(fileName: "KoffeeLid-2026-09-21-101010.diag", process: "KoffeeLid"))
    }

    func testOnlyRecentReportsOfThisProcessAreReadNewestFirst() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("crash-reports-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let today = Date()
        func write(_ name: String, at date: Date) throws {
            let file = folder.appendingPathComponent(name)
            try Data("{}".utf8).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        }
        try write("KoffeeLid-2026-09-20-101010.ips", at: today.addingTimeInterval(-3_600))
        try write("KoffeeLid-2026-09-21-101010.ips", at: today.addingTimeInterval(-60))
        try write("KoffeeLid-2026-09-01-101010.ips", at: today.addingTimeInterval(-20 * 86_400))
        try write("KoffeeLidWatchdog-2026-09-21-101010.ips", at: today)
        try write("ExcUserFault_KoffeeLid-2026-09-21-101010.ips", at: today)

        let dates = CrashReports.recent(process: "KoffeeLid", since: today.addingTimeInterval(-HealthConstants.crashWindow),
                                        in: [folder, folder.appendingPathComponent("Retired")])
        XCTAssertEqual(dates.count, 2)
        XCTAssertGreaterThan(dates[0], dates[1])
        XCTAssertEqual(CrashReports.recent(process: "KoffeeLid", since: .distantPast,
                                           in: [folder.appendingPathComponent("missing")]), [])
    }

    // MARK: Words and the report

    func testDurationsKeepTheTwoLargestUnits() {
        XCTAssertEqual(HealthDuration(seconds: 30), .lessThanAMinute)
        XCTAssertEqual(HealthDuration(seconds: -5), .lessThanAMinute)
        XCTAssertEqual(HealthDuration(seconds: 125), .minutes(2))
        XCTAssertEqual(HealthDuration(seconds: 3_720), .hours(1, minutes: 2))
        XCTAssertEqual(HealthDuration(seconds: 2 * 86_400 + 3 * 3_600 + 59), .days(2, hours: 3))
    }

    func testTheReportCarriesEveryRowWithItsLevel() {
        let groups = [HealthGroup(id: "app", title: "App", rows: [
            HealthRow(id: "login", label: "Launch at login", level: .good, word: "Enabled"),
            HealthRow(id: "memory", label: "Memory used", level: .info, word: "48 MB"),
            HealthRow(id: "location", label: "Installed in", level: .warning, word: "Disk image",
                      detail: "/Volumes/KoffeeLid/KoffeeLid.app"),
        ])]
        let text = HealthReport.text(appName: "KoffeeLid", version: "1.1.2", system: "macOS 27.0.0",
                                     summary: "1 thing to look at", groups: groups)
        XCTAssertTrue(text.hasPrefix("KoffeeLid 1.1.2, macOS 27.0.0\n1 thing to look at\n\nApp\n"))
        XCTAssertTrue(text.contains("[OK]   Launch at login: Enabled"))
        XCTAssertTrue(text.contains("[INFO] Memory used: 48 MB"))
        XCTAssertTrue(text.contains("[WARN] Installed in: Disk image (/Volumes/KoffeeLid/KoffeeLid.app)"))
    }

    func testAStampIsTheSameInEveryLanguage() {
        let stamp = HealthReport.stamp(now)
        XCTAssertEqual(stamp.count, "2026-09-21 10:10".count)
        XCTAssertTrue(stamp.hasPrefix("2026-"))
    }
}
