import Foundation
import KoffeeLidCore

/// The readings only the Health page takes: whether the crash watchdog runs, how many Claude Code, Codex and
/// Copilot hook events point at this copy, whether the OpenCode plugin is current, whether each of Copilot
/// and OpenCode is on this Mac, and KoffeeLid's crash reports. What the rest of the window also shows (a
/// grant, the lid) is `SettingsModel`'s poll, and KoffeeLid's own state (the mode, the kernel flag, the sleep
/// lock, the hooks' last events) is read from the coordinator each time the page draws; these are read when
/// the page is shown and when Check Again is pressed, and never on a timer, so a page nobody is looking at
/// costs nothing.
///
/// **The window drives this, not a view**, like the model's poll: `SettingsWindow` reads it when it opens on
/// the Health page and when the page is picked. Every one of these waits on something (every process's path,
/// another app's file, a directory of crash reports), so all of them are read off the main thread, and Check
/// Again keeps its spinner until they land.
@MainActor
final class HealthCheck: ObservableObject {
    struct Readings: Equatable {
        var recentCrashes: [Date] = []
        var watchdogRunning: Bool?
        var claudeHookEvents: Int?
        var claudeSettingsUnreadable = false
        var codexHookEvents: Int?
        var codexHooksUnreadable = false
        var copilotHookEvents: Int?
        var copilotHooksUnreadable = false
        var copilotHooksDisabled = false
        var copilotOnThisMac = false
        var opencodeStale = false
        var opencodeOnThisMac = false
    }

    @Published private(set) var readings = Readings()
    /// True from a read until its readings have landed, and after Check Again for at least
    /// `HealthConstants.minimumBusy`.
    @Published private(set) var isChecking = false
    /// Which read is the latest: an older one that lands late is dropped.
    private var generation = 0

    /// Reads everything again, off the main thread.
    func read(minimumBusy: TimeInterval = 0) {
        generation += 1
        let current = generation
        let started = Date()
        isChecking = true

        // Everything the background read needs from the main actor, taken here.
        let process = Bundle.main.executableURL?.lastPathComponent ?? AppSupport.appName
        let watchdog = WatchdogProcess.executableURL
        let settingsURL = HookInstaller.settingsURL
        let command = HookInstaller.command
        let codexHooksURL = HookInstaller.codexHooksURL, codexConfigURL = HookInstaller.codexConfigURL
        let codexCommand = HookInstaller.codexCommand
        // `hookPath` reads the bundle on the main actor: taken here, once, for every off-main file read below.
        let hookPath = HookInstaller.hookPath
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var fresh = Self.readSlowly(process: process, watchdog: watchdog, settingsURL: settingsURL,
                                        command: command, now: started)
            let codex = HookInstaller.codexInstalledCount(hooksURL: codexHooksURL, configURL: codexConfigURL, command: codexCommand)
            fresh.codexHookEvents = codex
            fresh.codexHooksUnreadable = codex == nil
            let copilot = HookInstaller.copilotInstalledCount(hooksURL: HookInstaller.copilotHooksURL, hookPath: hookPath)
            fresh.copilotHookEvents = copilot
            fresh.copilotHooksUnreadable = copilot == nil
            fresh.copilotHooksDisabled = HookInstaller.copilotHooksDisabled()
            // Evidence Copilot itself created, never `copilotHome` (`~/.copilot`): `installCopilot()` creates
            // that folder too when it writes the hooks file, so it would prove only that Set Up ran.
            fresh.copilotOnThisMac = FileManager.default.fileExists(atPath: HookInstaller.copilotConfigURL.path)
                || FileManager.default.fileExists(atPath: HookInstaller.copilotSessionStateURL.path)
                || HookInstaller.copilotHooksPresent()
            let opencodeText = try? String(contentsOf: HookInstaller.opencodePluginURL, encoding: .utf8)
            fresh.opencodeStale = opencodeText.map { OpencodePlugin.isOurs($0) && !OpencodePlugin.isCurrent($0, hookPath: hookPath) } ?? false
            // Evidence OpenCode itself created, never `opencodeConfigDir` (`~/.config/opencode`):
            // `installOpencode()` creates that folder too when it writes the plugin.
            let home = FileManager.default.homeDirectoryForCurrentUser
            fresh.opencodeOnThisMac = FileManager.default.fileExists(atPath: home.appendingPathComponent(".local/share/opencode").path)
                || FileManager.default.fileExists(atPath: home.appendingPathComponent(".opencode").path)
                || FileManager.default.fileExists(atPath: "/Applications/OpenCode.app")
                || HookInstaller.opencodePluginPresent()
            let wait = max(0, minimumBusy - Date().timeIntervalSince(started))
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                MainActor.assumeIsolated {
                    guard let self, current == self.generation else { return }
                    if fresh != self.readings { self.readings = fresh }
                    self.isChecking = false
                }
            }
        }
    }

    /// Check Again: the window's polled states now rather than at the next tick, every reading with them,
    /// and a spinner beside the button long enough to be seen.
    func checkAgain(_ model: SettingsModel) {
        guard !isChecking else { return }
        model.refresh()
        read(minimumBusy: HealthConstants.minimumBusy)
    }

    nonisolated private static func readSlowly(process: String, watchdog: URL, settingsURL: URL, command: String,
                                               now: Date) -> Readings {
        var slow = Readings()
        slow.recentCrashes = CrashReports.recent(process: process, since: now.addingTimeInterval(-HealthConstants.crashWindow))
        slow.watchdogRunning = ProcWalk.isRunning(executableAt: watchdog)
        do {
            let root = try HookSettingsFile.load(at: settingsURL) ?? [:]
            slow.claudeHookEvents = HookConfig.claude.installedCount(in: root, command: command)
        } catch {
            slow.claudeSettingsUnreadable = true
        }
        return slow
    }

    /// Everything the page reports: the polled states from `model`, KoffeeLid's own from the coordinator, the
    /// rest from here.
    func facts(_ model: SettingsModel) -> HealthFacts {
        let controller = KoffeeLidController.shared
        let prefs = model.prefs
        return HealthFacts(
            now: Date(), held: model.held, sensorPresent: model.sensorPresent, lidAngle: model.lidAngle,
            mode: controller.mode, armed: controller.isArmed,
            oneCloseArm: controller.isArmed && controller.armSource == .gesture, statusLine: controller.statusLine(),
            lidSleepFlagSet: controller.lidSleepFlagSet, lidSleepRestorePending: controller.lidSleepRestorePending,
            sleepLockEngaged: controller.sleepLockEngaged, lastSafetyStop: controller.lastSafetyStop,
            gestureEnabled: prefs.armWithOption, gestureUsesFn: prefs.gestureModifier == .fn,
            fnReader: Self.fnReader(controller.builtInFnReaderState),
            lastClaudeEvent: controller.activity.lastClaudeEvent, lastCodexEvent: controller.activity.lastCodexEvent,
            lastCopilotEvent: controller.activity.lastEvent(for: .copilot),
            lastOpencodeEvent: controller.activity.lastEvent(for: .opencode),
            lastTerminalEventAt: controller.activity.lastTerminalEventAt,
            watchdogRunning: readings.watchdogRunning, agentPlistName: RelaunchAgentController.plistName,
            claudeHookEvents: readings.claudeHookEvents, claudeSettingsUnreadable: readings.claudeSettingsUnreadable,
            codexHookEvents: readings.codexHookEvents, codexHooksUnreadable: readings.codexHooksUnreadable,
            copilotHookEvents: readings.copilotHookEvents, copilotHooksUnreadable: readings.copilotHooksUnreadable,
            copilotHooksDisabled: readings.copilotHooksDisabled, copilotOnThisMac: readings.copilotOnThisMac,
            opencodeStale: readings.opencodeStale, opencodeOnThisMac: readings.opencodeOnThisMac,
            recentCrashes: readings.recentCrashes)
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
