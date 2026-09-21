import AppKit
import ServiceManagement
import KoffeeLidCore
import LidPlaneKit

enum ArmSource: String { case menu, rightClick, shortcut, gesture, intent, url, cli, activity, update }
enum ArmState: Equatable { case idle, armedWaitingClose, armedClosed }

@MainActor
final class KoffeeLidController {
    static let shared = KoffeeLidController()

    private(set) var state: ArmState = .idle {
        didSet {
            sleepMonitor.armed = state != .idle
            refreshStatusItem()
        }
    }
    var onOpenSettings: (() -> Void)?
    var isArmed: Bool { state != .idle }
    var lastAngle: Double?
    /// The manual choice: off, armed, or armed + screen on (display never sleeps). The Mac is armed
    /// while this or the auto level holds it.
    private(set) var mode: ArmMode = .off
    /// Uptime of the last mode change; the right-click cycle window is measured from it.
    private var lastModeChange: TimeInterval = 0
    /// True while an external display is online; while armed, that means the built-in-screen
    /// behaviours (darken, sound, effect, lock on reopen) stand by and the kernel flag alone remains.
    private var externalDisplay = false
    var standingBy: Bool { isArmed && externalDisplay }
    /// Quitting now would let macOS sleep the Mac at once: armed, the lid shut, and no external display keeping
    /// the desktop up. The update's Install and Relaunch waits for the lid to open.
    var quitWouldSleepTheMac: Bool { isArmed && lidObserver?.isClosed == true && !externalDisplay }

    private let prefs = Preferences.shared
    private let log = DiagnosticLog.shared
    private var power: PowerManager!
    private var lidObserver: LidObserver!
    private(set) var lidAngleObserver: LidAngleObserver?
    private let gesture = GestureController(prefs: .shared)
    /// The built-in keyboard's Fn key (Input Monitoring): only it arms the lid gesture when it can be read.
    private let builtInFn = BuiltInFnKeyReader()
    private var fnReaderObservers: [NSObjectProtocol] = []
    /// Set after an Option + close arm until the lid actually closes: reopening cancels the arm.
    private var reopenWatch: ReopenCancelWatch?
    /// Holds a reopen lock that `standingBy` skipped, in case the topology was one event out of date.
    private var reopenLock = ReopenLockDecision()
    /// Keeps a one-close gesture arm alive across the lid opening, until the user logs back in.
    private var gestureHold = GestureArmHold()
    /// How the current arm was requested. Option + close arms one close; every other source stays armed until disarmed.
    private(set) var armSource: ArmSource?
    private let brightness = InternalDisplayBrightnessController()
    private let lock = LidReopenLockController()
    private let screenLock = ScreenLockObserver()
    private let displays = DisplayTopologyMonitor()
    private let battery = BatteryMonitor()
    private let thermal = ThermalMonitor()
    private let sleepMonitor = SleepInterruptionMonitor()
    private let sleepLock = SleepLock()
    /// Rate-limits the dark-wake hold when macOS keeps sleeping the closed lid behind the arm.
    private var overrideGuard = SleepOverrideGuard()
    private let volume = OutputVolumeOverride()
    let soundPlayer: LidCloseSoundPlayer
    let effect: EffectController
    private let hotKey = HotKeyController(prefs: .shared)
    let statusItem = StatusItemController(visible: Preferences.shared.showInMenuBar)
    private let agent = RelaunchAgentController()
    private let commands = CommandServer()
    /// Auto-arm on activity.
    let activity = ActivityMonitor()
    private var activityPolicy = ActivityArmPolicy()
    /// The auto-arm level (`ActivityArmPolicy`), independent of `mode`: the Mac is armed while either holds it.
    var autoArmed: Bool { activityPolicy.isOn }
    private var activityTimer: Timer?
    /// Polls for local input while an auto hold-off counts down (invariant 11).
    private var inputTimer: Timer?
    private var flagRetryTimer: Timer?
    private var flagClearPending = false { didSet { refreshStatusItem() } }
    private var isStarted = false
    /// When the update's Install and Relaunch asked the app to quit. A quit that follows within
    /// `updateQuitWindow` leaves the manual mode for the version the helper starts (`UpdateResume`); any other
    /// quit leaves nothing, and neither does a one-close gesture arm, which is no manual mode.
    var updateInstallRequestedAt: Date?
    private static let updateQuitWindow: TimeInterval = 30

    private init() {
        soundPlayer = LidCloseSoundPlayer(prefs: prefs, volume: volume)
        effect = EffectController(parameters: prefs.effect)
    }

    // MARK: lifecycle

    func start() throws {
        power = try PowerManager()
        // Only a previous instance that died without cleaning up can have left the kernel
        // flag set; another KoffeeLid build may legitimately own it right now, so clearing
        // it unconditionally would disarm a running sibling. Both markers are read before
        // this instance writes its own pid file / brightness recovery file.
        let stalePidFile = FileManager.default.fileExists(atPath: AppSupport.pidFileURL.path)
        let staleBrightness = FileManager.default.fileExists(atPath: AppSupport.brightnessRecoveryURL.path)
        if stalePidFile || staleBrightness {
            do { try power.setLidSleepDisabled(false); log.log("launch: unclean previous exit detected; kernel lid-sleep flag cleared (recovery)") }
            catch { log.log("launch: kernel lid-sleep flag clear FAILED (\(error))") }
        } else {
            log.log("launch: clean previous exit; kernel flag left untouched")
        }
        sleepLock.onLog = { [log] in log.log($0) }
        sleepLock.releaseIfMarkerPresent(reason: "launch recovery")

        brightness.onLog = { [log] in log.log($0) }; lock.onLog = { [log] in log.log($0) }
        soundPlayer.onLog = { [log] in log.log($0) }; volume.onLog = { [log] in log.log($0) }; agent.onLog = { [log] in log.log($0) }
        effect.onLog = { [log] in log.log($0) }; power.onLog = { [log] in log.log($0) }
        // Silent failure to lock is the one failure the user has to act on themselves. A one-close arm
        // held for a login that can never happen falls back to ending on lid open instead.
        lock.onGaveUp = { [weak self] in
            NotificationsController.shared.post(id: "lock",
                                                title: L("KoffeeLid could not lock the screen"),
                                                body: L("Lock it now with Control-Command-Q, then check Settings > General."))
            guard let self else { return }
            applyGestureHold(gestureHold.lockGaveUp())
        }

        brightness.restoreIfNeeded(reason: "launch recovery")
        agent.writePidFile()
        try? agent.register()
        agent.kickstartIfEnabled()
        effect.foldThresholdDegrees = prefs.gestureActivationDegrees
        // Launch at login defaults to on: register once; the switch in Settings owns it afterwards.
        if prefs.launchAtLogin, SMAppService.mainApp.status == .notRegistered {
            do { try SMAppService.mainApp.register(); log.log("launch at login registered (default)") }
            catch { log.log("launch at login default registration failed: \(error.localizedDescription)") }
        }
        // Onboarding asks for notifications itself, on its permissions page, with the reason next to it.
        if prefs.onboardingCompleted { NotificationsController.shared.requestAuthorization() }

        lidObserver = LidObserver(power: power)
        lidObserver.onLog = { [log] in log.log($0) }
        lidObserver.onTransition = { [weak self] t in self?.handleLid(t) }
        power.onLidStateNotification = { [weak self] in self?.lidObserver.handleNotification() }
        power.onReapplyNeeded = { [weak self] reason in self?.reapplyFlag(reason: reason) }
        power.startMonitoring()

        if let sensor = LidAngleSensor() {
            let obs = LidAngleObserver(sensor: sensor)
            obs.onLog = { [log] in log.log($0) }
            obs.onSample = { [weak self] a, t in self?.handleAngle(a, changedAt: t) }
            lidAngleObserver = obs
        } else { log.log("lid-angle sensor not found; lid gesture and effect unavailable") }

        gesture.onEvent = { [weak self] e in self?.handleGesture(e) }
        builtInFn.onLog = { [log] in log.log($0) }
        gesture.builtInFnDown = { [builtInFn] in builtInFn.fnDown }
        builtInFn.start()
        // The Input Monitoring grant lands while the system prompt or System Settings is in front, and the
        // keyboard device can come back after a wake: retry on both.
        fnReaderObservers = [
            NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.builtInFn.retryIfNotReading() }
            },
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.builtInFn.retryIfNotReading() }
            },
        ]
        effect.onNeedsAngleSampling = { [weak self] on in
            on ? self?.lidAngleObserver?.addConsumer("effect") : self?.lidAngleObserver?.removeConsumer("effect")
        }

        externalDisplay = displays.current.standsBy
        displays.onChange = { [weak self] t in self?.handleDisplays(t) }; displays.start()
        screenLock.onChange = { [weak self] locked in
            guard let self else { return }
            applyGestureHold(gestureHold.observed(locked: locked))
        }
        screenLock.start()
        battery.onChange = { [weak self] b in self?.handleBattery(b) }; battery.start()
        thermal.onChange = { [weak self] t in self?.handleThermal(t) }; thermal.start()
        sleepMonitor.onExternalSleep = { [weak self] in self?.handleExternalSleep() }; sleepMonitor.start()

        hotKey.onPressed = { [weak self] key in
            guard let self else { return }
            guard key == .armed ? prefs.armWithShortcut : prefs.armWithCaffeinateShortcut else { return }
            setMode(ModeCycle.nextOnShortcut(target: key == .armed ? .armed : .caffeinate, current: mode), source: .shortcut)
        }
        hotKey.register()
        statusItem.onRightClick = { [weak self] in
            guard let self, prefs.armWithRightClick else { return }
            let since = ProcessInfo.processInfo.systemUptime - lastModeChange
            setMode(ModeCycle.nextOnRightClick(current: mode, sinceLastChange: since), source: .rightClick)
        }
        statusItem.menuProvider = { [weak self] in self?.buildMenu() ?? NSMenu() }
        commands.handler = { [weak self] link in self?.perform(link, source: .cli) ?? "" }
        commands.start()

        prefs.onChange = { [weak self] key in self?.preferenceChanged(key) }
        refreshGestureSampling()
        log.log("launched (pid \(getpid()))")
        isStarted = true

        activityPolicy.holdOffs = prefs.activityHoldOffs
        activity.jobArmAfterSeconds = prefs.activityJobArmAfterSeconds
        activity.onLog = { [log] in log.log($0) }
        activity.onChange = { [weak self] snapshot in self?.handleActivity(snapshot) }
        activity.start()
        restoreModeAfterUpdate()
    }

    /// Install and Relaunch quits an armed app like any quit, and the user who clicked it expects the app back
    /// the way it was. The note is read once and removed, whatever it says; the mode goes through `setMode`, so
    /// every rail that would refuse an arm from the menu refuses this one.
    private func restoreModeAfterUpdate() {
        guard let text = try? String(contentsOf: AppSupport.updateResumeURL, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: AppSupport.updateResumeURL)
        guard let resume = UpdateResume(contents: text) else { log.log("update: unreadable mode note; starting off"); return }
        guard let target = resume.modeToRestore(now: Date()) else {
            log.log("update: mode \(resume.mode.rawValue) not restored (the relaunch came more than \(Int(UpdateResume.window)) s after the quit)")
            return
        }
        log.log("update: back to \(target.rawValue), the mode before the install")
        setMode(target, source: .update)
    }

    func shutdown() {
        if let asked = updateInstallRequestedAt, Date().timeIntervalSince(asked) < Self.updateQuitWindow, mode != .off, armSource != .gesture {
            try? UpdateResume(mode: mode, writtenAt: Date()).contents.write(to: AppSupport.updateResumeURL, atomically: true, encoding: .utf8)
            log.log("update: mode \(mode.rawValue) noted for the new version")
        }
        activity.stop(); activityTimer?.invalidate(); inputTimer?.invalidate()
        screenLock.stop(); builtInFn.stop()
        fnReaderObservers.forEach { NotificationCenter.default.removeObserver($0); NSWorkspace.shared.notificationCenter.removeObserver($0) }; fnReaderObservers = []
        flagRetryTimer?.invalidate(); flagRetryTimer = nil
        let wasArmed = isArmed

        if isArmed {
            lock.cancel()
            effect.stop()
            releaseSleepLock()
            power?.releaseAssertions()
            brightness.restoreIfNeeded(reason: "quit")
            state = .idle
        } else {
            brightness.restoreIfNeeded(reason: "quit")
        }

        // Never clear a flag this instance did not set: a second KoffeeLid build may own it.
        if let power, wasArmed || flagClearPending || power.lidSleepDisabled {
            var cleared = false
            for attempt in 1...3 {
                do {
                    try power.setLidSleepDisabled(false)
                    cleared = true
                    break
                } catch {
                    log.log("quit: kernel lid-sleep flag clear attempt \(attempt) FAILED (\(error))")
                }
                if attempt < 3 { Thread.sleep(forTimeInterval: 0.3) }
            }
            if cleared {
                flagClearPending = false
                NotificationsController.shared.clear(id: "restore")
            } else {
                flagClearPending = true
                log.log("quit: kernel lid-sleep flag clear FAILED after 3 attempts; restart the Mac to restore lid sleep")
                NotificationsController.shared.post(id: "restore", title: L("Lid sleep could not be restored"), body: L("KoffeeLid could not restore lid sleep before quitting. Restart the Mac to reset it."))
            }
        } else {
            log.log("quit: flag never set by this instance; left untouched")
        }

        lidAngleObserver?.removeConsumer("gesture")
        lidAngleObserver?.removeConsumer("effect")

        power?.stopMonitoring(); displays.stop(); battery.stop(); thermal.stop(); sleepMonitor.stop()
        power?.keepDisplayOn = false; power?.tickleUserActivity = false
        hotKey.unregister(); commands.stop()
        agent.removePidFile()
        log.log("clean termination")
    }

    // MARK: arming

    /// The single entry point for every mode change. `off` disarms; an armed target arms from off or
    /// switches between Armed and Armed + screen on in place (the kernel flag is untouched by that switch).
    @discardableResult
    func setMode(_ target: ArmMode, source: ArmSource) -> ArmDecision {
        guard isStarted else { log.log("ignored setMode(\(target.rawValue), \(source.rawValue)) before start"); return .blocked(.disabled) }
        if target == .off { releaseManual(reason: source.rawValue, source: source); return .allowed }
        if !isArmed { return arm(source: source, mode: target) }
        if mode != target || armSource == .activity {   // a user choice over an auto-only arm makes it manual too
            log.log("mode \(mode.rawValue) → \(target.rawValue) (\(source.rawValue))")
            mode = target
            armSource = source
            reopenWatch = nil       // the arm is manual from here on, so the one-close cancels end with it
            gestureHold.clear()
            lastModeChange = ProcessInfo.processInfo.systemUptime
            applyCaffeinate()
            refreshStatusItem()
            refreshGestureSampling()
        }
        return .allowed
    }

    /// Off from the user (menu, right-click, shortcut, CLI, URL, intent) or the end of a one-close gesture
    /// arm: the manual mode goes Off, and the session ends unless the auto level still holds it. The rails
    /// (battery, thermal, external sleep, reset) call `disarm` instead: they end everything.
    func releaseManual(reason: String, source: ArmSource? = nil) {
        guard isArmed else { mode = .off; return }
        guard autoArmed else { disarm(reason: reason, source: source); return }
        log.log("manual off (\(reason)); the auto-arm holds the session")
        mode = .off
        armSource = .activity
        reopenWatch = nil
        gestureHold.clear()
        lastModeChange = ProcessInfo.processInfo.systemUptime
        applyCaffeinate()
        gesture.reset(); refreshGestureSampling()
        refreshStatusItem()
    }

    /// Runs a CLI / URL verb and returns the text the `koffeelid` command prints.
    @discardableResult
    func perform(_ link: DeepLink, source: ArmSource) -> String {
        guard isStarted else { log.log("ignored \(link.rawValue) before start"); return "did not run: KoffeeLid is starting" }
        var decision: ArmDecision = .allowed
        switch link {
        case .arm: decision = setMode(.armed, source: source)
        case .off: setMode(.off, source: source)
        case .caffeinate: decision = setMode(.caffeinate, source: source)
        case .toggleArmed: decision = setMode(ModeCycle.nextOnShortcut(target: .armed, current: mode), source: source)
        case .toggleCaffeinate: decision = setMode(ModeCycle.nextOnShortcut(target: .caffeinate, current: mode), source: source)
        case .status: break
        case .settings: onOpenSettings?()
        }
        if case .blocked(let r) = decision { return "did not arm: \(Self.describe(r))" }
        return statusLine()
    }

    /// One line for the CLI, Shortcuts and the log: `mode: armed + screen on · lid: open · standing by (external display)`.
    func statusLine() -> String {
        var parts = ["mode: " + (mode == .caffeinate ? "armed + screen on" : mode.rawValue)]
        if autoArmed, isArmed { parts.append("auto-armed (activity)") }
        if activityPolicy.disarmOnce { parts.append("disarm once finished: pending") }
        if let closed = lidObserver?.isClosed { parts.append("lid: " + (closed ? "closed" : "open")) }
        if standingBy { parts.append("standing by (external display)") }
        if isArmed { parts.append(sleepLock.engaged ? "sleep lock: on" : "sleep lock: off (no sudoers rule)") }
        if flagClearPending { parts.append("warning: lid sleep restoration pending") }
        if quitWouldSleepTheMac { parts.append("warning: quitting would sleep the Mac") }
        parts.append(ActivityMonitor.isDisabledByEnvironment
                     ? "activity: off (disabled by environment)"
                     : "activity: " + activity.snapshot.summary)
        return parts.joined(separator: " · ")
    }

    private static func describe(_ r: ArmBlockReason) -> String {
        switch r {
        case .displayUnverified: return "display setup could not be verified"
        case .thermal(let t): return "thermal pressure (\(t))"
        case .batteryLow(let p): return "battery at \(p)% on battery power"
        case .disabled: return "KoffeeLid is still starting"
        case .flagSetFailed: return "the kernel flag could not be set"
        }
    }

    @discardableResult
    func arm(source: ArmSource, mode target: ArmMode = .armed) -> ArmDecision {
        guard isStarted else { log.log("ignored arm(\(source.rawValue)) before start"); return .blocked(.disabled) }
        guard !isArmed else { return .allowed }
        precondition(target != .off)
        let policy = ArmingPolicy(lowBatteryDisarmEnabled: prefs.lowBatteryDisarm, lowBatteryPercent: prefs.lowBatteryDisarmPercent)
        let decision = policy.evaluate(displays: displays.current, thermal: thermal.current, battery: battery.current)
        if case .blocked(let reason) = decision {
            log.log("arm blocked (\(source.rawValue)): \(reason)")
            notifyBlocked(reason)
            return decision
        }
        do { try power.setLidSleepDisabled(true) }
        catch {
            // A pending clear keeps retrying: the flag is still set from the last session.
            log.log("lid-sleep flag set FAILED (\(error))")
            notifyBlocked(.flagSetFailed)
            return .blocked(.flagSetFailed)
        }
        flagRetryTimer?.invalidate(); flagRetryTimer = nil
        flagClearPending = false
        power.acquireAssertions()
        log.log("power transition protection active")
        engageSleepLock()
        overrideGuard = SleepOverrideGuard()
        if source != .activity { mode = target }   // the auto level never touches the manual mode
        lastModeChange = ProcessInfo.processInfo.systemUptime
        state = (lidObserver.isClosed == true) ? .armedClosed : .armedWaitingClose
        armSource = source                        // before refreshGestureSampling: gestureWanted reads it
        gesture.reset()
        refreshGestureSampling()
        effect.gateToStartAngle = source != .gesture
        reopenWatch = (source == .gesture && state == .armedWaitingClose) ? lastAngle.map { ReopenCancelWatch(angle: $0, now: ProcessInfo.processInfo.systemUptime) } : nil
        if state == .armedWaitingClose, !standingBy { effect.start() }
        applyCaffeinate()
        log.log("armed (\(source.rawValue), \(target.rawValue))" + (standingBy ? "; standing by: external display connected" : ""))
        refreshStatusItem()
        return .allowed
    }

    func disarm(reason: String, source: ArmSource? = nil) {
        guard isStarted else { log.log("ignored disarm(\(reason)) before start"); return }
        guard isArmed else { return }
        if lock.cancel() { log.log("pending lid-open lock cancelled (\(reason))") }
        reopenWatch = nil
        reopenLock.clear()
        gestureHold.clear()
        effect.stop()
        do {
            try power.setLidSleepDisabled(false)
            flagRetryTimer?.invalidate(); flagRetryTimer = nil
            flagClearPending = false
        }
        catch {
            log.log("lid-sleep flag clear FAILED (\(error)); retrying")
            flagClearPending = true
            NotificationsController.shared.post(id: "restore", title: L("Lid sleep restoration pending"), body: L("KoffeeLid is retrying. Until the warning icon clears, open the lid before leaving your Mac; restarting the Mac always resets this setting."))
            flagRetryTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] t in
                Task { @MainActor in
                    guard let self else { t.invalidate(); return }
                    if (try? self.power.setLidSleepDisabled(false)) != nil {
                        t.invalidate()
                        self.flagClearPending = false
                        NotificationsController.shared.clear(id: "restore")
                        self.log.log("lid-sleep flag cleared on retry")
                    }
                }
            }
        }
        releaseSleepLock()
        power.releaseAssertions()
        brightness.restoreIfNeeded(reason: reason)
        mode = .off
        lastModeChange = ProcessInfo.processInfo.systemUptime
        applyCaffeinate()
        state = .idle
        armSource = nil
        gesture.reset()                           // a half gesture or a held arm never outlives the session
        refreshGestureSampling()
        log.log("power transition protection released")
        activityPolicy.suspend(); scheduleActivityTick()   // a rail or the end of the work: no auto re-arm until the work stops and restarts
        log.log("disarmed (\(reason))")
    }

    /// Armed + screen on holds the display assertion for the whole session; the user-activity tickle
    /// (screen saver, auto-lock) only while the lid is open, since it would wake a closed lid's panel.
    private func applyCaffeinate() {
        power.keepDisplayOn = mode.keepsDisplayOn
        power.tickleUserActivity = mode.keepsDisplayOn && lidObserver?.isClosed != true
    }

    // MARK: events

    private func handleLid(_ t: LidTransition) {
        switch t {
        case .closed:
            guard isArmed else { return }
            state = .armedClosed
            reopenWatch = nil
            reopenLock.clear()
            refreshGestureSampling()
            effect.stop()
            applyCaffeinate()
            if standingBy { log.log("lid closed on an external display; macOS closed-lid mode, nothing to darken"); return }
            if !brightness.darken() { InternalDisplayBrightnessController.displaySleepNow(onLog: log.log) }
            if prefs.lidCloseSoundEnabled { soundPlayer.play() }
        case .opened:
            guard isArmed else { brightness.restoreIfNeeded(reason: "lid opened"); return }
            brightness.restoreIfNeeded(reason: "lid opened")
            // macOS reports a display that vanished behind a closed lid only after the lid-open
            // notification (see `ReopenLockDecision`), so read the topology live before anything —
            // the effect, the lock — depends on `standingBy`. An unreadable list keeps the cache.
            let live = displays.current
            if live.verified { handleDisplays(live) }
            // A one-close arm is held until the user logs back in, so that opening and closing the
            // lid in between cannot stop their work (`GestureArmHold`).
            if armSource == .gesture { applyGestureHold(gestureHold.lidOpened()) }
            if isArmed {
                state = .armedWaitingClose
                gesture.reset()
                refreshGestureSampling()
                applyCaffeinate()
                // A held arm belongs to someone who is away: the closes it still covers stay silent
                // of the effect (the lid sound stays, by choice), and nothing captures a locked desktop.
                if !standingBy, !gestureHold.isHolding { effect.gateToStartAngle = true; effect.start() }
                log.log("lid opened; arm stands (\(mode.rawValue)\(autoArmed ? ", auto-armed" : ""))")
            }
            if reopenLock.lidOpened(standingBy: standingBy, now: ProcessInfo.processInfo.systemUptime) { lock.requestLock() }
            else { log.log("lid opened on an external display; no lock") }
            // A lid that reopens on an already locked screen gets no lock edge: read the state now.
            applyGestureHold(gestureHold.observed(locked: screenLock.isLocked))
        }
    }

    /// Acts on a `GestureArmHold` verdict. The release runs through `releaseManual`, so the activity
    /// auto-arm still keeps the session if it is holding one.
    private func applyGestureHold(_ outcome: GestureArmHold.Outcome) {
        switch outcome {
        case .nothing:
            break
        case .keepArmed:
            log.log("one-close session held on lid open; waiting for the screen to lock")
        case .held:
            log.log("one-close arm held; it ends when you log back in")
        case .release(let reason):
            log.log("one-close session ended on \(reason.rawValue)")
            releaseManual(reason: reason.rawValue)
            if isArmed, !standingBy { effect.gateToStartAngle = true; effect.start() }
        }
    }

    private func reapplyFlag(reason: String) {
        guard isArmed else { return }
        // Root-domain notifications fire for our own write too; re-applying an already
        // disabled flag would log forever and feed itself another notification.
        if power.readLidCausesSleep() == false { return }
        if (try? power.setLidSleepDisabled(true)) != nil { log.log("re-applied lid-sleep flag after \(reason)") }
        else { log.log("re-apply lid-sleep flag FAILED after \(reason)") }
    }

    private func handleAngle(_ a: Double, changedAt: TimeInterval) {
        lastAngle = a
        if prefs.effect.showAngleInMenuBar { statusItem.angleText = "\(Int(a))°" } else if statusItem.angleText != nil { statusItem.angleText = nil }
        // Fn (or Option) held = "still in the gesture": the detector sees it, and neither the one-close stall
        // cancel nor the plane's return-to-flat counts stillness while it is down.
        let held = prefs.armWithOption && gesture.readModifier()
        if gestureWanted { gesture.feed(angle: a, modifierDown: held) }
        guard state == .armedWaitingClose else { return }
        if var w = reopenWatch {
            let verdict = w.update(angle: a, now: ProcessInfo.processInfo.systemUptime,
                                   cancelDegrees: prefs.gestureReverseCancelDegrees, stallSeconds: prefs.effect.settleDelay, held: held)
            reopenWatch = w
            if let verdict {
                reopenWatch = nil
                switch verdict {
                case .reopened: log.log("gesture: lid reopened by \(Int(prefs.gestureReverseCancelDegrees))deg after arming (min \(Int(w.minAngle))deg); cancelling")
                case .stalled: log.log(String(format: "gesture: lid still for %.2gs after arming without closing; cancelling", prefs.effect.settleDelay))
                }
                effect.stop(retracting: true)
                releaseManual(reason: verdict == .reopened ? "reopened" : "stalled")
                if isArmed, !standingBy { effect.gateToStartAngle = true; effect.start() }   // the auto-arm holds: back to a standing arm
                return
            }
        }
        effect.feed(angleDegrees: a, changedAt: changedAt, holding: held)
    }

    private func handleGesture(_ e: GestureEvent) {
        switch e {
        case .progress: break
        case .started(let angle):
            log.log("gesture: started @\(Int(angle))deg (\(prefs.gestureModifier.rawValue) via \(gesture.modifierSource))")
        case .armed(let angle, let start):
            if isArmed {
                // Already armed from the menu/shortcut/CLI: the gesture is visual confirmation, not a second
                // arm. The driver stays silent until the modifier is released, then listens again.
                let outcome: String
                switch effect.followLidFromHere() {
                case .following: outcome = "effect follows the lid (plane from \(Int(prefs.effect.gestureStartBelowDegrees))°)"
                case .keptCurrentFold: outcome = "effect already folding; fold kept"
                case .alreadyFollowing: outcome = "effect already following the lid"
                case .notRunning: outcome = "effect not running (off or no Screen Recording); nothing to show"
                }
                log.log("gesture: modifier + close while armed (\(armSource?.rawValue ?? "?")) @\(Int(angle))deg; \(outcome)")
            } else {
                log.log("gesture: armed via tilt @\(Int(angle))deg (start \(Int(start))deg, closed \(Int(start - angle))deg)")
                arm(source: .gesture)
            }
        case .cancelled(let r):
            log.log("gesture: cancelled (\(r))")
        }
    }

    private func handleDisplays(_ t: DisplayTopology) {
        let external = t.standsBy
        guard external != externalDisplay else { return }
        externalDisplay = external
        defer { refreshGestureSampling(); refreshStatusItem() }
        guard isArmed else { return }
        if external {
            log.log("external display connected while armed; standing by (kernel flag kept)")
            reopenWatch = nil
            effect.stop(retracting: true)
            if armSource == .gesture, state == .armedWaitingClose { releaseManual(reason: "external display during one-close arm"); return }
            if lidObserver.isClosed == true {
                // The session was darkened and unlocked behind a closed lid; a display just made it visible.
                log.log("display appeared while the lid is closed; locking")
                lock.requestLock()
            }
        } else {
            log.log("external display disconnected; lid behaviours active again")
            if state == .armedWaitingClose { effect.gateToStartAngle = true; effect.start() }
            // It was already gone while the lid was closed and macOS only says so now: the session the
            // reopen left unlocked had been sitting behind a closed lid with no display at all.
            if reopenLock.externalDisplayGone(lidOpen: lidObserver.isClosed != true, now: ProcessInfo.processInfo.systemUptime) {
                log.log("the external display was already gone when the lid opened; locking after all")
                lock.requestLock()
            }
        }
    }

    private func handleBattery(_ b: BatteryState?) {
        guard isArmed, LowBatteryPolicy(enabled: prefs.lowBatteryDisarm, thresholdPercent: prefs.lowBatteryDisarmPercent).shouldDisarm(b) else { return }
        disarm(reason: "low battery")
        let body = b.map { String(format: L("Battery dropped to %d%%. The low-battery safety disarmed KoffeeLid so your Mac can sleep instead of running flat."), $0.percent) }
            ?? L("macOS stopped reporting battery charge while the low-battery safety was enabled. KoffeeLid disarmed so the Mac can sleep.")
        NotificationsController.shared.post(id: "battery", title: L("KoffeeLid disarmed"), body: body)
    }

    private func handleThermal(_ t: ThermalLevel) {
        guard isArmed, t >= .serious else { return }
        disarm(reason: "thermal")
        NotificationsController.shared.post(id: "thermal", title: L("KoffeeLid disarmed"), body: String(format: L("macOS reported %@ thermal pressure. Normal lid-close sleep has been restored."), t == .critical ? L("critical") : L("serious")))
    }

    private func handleExternalSleep() {
        let reason = power.readLastSleepReason()
        let kind = SleepInterruptionPolicy.classify(reason: reason, lidClosed: lidObserver.isClosed == true)
        if kind == .lidSleepOverride, overrideGuard.record(now: ProcessInfo.processInfo.systemUptime) {
            // powerd rewrote the shared lid-sleep bit and the kernel evaluated the closed lid (nobody asked
            // for sleep). That sleep goes full wake → dark wake first, and our PreventSystemSleep assertion
            // vetoes the dark wake → sleep step (xnu checkSystemSleepAllowed, CPU assertion), so keeping mode,
            // state and assertions holds the Mac in dark wake: processes keep running, display and audio
            // off, until the lid opens or something tickles a full wake. The flag goes back now so the next
            // clamshell evaluation (full wake + 20 s, lid events) finds it. The sleep lock, when configured,
            // stops the kernel from starting this sleep at all and this path never runs.
            log.log("macOS started a lid sleep behind the arm (powerd rewrote the lid-sleep bit); holding the session in dark wake")
            if (try? power.setLidSleepDisabled(true)) != nil { log.log("re-applied lid-sleep flag after lid-sleep override") }
            else { log.log("re-apply lid-sleep flag FAILED after lid-sleep override") }
            NotificationsController.shared.post(id: "override", title: L("KoffeeLid held your Mac awake"), body: L("macOS tried to sleep the closed Mac after a charger or display change. KoffeeLid kept it running in the background. Set up the sleep lock (see the documentation) to stop this from happening."))
            return
        }
        if kind == .lidSleepOverride { log.log("lid-sleep override repeated too often; giving up the hold") }
        log.log("armed session interrupted by external software sleep" + (reason.map { " (\($0))" } ?? ""))
        disarm(reason: "external sleep")
        NotificationsController.shared.post(id: "extsleep", title: L("KoffeeLid disarmed"), body: L("Another app or automation put your Mac to sleep while KoffeeLid was armed. Check your charging, scheduling, and automation settings before trying again."))
    }

    // MARK: reset

    /// Advanced › Reset: undoes every change KoffeeLid made outside its own bundle — disarms, releases the
    /// sleep lock and deletes its sudoers rule (administrator dialog), unregisters the login items, resets the
    /// Screen Recording and notification grants, wipes preferences and recovery files. Returns what happened.
    func resetEverything() -> [String] {
        var done: [String] = []
        // Straight to disarm, not through setMode: Off from the menu is ignored while auto-armed, and a reset
        // must end every arm before the sudoers rule goes (the sleep lock releases through that rule).
        if isArmed { disarm(reason: "reset"); done.append("disarmed") }
        if sleepLock.isAvailable {
            switch SleepLock.removeRule() {
            case .done: done.append("sudoers rule removed")
            case .cancelled: done.append("sudoers rule kept (cancelled)")
            case .failed(let m): done.append("sudoers rule removal failed: \(m)")
            }
        }
        try? FileManager.default.removeItem(at: AppSupport.sleepLockMarkerURL)
        try? agent.unregister(); try? SMAppService.mainApp.unregister()
        try? agent.register()   // back to "requires approval" so the onboarding row has something to approve
        done.append("login items unregistered")
        if Self.run("/usr/bin/tccutil", ["reset", "ScreenCapture", Bundle.main.bundleIdentifier ?? "dev.rubens.koffeelid"]) == 0 { done.append("screen recording reset") }
        if Self.run("/usr/bin/tccutil", ["reset", "ListenEvent", Bundle.main.bundleIdentifier ?? "dev.rubens.koffeelid"]) == 0 { done.append("input monitoring reset") }
        if Self.resetNotificationGrant() { done.append("notifications reset") }
        // The update's leftovers too: a note or an outcome kept past a reset would speak at the next launch.
        for url in [AppSupport.relaunchHistoryURL, AppSupport.brightnessRecoveryURL, AppSupport.updateResumeURL, UpdateController.directory] {
            try? FileManager.default.removeItem(at: url)
        }
        if (HookInstaller.installedCount() ?? 0) > 0 { done.append(HookInstaller.uninstall().ok ? "claude code hooks removed" : "claude code hooks removal failed") }
        if HookInstaller.zshrcHasSnippet() { done.append(HookInstaller.removeFromZshrc().ok ? "zsh snippet removed" : "zsh snippet removal failed") }
        if let id = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: id); done.append("preferences cleared") }
        hotKey.register(); refreshGestureSampling(); effect.parameters = prefs.effect; builtInFn.start(); refreshStatusItem()
        log.log("reset: " + done.joined(separator: ", "))
        return done
    }

    /// Everything KoffeeLid put on this Mac outside its own bundle, taken off, and then the bundle itself
    /// moved to the Trash. Returns what was done, and then what could not be, so the caller can say so.
    ///
    /// **Dragging the bundle to the Trash is not an uninstall.** It removes the app and nothing else: the
    /// sudoers rule stays, the wrapper on the PATH stays, the login items stay, and the Claude Code hooks
    /// and the zsh snippet go on calling a binary that is no longer there, once per event, for ever.
    ///
    /// The order is the whole of it:
    /// 1. the arm ends first, so the kernel flag is clear before anything else moves (invariant 1);
    /// 2. the sleep lock is released while the sudoers rule that releases it still exists;
    /// 3. the TCC grants are reset while the bundle they name is still where they name it (`tccutil reset`
    ///    on a bundle identifier with no bundle behind it fails, and there is no putting it right after);
    /// 4. nothing that could start the app again is left registered, and nothing is registered back;
    /// 5. the two root-owned files go in one administrator dialog, and only if one of them is there;
    /// 6. the support folder goes last, once the log that writes into it has been silenced.
    @discardableResult
    func uninstallEverything() -> (done: [String], failed: [String]) {
        var done: [String] = []
        var failed: [String] = []
        let bundleID = Bundle.main.bundleIdentifier ?? "dev.rubens.koffeelid"

        // Straight to disarm, not through setMode: Off from the menu is ignored while auto-armed.
        if isArmed { disarm(reason: "uninstall"); done.append("disarmed") }
        // Unconditionally, not only when this instance holds it: `pmset disablesleep 1` outlives the
        // process that set it and survives a reboot, so a lock an earlier instance died holding has to go
        // now, while the rule that releases it is still there. Sending 0 at an unlocked Mac does nothing.
        if sleepLock.isAvailable {
            if sleepLock.release() { done.append("sleep lock released") }
            else { failed.append(L("The Mac is still held awake. Run `sudo pmset disablesleep 0` in Terminal.")) }
        }
        try? FileManager.default.removeItem(at: AppSupport.sleepLockMarkerURL)
        // The one thing an uninstall can leave genuinely wrong: the kernel's lid-sleep bit still set, so a
        // closed Mac would not sleep and nothing would be left to clear it. `disarm` retries on a timer
        // that will not outlive this quit, so the user is told instead.
        if flagClearPending { failed.append(L("The Mac is still set not to sleep when the lid shuts. Restart the Mac: that always puts it back.")) }

        if Self.run("/usr/bin/tccutil", ["reset", "ScreenCapture", bundleID]) == 0 { done.append("screen recording reset") }
        if Self.run("/usr/bin/tccutil", ["reset", "ListenEvent", bundleID]) == 0 { done.append("input monitoring reset") }
        if Self.resetNotificationGrant() { done.append("notifications reset") }

        // No re-register here, unlike a reset: after this there is no app for them to point at.
        try? agent.unregister(); try? SMAppService.mainApp.unregister()
        done.append("login items unregistered")

        if (HookInstaller.installedCount() ?? 0) > 0 {
            let r = HookInstaller.uninstall()
            if r.ok { done.append("claude code hooks removed") } else { failed.append(String(format: L("The Claude Code hooks could not be removed: %@"), r.message)) }
        }
        if HookInstaller.zshrcHasSnippet() {
            let r = HookInstaller.removeFromZshrc()
            if r.ok { done.append("zsh snippet removed") } else { failed.append(String(format: L("The line in .zshrc could not be removed: %@"), r.message)) }
        }
        try? FileManager.default.removeItem(at: HookInstaller.backupURL)

        if UninstallPlan.needsPrivilege(present: { FileManager.default.fileExists(atPath: $0) }) {
            switch SleepLock.runPrivilegedScript(UninstallPlan.privilegedScript) {
            case .done: done.append("sudoers rule and command line removed")
            case .cancelled: failed.append(String(format: L("These files need an administrator password and are still there: %@"), UninstallPlan.privilegedPaths.joined(separator: ", ")))
            case .failed(let m): failed.append(String(format: L("These files could not be removed: %@ (%@)"), UninstallPlan.privilegedPaths.joined(separator: ", "), m))
            }
        }

        UserDefaults.standard.removePersistentDomain(forName: bundleID)
        UserDefaults.standard.synchronize()
        done.append("preferences cleared")

        log.log("uninstall: " + done.joined(separator: ", "))
        // Nothing may write into the folder after this, or it comes back with the line that created it.
        DiagnosticLog.shared.silence()
        try? FileManager.default.removeItem(at: AppSupport.directory)

        // **And again, once this process has gone.** Removing either of those here is not enough: the way
        // out through `shutdown()` recreates the activity journal, and so the folder with it, and cfprefsd
        // writes the domain back out as the process exits, leaving an empty plist where a Mac that never
        // had KoffeeLid has no file at all. Both were seen on a real uninstall. The helper waits for the pid.
        let script = UninstallPlan.helperScript(pid: getpid(), domain: bundleID,
                                                supportDirectory: AppSupport.directory.path,
                                                home: FileManager.default.homeDirectoryForCurrentUser.path)
        do {
            try DetachedProcess.spawn(executable: "/bin/sh", arguments: ["-c", script], environment: [:])
            done.append("support folder and preferences handed to the helper")
        } catch {
            failed.append(String(format: L("The last step could not be started: %@. The settings and the KoffeeLid folder in Application Support are still there; remove them by hand."), "\(error)"))
        }
        return (done, failed)
    }

    /// Notification authorization lives in usernoted's group preferences; dropping the app's entry and
    /// restarting the daemon puts it back to "not determined" (no public API does this).
    private static func resetNotificationGrant() -> Bool {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/Library/Preferences/group.com.apple.usernoted.plist")
        guard let data = try? Data(contentsOf: url),
              var plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let apps = plist["apps"] as? [[String: Any]] else { return false }
        let kept = apps.filter { ($0["bundle-id"] as? String) != Bundle.main.bundleIdentifier }
        guard kept.count != apps.count else { return true }
        plist["apps"] = kept
        guard let out = try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0),
              (try? out.write(to: url)) != nil else { return false }
        _ = run("/usr/bin/killall", ["usernoted"]); _ = run("/usr/bin/killall", ["NotificationCenter"])
        return true
    }

    private static func run(_ path: String, _ args: [String]) -> Int32 {
        let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit(); return p.terminationStatus
    }

    // MARK: sleep lock

    /// Engaged on every arm when the sudoers rule exists: the only thing that makes a closed armed Mac
    /// immune to powerd rewriting the shared lid-sleep bit (docs/macOS.md § Kernel lid-sleep flag).
    private func engageSleepLock() {
        if sleepLock.isAvailable {
            if sleepLock.engage() { log.log("sleep lock engaged (pmset disablesleep 1)") }
        } else {
            log.log("sleep lock unavailable: no sudoers rule for pmset; a charger or display change can still sleep the closed Mac (docs/development.md)")
        }
    }

    /// The sudoers rule is installed or removed from Settings / onboarding: true when the lock is
    /// available now. An armed session picks it up immediately.
    var sleepLockAvailable: Bool { sleepLock.isAvailable }
    func sleepLockRuleChanged() {
        guard isStarted, isArmed, !sleepLock.engaged else { return }
        engageSleepLock()
    }

    /// The Input Monitoring row was acted on (Settings / onboarding): reopen the built-in keyboard, or let it go.
    func inputMonitoringChanged() {
        guard isStarted else { return }
        builtInFn.start()
    }

    private func releaseSleepLock() {
        guard sleepLock.engaged else { return }
        if sleepLock.release() { log.log("sleep lock released (pmset disablesleep 0)") }
        else {
            log.log("sleep lock release FAILED; the Mac cannot sleep until `sudo pmset disablesleep 0` runs")
            NotificationsController.shared.post(id: "sleeplock", title: L("Sleep could not be re-enabled"), body: L("KoffeeLid could not run pmset to allow sleep again. Run `sudo pmset disablesleep 0` in Terminal."))
        }
    }

    private func notifyBlocked(_ r: ArmBlockReason) {
        let body: String
        switch r {
        case .displayUnverified: body = L("KoffeeLid could not verify the display setup. Disconnect any additional displays and try again.")
        case .thermal: body = L("KoffeeLid did not arm because macOS reports high thermal pressure. Let the Mac cool, then try again.")
        case .batteryLow(let p): body = String(format: L("Battery is at %d%%. Charge the Mac or lower the low-battery threshold."), p)
        case .disabled: body = L("KoffeeLid is still starting. Try again in a moment.")
        case .flagSetFailed: body = L("KoffeeLid could not change the Mac's sleep setting. Try again.")
        }
        NotificationsController.shared.post(id: "blocked", title: L("KoffeeLid did not arm"), body: body)
    }

    // MARK: activity

    private func handleActivity(_ snapshot: ActivitySnapshot) {
        applyAuto(activityPolicy.update(running: snapshot.kinds, enabled: prefs.armOnActivity, now: Date()))
        scheduleActivityTick()
    }

    /// "Disarm once finished" from the menu: the auto level drops a minute after the work is over (instead of
    /// its long hold-off) and takes the manual mode Off with it. Already idle for longer than that, it fires now.
    func requestActivityDisarmOnce(_ on: Bool) {
        activityPolicy.requestDisarmOnce(on)
        log.log("disarm once finished \(on ? "requested" : "cancelled")")
        applyAuto(activityPolicy.tick(now: Date()))
        scheduleActivityTick()
    }
    var activityDisarmOncePending: Bool { activityPolicy.disarmOnce }

    /// The auto level changed. The Mac is armed while either the manual mode or the auto level holds it, so
    /// the level arms only from an idle Mac and disarms only when the manual mode is Off.
    private func applyAuto(_ change: ActivityArmChange?) {
        switch change {
        case .on:
            if isArmed { log.log("auto-arm on; the manual arm (\(mode.rawValue)) stands"); refreshStatusItem(); return }
            if case .blocked = arm(source: .activity) { activityPolicy.armFailed(); log.log("auto-arm blocked; waiting for the next activity") }
            else { log.log("auto-armed (activity)") }
        case .off(let releaseManual):
            if releaseManual, mode != .off { log.log("disarm once finished: manual mode (\(mode.rawValue)) released"); mode = .off }
            if mode == .off { if isArmed { disarm(reason: "activity ended", source: .activity) } }
            else { log.log("auto-arm ended; the manual arm (\(mode.rawValue)) stands"); refreshStatusItem() }
        case nil: break
        }
    }

    private func scheduleActivityTick() {
        activityTimer?.invalidate(); activityTimer = nil
        inputTimer?.invalidate(); inputTimer = nil
        guard let due = activityPolicy.nextDeadline(after: Date()) else { return }
        log.log("auto-disarm scheduled in \(Int(due.timeIntervalSinceNow.rounded()))s")
        // The hold-off is for a remote user whose connection would die with the Mac; someone typing or
        // moving the mouse here is responsible for arming it, so local input ends the wait at once.
        let poll = Timer(timeInterval: 2, repeats: true) { [weak self] _ in Task { @MainActor in self?.checkLocalInput() } }
        poll.tolerance = 0.5
        RunLoop.main.add(poll, forMode: .common)
        inputTimer = poll
        let t = Timer(fire: due, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.applyAuto(self.activityPolicy.tick(now: Date()))
            }
        }
        RunLoop.main.add(t, forMode: .common)
        activityTimer = t
    }

    private func checkLocalInput() {
        guard let idleSince = activityPolicy.idleSince, let last = LocalInputMonitor.lastInputDate(), last > idleSince else { return }
        guard let change = activityPolicy.userActive(now: Date()) else { return }
        log.log("auto-arm ended: local input during the hold-off")
        applyAuto(change)
        scheduleActivityTick()
    }

    // MARK: preferences

    private func preferenceChanged(_ key: String) {
        switch key {
        case "armWithShortcut", "armWithCaffeinateShortcut", "hotKeyCode", "hotKeyModifiers", "caffeinateHotKeyCode", "caffeinateHotKeyModifiers":
            hotKey.register()   // registers only the enabled ones
        case "showInMenuBar": statusItem.visible = prefs.showInMenuBar
        case EffectParameters.userDefaultsKey: effect.parameters = prefs.effect; if isArmed, state == .armedWaitingClose, prefs.effect.enabled { effect.start() }
        case "armWithOption", "gestureModifier", "gestureActivationDegrees", "gestureReverseCancelDegrees":
            if key == "gestureActivationDegrees" { effect.foldThresholdDegrees = prefs.gestureActivationDegrees }
            gesture.reset(); refreshGestureSampling()
        case "armOnActivity", "activityJobArmAfterSeconds", Preferences.holdOffKey(.claude), Preferences.holdOffKey(.terminal):
            activityPolicy.holdOffs = prefs.activityHoldOffs
            activity.jobArmAfterSeconds = prefs.activityJobArmAfterSeconds
            if key == "armOnActivity" { log.log(prefs.armOnActivity ? "auto-arm enabled" : "auto-arm disabled"); handleActivity(activity.snapshot) }
            scheduleActivityTick()
        default: break
        }
    }

    /// The Fn + close detector runs while idle (to arm) and while armed from another source with the lid
    /// open (so the gesture still gives its visual confirmation). Never with an external display, never
    /// during a one-close (gesture) arm, never with the lid closed. See `docs/pitfalls.md`.
    private var gestureWanted: Bool {
        prefs.armWithOption && !externalDisplay && (!isArmed || (state == .armedWaitingClose && armSource != .gesture))
    }
    private var gestureListening = false

    /// Every entry into (or exit from) a listening state starts the detector from a clean slate, so no
    /// half gesture or held arm can carry over from a previous state.
    private func refreshGestureSampling() {
        let wants = gestureWanted && lidAngleObserver != nil
        if wants != gestureListening { gesture.reset() }
        gestureListening = wants
        if wants { lidAngleObserver?.addConsumer("gesture") } else { lidAngleObserver?.removeConsumer("gesture") }
    }

    private func refreshStatusItem() {
        // The glyph is the one place the auto-arm shows: a manual arm (any other source) always wins over it.
        statusItem.state = mode != .off ? (mode == .caffeinate ? .caffeinate : .armed) : (isArmed && autoArmed ? .auto : .off)
        statusItem.warning = flagClearPending
        statusItem.standingBy = standingBy
    }

    // MARK: menu

    private func buildMenu() -> NSMenu {
        let m = NSMenu()
        var header = "KoffeeLid — " + StatusItemController.title(for: mode)
        if standingBy { header += " · " + L("Standing by: external display") }
        m.addItem(withTitle: header, action: nil, keyEquivalent: "").isEnabled = false
        if autoArmed, isArmed {
            let hint = NSMenuItem(title: autoArmHint(), action: nil, keyEquivalent: "")
            hint.attributedTitle = StatusItemController.menuTitle(autoArmHint(), glyph: .auto); hint.isEnabled = false
            m.addItem(hint)
        }
        m.addItem(.separator())
        for (i, target) in ArmMode.allCases.enumerated() {
            let item = NSMenuItem(title: StatusItemController.title(for: target), action: #selector(menuSelectMode(_:)), keyEquivalent: "")
            item.attributedTitle = StatusItemController.menuTitle(StatusItemController.title(for: target), glyph: Self.glyph(for: target))
            item.target = self; item.tag = i; item.state = target == mode ? .on : .off
            m.addItem(item)
        }
        m.addItem(.separator())
        // With a hook set up: end the arm a minute after the work is over (a manual arm, or an auto-arm
        // ahead of its long hold-off). Pending until it fires; clicking again cancels.
        if (HookInstaller.installedCount() ?? 0) == HookConfig.events.count || HookInstaller.zshrcHasSnippet() {
            let once = NSMenuItem(title: L("Disarm once finished"), action: #selector(menuToggleDisarmOnce(_:)), keyEquivalent: "")
            once.target = self; once.state = activityDisarmOncePending ? .on : .off
            m.addItem(once)
            m.addItem(.separator())
        }
        let s = NSMenuItem(title: L("Settings…"), action: #selector(menuSettings), keyEquivalent: ","); s.target = self; m.addItem(s)
        m.addItem(.separator())
        let q = NSMenuItem(title: L("Quit KoffeeLid"), action: #selector(menuQuit), keyEquivalent: "q"); q.target = self; m.addItem(q)
        return m
    }
    private static func glyph(for mode: ArmMode) -> MugShape.State {
        switch mode { case .off: return .off; case .armed: return .armed; case .caffeinate: return .caffeinate }
    }
    @objc private func menuSelectMode(_ sender: NSMenuItem) { setMode(ArmMode.allCases[sender.tag], source: .menu) }
    @objc private func menuToggleDisarmOnce(_ sender: NSMenuItem) { requestActivityDisarmOnce(sender.state != .on) }

    /// The greyed line under the header: why a closed lid does not sleep while the menu says Off.
    private func autoArmHint() -> String {
        let kinds = activity.snapshot.kinds
        if kinds == [.claude] { return L("Auto-armed while Claude Code works") }
        if kinds == [.terminal] { return L("Auto-armed while a command runs") }
        if !kinds.isEmpty { return L("Auto-armed while Claude Code and a command run") }
        let left = activityPolicy.nextDeadline(after: Date()).map { $0.timeIntervalSinceNow } ?? 0
        let text = left >= 60 ? String(format: L("%d min"), Int((left / 60).rounded(.up))) : String(format: L("%d s"), Int(left.rounded(.up)))
        return String(format: L("Auto-armed, off in %@"), text)
    }
    @objc private func menuSettings() { onOpenSettings?() }
    @objc private func menuQuit() { NSApp.terminate(nil) }
}

/// Localization shim over the String Catalog.
func L(_ key: String) -> String { NSLocalizedString(key, comment: "") }
