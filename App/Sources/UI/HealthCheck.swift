import Foundation
import KoffeeLidCore

/// The readings only the Health page takes: the displays, the battery and the heat, the crash watchdog and
/// its last relaunch, the Claude Code settings file, this process's age and memory, its crash reports and
/// where it is installed. What the rest of the window also shows (a grant, the login item, the lid) is
/// `SettingsModel`'s poll, and KoffeeLid's own state (the mode, the kernel flag, the sleep lock, the hooks'
/// last events) is read from the coordinator each time the page draws; these are read when the page is shown
/// and when Check Again is pressed, and never on a timer, so a page nobody is looking at costs nothing.
///
/// **The window drives this, not a view**, like the model's poll: `SettingsWindow` reads it when it opens on
/// the Health page and when the page is picked. What waits on anything (another app's file, a directory of
/// crash reports, every process's path) is read off the main thread, and the overview reads *Checking* until
/// it lands.
@MainActor
final class HealthCheck: ObservableObject {
    struct Readings: Equatable {
        var launchDate: Date?
        var memoryBytes: UInt64?
        var location: AppLocation?
        var bundlePath = ""
        var displays: DisplayTopology?
        var battery: BatteryState?
        var thermal: ThermalLevel?
        var slow = SlowReadings()
    }

    /// What is read off the main thread.
    struct SlowReadings: Equatable {
        var recentCrashes: [Date] = []
        var watchdogRunning: Bool?
        var lastRelaunch: Date?
        var claudeHookEvents: Int?
        var claudeSettingsUnreadable = false
    }

    @Published private(set) var readings = Readings()
    /// True from a read until its slow readings have landed, and after Check Again for at least
    /// `HealthConstants.minimumBusy`.
    @Published private(set) var isChecking = false
    /// Which read is the latest: an older one that lands late is dropped.
    private var generation = 0

    /// Reads everything again: the cheap readings at once, the rest off the main thread.
    func read(minimumBusy: TimeInterval = 0) {
        generation += 1
        let current = generation
        let started = Date()
        isChecking = true

        var fresh = readings
        fresh.launchDate = ProcessStats.launchDate
        fresh.memoryBytes = ProcessStats.memoryFootprint
        fresh.location = InstallLocation.current()
        fresh.bundlePath = Bundle.main.bundleURL.path
        fresh.displays = DisplayTopologyMonitor.read()
        fresh.battery = BatteryMonitor.read()
        fresh.thermal = ThermalMonitor.map(ProcessInfo.processInfo.thermalState)
        if fresh != readings { readings = fresh }

        // Everything the background read needs from the main actor, taken here.
        let process = Bundle.main.executableURL?.lastPathComponent ?? AppSupport.appName
        let watchdog = WatchdogProcess.executableURL
        let settingsURL = HookInstaller.settingsURL
        let command = HookInstaller.command
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let slow = Self.readSlowly(process: process, watchdog: watchdog, settingsURL: settingsURL,
                                       command: command, now: started)
            let wait = max(0, minimumBusy - Date().timeIntervalSince(started))
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                MainActor.assumeIsolated {
                    guard let self, current == self.generation else { return }
                    if slow != self.readings.slow { self.readings.slow = slow }
                    self.isChecking = false
                }
            }
        }
    }

    /// Check Again: the window's polled states now rather than at the next tick, every reading with them,
    /// and the overview reads *Checking* long enough to be seen.
    func checkAgain(_ model: SettingsModel) {
        guard !isChecking else { return }
        model.refresh()
        read(minimumBusy: HealthConstants.minimumBusy)
    }

    nonisolated private static func readSlowly(process: String, watchdog: URL, settingsURL: URL, command: String,
                                               now: Date) -> SlowReadings {
        var slow = SlowReadings()
        slow.recentCrashes = CrashReports.recent(process: process, since: now.addingTimeInterval(-HealthConstants.crashWindow))
        slow.watchdogRunning = ProcWalk.isRunning(executableAt: watchdog)
        slow.lastRelaunch = RelaunchHistoryStore(url: AppSupport.relaunchHistoryURL).load().max()
        do {
            let root = try HookSettingsFile.load(at: settingsURL) ?? [:]
            slow.claudeHookEvents = HookConfig.installedCount(in: root, command: command)
        } catch {
            slow.claudeSettingsUnreadable = true
        }
        return slow
    }

    /// Everything the page reports: the polled states from `model`, KoffeeLid's own from the coordinator, the
    /// rest from here.
    func facts(_ model: SettingsModel) -> HealthFacts {
        let now = Date()
        let controller = KoffeeLidController.shared
        let prefs = model.prefs
        let slow = readings.slow
        return HealthFacts(
            now: now, held: model.held, loginItem: model.loginItem, sensorPresent: model.sensorPresent,
            lidAngle: model.lidAngle, workingSessions: model.activity.workingSessions,
            runningJobs: model.activity.runningJobs, mode: controller.mode, armed: controller.isArmed,
            oneCloseArm: controller.isArmed && controller.armSource == .gesture, statusLine: controller.statusLine(),
            lidSleepFlagSet: controller.lidSleepFlagSet, lidSleepRestorePending: controller.lidSleepRestorePending,
            sleepLockEngaged: controller.sleepLockEngaged, lastSafetyStop: controller.lastSafetyStop,
            gestureEnabled: prefs.armWithOption, gestureUsesFn: prefs.gestureModifier == .fn,
            effectEnabled: prefs.effect.enabled, autoArmEnabled: prefs.armOnActivity,
            lowBatteryRail: prefs.lowBatteryDisarm, lowBatteryPercent: prefs.lowBatteryDisarmPercent,
            fnReader: Self.fnReader(controller.builtInFnReaderState),
            activityDisabledByEnvironment: ActivityMonitor.isDisabledByEnvironment,
            lastClaudeEvent: controller.activity.lastClaudeEvent,
            lastTerminalEventAt: controller.activity.lastTerminalEventAt,
            displays: readings.displays, battery: readings.battery, thermal: readings.thermal,
            watchdogRunning: slow.watchdogRunning, watchdogPath: WatchdogProcess.executableURL.path,
            agentPlistName: RelaunchAgentController.plistName, lastRelaunch: slow.lastRelaunch,
            claudeHookEvents: slow.claudeHookEvents, claudeSettingsUnreadable: slow.claudeSettingsUnreadable,
            runningSeconds: readings.launchDate.map { now.timeIntervalSince($0) }, memoryBytes: readings.memoryBytes,
            recentCrashes: slow.recentCrashes, location: readings.location, bundlePath: readings.bundlePath)
    }

    /// The reader's own states, in the page's terms. Not granted is the permission line's to report, and a
    /// reader that has not started (or stopped) is one that is not reading.
    private static func fnReader(_ state: BuiltInFnKeyReader.State) -> FnKeyReaderState {
        switch state {
        case .reading: .reading
        case .noDevice: .noKeyboard
        case .stopped, .notGranted, .openFailed: .failed
        }
    }
}
