import AppKit
import KoffeeLidCore

/// The Fn (or Option) + close detector: modifier state + lid angle → `GestureEvent`s for the coordinator.
///
/// The modifier is read fresh on every sample from two live sources (`CGEventSource.flagsState`, the
/// hardware/session state, and `NSEvent.modifierFlags`). Nothing is cached: an earlier global
/// `flagsChanged` monitor kept its own "down" flag, and because global monitors never see events delivered to
/// KoffeeLid itself, a key released while our Settings window was active left that flag stuck — the gesture
/// then armed on any close and, after `OptionGateFilter`'s 20 s hold limit, went dead (`docs/gesture.md`).
final class GestureController {
    private let prefs: Preferences
    private var gate = OptionGateFilter()
    private var driver: LidProgressDriver
    /// Which source last saw the modifier down ("hardware", "events" or "none"), for the log only.
    private(set) var modifierSource = "none"
    var onEvent: ((GestureEvent) -> Void)?

    init(prefs: Preferences) {
        self.prefs = prefs
        driver = LidProgressDriver(angleOpen: prefs.gestureAngleOpen, activationDegrees: prefs.gestureActivationDegrees,
                                   reverseCancelDegrees: prefs.gestureReverseCancelDegrees)
    }

    private var flag: NSEvent.ModifierFlags { prefs.gestureModifier == .fn ? .function : .option }
    private var cgFlag: CGEventFlags { prefs.gestureModifier == .fn ? .maskSecondaryFn : .maskAlternate }

    /// Live modifier state, never cached.
    func readModifier() -> Bool {
        let hardware = CGEventSource.flagsState(.combinedSessionState).contains(cgFlag)
        let events = NSEvent.modifierFlags.contains(flag)
        modifierSource = hardware ? "hardware" : events ? "events" : "none"
        return hardware || events
    }

    /// Back to "no gesture in progress": called whenever the coordinator (re)enters a state in which the
    /// detector listens, on every arm and disarm, and when a gesture preference changes.
    func reset() {
        driver.reset()
        gate = OptionGateFilter()
        driver.activationDegrees = prefs.gestureActivationDegrees
        driver.reverseCancelDegrees = prefs.gestureReverseCancelDegrees
    }

    /// Call on the main thread for every filtered angle sample while the detector is wanted.
    /// `modifierDown` is this sample's `readModifier()` (the coordinator reads it once per sample).
    func feed(angle: Double, modifierDown: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        let trusted = gate.feed(optionDown: modifierDown, now: now)
        if let e = driver.feed(angle: angle, optionTrusted: trusted, now: now) {
            if driver.angleOpen != prefs.gestureAngleOpen { prefs.gestureAngleOpen = driver.angleOpen }
            onEvent?(e)
        }
    }
}
