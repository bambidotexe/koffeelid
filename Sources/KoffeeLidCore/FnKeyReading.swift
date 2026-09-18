import Foundation

/// Tells the Fn (Globe) key apart from an arrow key in a modifier-flags reading.
///
/// macOS sets the secondary-Fn flag on every arrow-key event too, together with the numeric-pad
/// flag: a reading that carries the numeric-pad flag is an arrow key, not the Fn key. Taking it for
/// Fn makes the lid gesture fire on an ordinary lid adjustment, and — worse — keeps the lid effect
/// from returning to flat, because `FoldTracker` and `ReopenCancelWatch` both ignore stillness while
/// the gesture modifier is held.
public enum FnKeyReading {
    /// True when this reading is the Fn key itself: the secondary-Fn flag without the numeric-pad flag.
    public static func isFnDown(secondaryFn: Bool, numericPad: Bool) -> Bool {
        secondaryFn && !numericPad
    }
}
