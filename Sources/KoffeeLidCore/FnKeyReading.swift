import Foundation

/// Tells the Fn (Globe) key apart from the other keys that raise its modifier flag.
///
/// macOS sets the secondary-Fn flag on every arrow-key event (together with the numeric-pad flag), and on
/// function keys used as F1–F12 and an external keyboard's navigation keys (without it). Only the physical
/// Fn key presses virtual key 63 (`kVK_Function`). Taking any other key for Fn makes the lid gesture fire on
/// an ordinary lid adjustment and — worse — keeps the lid effect from returning to flat, because
/// `FoldTracker` and `ReopenCancelWatch` both ignore stillness while the gesture modifier is held.
public enum FnKeyReading {
    /// True when this reading is the Fn key itself: the secondary-Fn flag, no numeric-pad flag, and key 63 down.
    /// `builtInKeyDown` is the built-in keyboard's own Fn key when it can be read (Input Monitoring granted):
    /// then only that key counts, so an external keyboard's Fn/Globe key never arms. `nil` when it cannot.
    public static func isFnDown(secondaryFn: Bool, numericPad: Bool, keyDown: Bool, builtInKeyDown: Bool? = nil) -> Bool {
        secondaryFn && !numericPad && keyDown && (builtInKeyDown ?? true)
    }
}
