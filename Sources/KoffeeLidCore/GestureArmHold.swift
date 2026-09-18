import Foundation

/// When a one-close (Fn + close) arm ends.
///
/// The arm survives the lid opening and ends when the user logs back in — the lid can be opened and
/// closed any number of times in between and the Mac stays awake, so nobody can stop the work by
/// opening and closing the lid.
///
/// The hold only means something if the session is locked, so it is armed by the lock landing (the
/// reopen lock the app requests anyway) and the arm ends at that reopen if that lock never takes —
/// on a Mac with no login password, since holding an arm over a visible desktop would be worse than
/// sleeping.
public struct GestureArmHold {
    public enum Reason: String, Equatable {
        case unlocked = "unlock"
        case neverLocked = "lid open; the screen never locked"
    }

    public enum Outcome: Equatable {
        /// Nothing to do.
        case nothing
        /// The lid opened on a one-close arm: keep it armed, the lock is on its way.
        case keepArmed
        /// The lock landed: the arm is now held until the user logs back in.
        case held
        /// End the one-close arm.
        case release(Reason)
    }

    private enum Phase { case off, awaitingLock, holding }
    private var phase: Phase = .off

    public init() {}

    /// True from the lid opening until the arm is released: the session outlives the reopen.
    public var isHolding: Bool { phase != .off }

    /// The lid opened while a one-close arm was running.
    public mutating func lidOpened() -> Outcome {
        phase = .awaitingLock
        return .keepArmed
    }

    /// The screen lock state, from either edge of `com.apple.screenIs(Un)locked` or a live read.
    /// Before the lock lands the screen is legitimately unlocked — that is not the user coming back.
    public mutating func observed(locked: Bool) -> Outcome {
        switch phase {
        case .off:
            return .nothing
        case .awaitingLock:
            guard locked else { return .nothing }
            phase = .holding
            return .held
        case .holding:
            guard !locked else { return .nothing }
            phase = .off
            return .release(.unlocked)
        }
    }

    /// The reopen lock exhausted its retries. Unreachable once the lock has landed, since the retry
    /// chain stops at the first confirmation.
    public mutating func lockGaveUp() -> Outcome {
        guard phase == .awaitingLock else { return .nothing }
        phase = .off
        return .release(.neverLocked)
    }

    /// A rail, a fresh arm or a mode switch ended the session: the hold must not outlive it.
    public mutating func clear() { phase = .off }
}
