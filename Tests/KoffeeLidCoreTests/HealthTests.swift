import XCTest
import KoffeeLidCore

/// The Health page's rules: which check shows, in which colour, with which word and which fix; which reading
/// shows and what it says; how long the two tables may grow; and which files are KoffeeLid's crash reports.
final class HealthTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    /// A Mac on which everything is as it should be, KoffeeLid idle.
    private func healthy() -> HealthFacts {
        HealthFacts(now: now, held: Set(SettingsGrant.allCases), sensorPresent: true, lidAngle: 112, mode: .off,
                    armed: false, oneCloseArm: false, statusLine: "mode: off · lid: open", lidSleepFlagSet: false,
                    lidSleepRestorePending: false, sleepLockEngaged: false, lastSafetyStop: nil,
                    gestureEnabled: true, gestureUsesFn: true, fnReader: .reading,
                    lastClaudeEvent: HookEventSeen(name: "Stop", at: now.addingTimeInterval(-600)),
                    lastCodexEvent: HookEventSeen(name: "Interrupt", at: now.addingTimeInterval(-120)),
                    lastCopilotEvent: HookEventSeen(name: "Stop", at: now.addingTimeInterval(-90)),
                    lastOpencodeEvent: HookEventSeen(name: "Stop", at: now.addingTimeInterval(-45)),
                    lastTerminalEventAt: now.addingTimeInterval(-30), watchdogRunning: true,
                    agentPlistName: "dev.rubens.koffeelid.agent.plist", claudeHookEvents: 15,
                    claudeSettingsUnreadable: false, codexHookEvents: 12, codexHooksUnreadable: false,
                    copilotHookEvents: 7, copilotHooksUnreadable: false, copilotHooksDisabled: false,
                    copilotOnThisMac: true, opencodeStale: false, opencodeOnThisMac: true, recentCrashes: [])
    }

    /// The same Mac, armed, with the flag and the lock holding.
    private func armed() -> HealthFacts {
        var facts = healthy()
        facts.armed = true
        facts.mode = .armed
        facts.lidSleepFlagSet = true
        facts.sleepLockEngaged = true
        return facts
    }

    private func check(_ id: HealthItemID, _ facts: HealthFacts) -> HealthItem? {
        HealthReport.checks(for: facts).first { $0.id == id }
    }

    private func reading(_ id: HealthReadingID, _ facts: HealthFacts) -> HealthReading? {
        HealthReport.readings(for: facts).first { $0.id == id }
    }

    // MARK: The Health table

    func testAHealthyMacIsAllGreenInPageOrder() {
        for facts in [healthy(), armed()] {
            let checks = HealthReport.checks(for: facts)
            XCTAssertTrue(checks.allSatisfy { $0.level == .good })
            XCTAssertEqual(checks.map(\.id), [.sleepLock, .crashWatchdog, .screenRecording, .inputMonitoring,
                                              .notifications, .claudeHooks, .codexHooks, .copilotHooks,
                                              .opencodeHooks, .zshHook, .lidSensor])
        }
    }

    func testEveryMissingGrantFollowsTheOnboardingsRequiredMark() {
        let lines: [SettingsGrant: HealthItemID] = [
            .sleepLock: .sleepLock, .loginItems: .crashWatchdog, .screenRecording: .screenRecording,
            .inputMonitoring: .inputMonitoring, .notifications: .notifications, .claudeHooks: .claudeHooks,
            .codexHooks: .codexHooks, .copilotHooks: .copilotHooks, .opencodeHooks: .opencodeHooks,
            .zshHook: .zshHook,
        ]
        for (grant, id) in lines {
            var facts = healthy()
            facts.held.remove(grant)
            let line = check(id, facts)
            XCTAssertEqual(line?.level, grant.isRequired ? .failure : .warning, grant.rawValue)
            XCTAssertNotNil(line?.fix, grant.rawValue)
        }
    }

    func testAPermissionReadsGrantedOrDenied() {
        var facts = healthy()
        facts.held.remove(.screenRecording)
        XCTAssertEqual(check(.screenRecording, facts)?.word, .denied)
        XCTAssertEqual(check(.screenRecording, facts)?.fix, .screenRecording)
        XCTAssertEqual(check(.inputMonitoring, facts)?.word, .granted)
    }

    func testTheSleepLockMustBeThereHoldWhileArmedAndLetGoAfterwards() {
        var facts = healthy()
        facts.held.remove(.sleepLock)
        XCTAssertEqual(check(.sleepLock, facts), HealthItem(.sleepLock, .failure, .missing, detail: .sudoersRule,
                                                            fix: .setUpSleepLock))
        facts = armed()
        facts.sleepLockEngaged = false
        XCTAssertEqual(check(.sleepLock, facts)?.level, .failure)
        XCTAssertEqual(check(.sleepLock, facts)?.fix, .sleepLockDidNotEngage)
        facts = healthy()
        facts.sleepLockEngaged = true
        XCTAssertEqual(check(.sleepLock, facts)?.level, .warning)
        XCTAssertEqual(check(.sleepLock, facts)?.fix, .sleepLockStillOn)
    }

    func testLidSleepIsALineOnlyWhileItDisagreesWithTheArm() {
        XCTAssertNil(check(.lidSleep, healthy()))
        XCTAssertNil(check(.lidSleep, armed()))

        var facts = armed()
        facts.lidSleepFlagSet = false
        XCTAssertEqual(check(.lidSleep, facts), HealthItem(.lidSleep, .failure, .enabled, fix: .lidSleepOnWhileArmed))
        XCTAssertEqual(HealthReport.checks(for: facts).map(\.id).prefix(2), [.sleepLock, .lidSleep])

        facts = healthy()
        facts.lidSleepRestorePending = true
        XCTAssertEqual(check(.lidSleep, facts),
                       HealthItem(.lidSleep, .warning, .disabled, fix: .lidSleepRestorePending))
    }

    func testTheCrashWatchdogIsOneLineForTheAgentAndTheProcess() {
        XCTAssertEqual(check(.crashWatchdog, healthy())?.word, .running)
        XCTAssertEqual(check(.crashWatchdog, healthy())?.detail, .text("dev.rubens.koffeelid.agent.plist"))

        var facts = healthy()
        facts.watchdogRunning = false
        XCTAssertEqual(check(.crashWatchdog, facts)?.level, .warning)
        XCTAssertEqual(check(.crashWatchdog, facts)?.word, .stopped)
        XCTAssertEqual(check(.crashWatchdog, facts)?.fix, .crashWatchStopped)

        // Without the agent the watchdog cannot run, and the agent is the one thing to fix.
        facts.held.remove(.loginItems)
        XCTAssertEqual(check(.crashWatchdog, facts)?.level, .failure)
        XCTAssertEqual(check(.crashWatchdog, facts)?.word, .disabled)
        XCTAssertEqual(check(.crashWatchdog, facts)?.fix, .backgroundActivity)

        // Not read yet is not a stopped watchdog.
        facts = healthy()
        facts.watchdogRunning = nil
        XCTAssertEqual(check(.crashWatchdog, facts)?.level, .good)
    }

    func testInputMonitoringMustAlsoReadThisMacsFnKeyWhenTheGestureUsesIt() {
        var facts = healthy()
        facts.fnReader = .noKeyboard
        XCTAssertEqual(check(.inputMonitoring, facts), HealthItem(.inputMonitoring, .warning, .failed,
                                                                  fix: .noBuiltInKeyboard))
        facts.fnReader = .failed
        XCTAssertEqual(check(.inputMonitoring, facts)?.fix, .fnKeyUnreadable)

        // The reader matters only while the gesture is on and uses Fn.
        facts.gestureUsesFn = false
        XCTAssertEqual(check(.inputMonitoring, facts)?.level, .good)
        facts.gestureUsesFn = true
        facts.gestureEnabled = false
        XCTAssertEqual(check(.inputMonitoring, facts)?.level, .good)

        // Without the grant, the grant is the one thing to fix.
        facts = healthy()
        facts.fnReader = .failed
        facts.held.remove(.inputMonitoring)
        XCTAssertEqual(check(.inputMonitoring, facts)?.word, .denied)
        XCTAssertEqual(check(.inputMonitoring, facts)?.fix, .inputMonitoring)
    }

    func testTheHooksSayHowManyEventsPointHere() {
        XCTAssertEqual(check(.claudeHooks, healthy())?.detail, .hookEvents(installed: 15, of: HookConfig.claude.events.count))
        XCTAssertEqual(check(.codexHooks, healthy())?.detail, .hookEvents(installed: 12, of: 12))
        XCTAssertEqual(check(.copilotHooks, healthy())?.detail, .hookEvents(installed: 7, of: CopilotHookFile.events.count))
        var facts = healthy()
        facts.claudeSettingsUnreadable = true
        facts.codexHooksUnreadable = true
        facts.copilotHooksUnreadable = true
        XCTAssertEqual(check(.claudeHooks, facts)?.detail, .settingsUnreadable)
        XCTAssertEqual(check(.codexHooks, facts)?.detail, .codexFilesUnreadable)
        XCTAssertEqual(check(.copilotHooks, facts)?.detail, .copilotFileUnreadable)
        facts.held.remove(.codexHooks)
        XCTAssertEqual(check(.codexHooks, facts)?.word, .disabled)
        XCTAssertEqual(check(.codexHooks, facts)?.fix, .setUpCodex)
        facts.held.remove(.zshHook)
        XCTAssertEqual(check(.zshHook, facts)?.word, .disabled)
        XCTAssertEqual(check(.zshHook, facts)?.fix, .setUpTerminal)
    }

    func testCopilotHooksDisabledIsItsOwnDetailDistinctFromTheCount() {
        var facts = healthy()
        facts.copilotHooksDisabled = true
        XCTAssertEqual(check(.copilotHooks, facts)?.detail, .copilotDisabled)
        XCTAssertEqual(check(.copilotHooks, facts)?.fix, .setUpCopilot)
    }

    func testOpenCodePluginIsStaleWhenOursButNotCurrent() {
        var facts = healthy()
        XCTAssertNil(check(.opencodeHooks, facts)?.detail)
        facts.opencodeStale = true
        XCTAssertEqual(check(.opencodeHooks, facts)?.detail, .opencodePluginStale)
        XCTAssertEqual(check(.opencodeHooks, facts)?.fix, .setUpOpencode)
    }

    func testCopilotAndOpenCodeAreLinesOnlyOnThisMacOrSetUp() {
        var facts = healthy()
        facts.copilotOnThisMac = false
        facts.opencodeOnThisMac = false
        XCTAssertNil(check(.copilotHooks, facts))
        XCTAssertNil(check(.opencodeHooks, facts))
        XCTAssertEqual(HealthReport.checks(for: facts).map(\.id), [.sleepLock, .crashWatchdog, .screenRecording,
                                                                   .inputMonitoring, .notifications, .claudeHooks,
                                                                   .codexHooks, .zshHook, .lidSensor])
        facts.copilotOnThisMac = true
        facts.opencodeOnThisMac = true
        XCTAssertNotNil(check(.copilotHooks, facts))
        XCTAssertNotNil(check(.opencodeHooks, facts))
    }

    func testAMacWithoutTheLidSensorIsWorthALook() {
        var facts = healthy()
        facts.sensorPresent = false
        XCTAssertEqual(check(.lidSensor, facts), HealthItem(.lidSensor, .warning, .missing, fix: .noLidSensor))
    }

    func testACrashIsALineOnlyWhileThereIsOne() {
        XCTAssertNil(check(.crashes, healthy()))
        var facts = healthy()
        facts.recentCrashes = [now, now.addingTimeInterval(-3_600)]
        XCTAssertEqual(check(.crashes, facts), HealthItem(.crashes, .warning, .count(2), detail: .lastCrash(now),
                                                          fix: .crashes))
        XCTAssertEqual(HealthReport.checks(for: facts).last?.id, .crashes)
    }

    func testAFixIsShownOnlyWhileItsRowIsOrangeOrRed() {
        let fine = HealthRow(id: "a", label: "A", level: .good, word: "x", fix: "Do this.")
        let wrong = HealthRow(id: "b", label: "B", level: .warning, word: "x", fix: "Do that.")
        let twice = HealthRow(id: "c", label: "C", level: .failure, word: "x", fix: "Do that.")
        XCTAssertEqual([fine, wrong, twice].warnings, ["Do that."])
        XCTAssertEqual([fine].warnings, [])
    }

    // MARK: The Information table

    func testTheReadingsOfAnIdleMac() {
        XCTAssertEqual(HealthReport.readings(for: healthy()).map(\.id),
                       [.state, .lidAngle, .lastClaudeEvent, .lastCodexEvent, .lastCopilotEvent,
                        .lastOpencodeEvent, .lastTerminalCommand])
        XCTAssertEqual(reading(.state, healthy()), HealthReading(.state, .mode(.off), detail: .text("mode: off · lid: open")))
        XCTAssertEqual(reading(.lidAngle, healthy())?.value, .degrees(112))
        XCTAssertEqual(reading(.lastClaudeEvent, healthy()),
                       HealthReading(.lastClaudeEvent, .ago(.minutes(10)),
                                     detail: .event("Stop", at: now.addingTimeInterval(-600))))
        XCTAssertEqual(reading(.lastCopilotEvent, healthy())?.value, .ago(.minutes(1)))
        XCTAssertEqual(reading(.lastOpencodeEvent, healthy())?.value, .ago(.lessThanAMinute))
        XCTAssertEqual(reading(.lastTerminalCommand, healthy())?.value, .ago(.lessThanAMinute))
    }

    func testTheStateSaysHowKoffeeLidIsArmed() {
        XCTAssertEqual(reading(.state, armed())?.value, .mode(.armed))
        var facts = armed()
        facts.mode = .off
        XCTAssertEqual(reading(.state, facts)?.value, .autoArmed)
        facts.oneCloseArm = true
        XCTAssertEqual(reading(.state, facts)?.value, .armedForOneClose)
    }

    func testAReadingWithNothingToSayIsLeftOut() {
        var facts = healthy()
        facts.lidAngle = nil
        XCTAssertNil(reading(.lidAngle, facts))
        facts = healthy()
        facts.sensorPresent = false
        XCTAssertNil(reading(.lidAngle, facts))

        // A hook that is not set up reports nothing; one that is set up and silent says so.
        facts = healthy()
        facts.held.remove(.claudeHooks)
        facts.held.remove(.codexHooks)
        facts.held.remove(.copilotHooks)
        facts.held.remove(.opencodeHooks)
        facts.held.remove(.zshHook)
        XCTAssertNil(reading(.lastClaudeEvent, facts))
        XCTAssertNil(reading(.lastCodexEvent, facts))
        XCTAssertNil(reading(.lastCopilotEvent, facts))
        XCTAssertNil(reading(.lastOpencodeEvent, facts))
        XCTAssertNil(reading(.lastTerminalCommand, facts))
        facts = healthy()
        facts.lastClaudeEvent = nil
        facts.lastCodexEvent = nil
        facts.lastCopilotEvent = nil
        facts.lastOpencodeEvent = nil
        facts.lastTerminalEventAt = nil
        XCTAssertEqual(reading(.lastClaudeEvent, facts)?.value, .noneYet)
        XCTAssertEqual(reading(.lastCodexEvent, facts)?.value, .noneYet)
        XCTAssertEqual(reading(.lastCopilotEvent, facts)?.value, .noneYet)
        XCTAssertEqual(reading(.lastOpencodeEvent, facts)?.value, .noneYet)
        XCTAssertEqual(reading(.lastTerminalCommand, facts)?.value, .noneYet)
        XCTAssertEqual(reading(.lastCodexEvent, healthy())?.value, .ago(.minutes(2)))
        XCTAssertEqual(HealthReport.readings(for: healthy()).map(\.id),
                       [.state, .lidAngle, .lastClaudeEvent, .lastCodexEvent, .lastCopilotEvent,
                        .lastOpencodeEvent, .lastTerminalCommand])
    }

    func testTheLastSafetyStopSaysWhichRailAndWhen() {
        XCTAssertNil(reading(.lastSafetyStop, healthy()))
        var facts = healthy()
        facts.lastSafetyStop = SafetyStop(reason: .thermal, at: now.addingTimeInterval(-7_200))
        XCTAssertEqual(reading(.lastSafetyStop, facts)?.value, .safetyStop(.thermal, ago: .hours(2, minutes: 0)))
        XCTAssertEqual(HealthReport.readings(for: facts).last?.id, .lastSafetyStop)
    }

    // MARK: How long the tables may grow

    func testTheTablesStayShortInTheWorstCase() {
        // Everything that can go wrong gone wrong at once, and every reading there.
        var worst = armed()
        worst.held = [.inputMonitoring, .claudeHooks, .zshHook]
        worst.lidSleepFlagSet = false
        worst.sensorPresent = false
        worst.fnReader = .failed
        worst.watchdogRunning = false
        worst.recentCrashes = [now]
        let checks = HealthReport.checks(for: worst)
        XCTAssertEqual(checks.count, HealthLimits.checks)
        XCTAssertLessThanOrEqual(checks.count, HealthLimits.checks)
        for line in checks where line.level >= .warning { XCTAssertNotNil(line.fix, line.id.rawValue) }

        var everyReading = armed()
        everyReading.lastSafetyStop = SafetyStop(reason: .lowBattery, at: now)
        XCTAssertEqual(HealthReport.readings(for: everyReading).count, HealthLimits.readings)
        XCTAssertLessThanOrEqual(HealthReport.readings(for: everyReading).count, HealthLimits.readings)
    }

    func testEveryLineHasAStableIdentityOnce() {
        var facts = armed()
        facts.lidSleepFlagSet = false
        facts.recentCrashes = [now]
        let ids = HealthReport.checks(for: facts).map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
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

    // MARK: Words decided here

    func testDurationsKeepTheTwoLargestUnits() {
        XCTAssertEqual(HealthDuration(seconds: 30), .lessThanAMinute)
        XCTAssertEqual(HealthDuration(seconds: -5), .lessThanAMinute)
        XCTAssertEqual(HealthDuration(seconds: 125), .minutes(2))
        XCTAssertEqual(HealthDuration(seconds: 3_720), .hours(1, minutes: 2))
        XCTAssertEqual(HealthDuration(seconds: 2 * 86_400 + 3 * 3_600 + 59), .days(2, hours: 3))
    }

    func testAStampIsTheSameInEveryLanguage() {
        let stamp = HealthReport.stamp(now)
        XCTAssertEqual(stamp.count, "2026-09-21 10:10".count)
        XCTAssertTrue(stamp.hasPrefix("2026-"))
    }
}
