import AppKit
import KoffeeLidCore

/// The Fn (or Option) + close detector: modifier state + lid angle → `GestureEvent`s for the coordinator.
///
/// The modifier is read fresh on every sample from two live sources: `CGEventSource.flagsState`, the
/// hardware/session state, and `NSEvent.modifierFlags`. Nothing is cached — a global `flagsChanged`
/// monitor never sees the events delivered to KoffeeLid itself, so a "down" flag kept from one would
/// stick whenever a key is released while one of our own windows is active, and the gesture would then
/// arm on any close.
///
/// Fn is the secondary-Fn flag *without* the numeric-pad flag (`FnKeyReading`): macOS raises the
/// secondary-Fn flag on arrow keys as well, and reading one of those as the gesture modifier both arms
/// on a plain lid adjustment and keeps the lid effect from settling back to flat.
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

    /// Live modifier state, never cached.
    func readModifier() -> Bool {
        let cg = CGEventSource.flagsState(.combinedSessionState)
        let ns = NSEvent.modifierFlags
        let hardware: Bool
        let events: Bool
        switch prefs.gestureModifier {
        case .fn:
            hardware = FnKeyReading.isFnDown(secondaryFn: cg.contains(.maskSecondaryFn), numericPad: cg.contains(.maskNumericPad))
            events = FnKeyReading.isFnDown(secondaryFn: ns.contains(.function), numericPad: ns.contains(.numericPad))
        case .option:
            hardware = cg.contains(.maskAlternate)
            events = ns.contains(.option)
        }
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
