import Foundation

/// Whether reopening the lid must lock the screen.
///
/// While an external display is connected macOS runs its own clamshell mode and the session stayed
/// visible on that display the whole time, so the reopen does not lock (`DisplayTopology.standsBy`).
/// The catch, measured on this Mac on 2026-09-14 (charger-fed display, unplugged in clamshell): macOS
/// posts no screen-parameters change while the lid is closed and no display is left to reconfigure —
/// the disconnect lands ~130 ms *after* the lid-open notification. The decision taken at the lid-open
/// instant is therefore one event out of date, and the session that had been sitting behind a closed
/// lid with no display at all reopened unlocked.
///
/// So a skipped lock stays pending for `graceSeconds`: a disconnect arriving inside that window, with
/// the lid open, locks after all. Unplugging a display later, on a lid that has been open for a while,
/// is an ordinary act and must not lock.
public struct ReopenLockDecision {
    /// How long a skipped reopen lock stays open to a late topology change. The measured gap is ~130 ms.
    public var graceSeconds: TimeInterval
    private var skippedAt: TimeInterval?

    public init(graceSeconds: TimeInterval = 2) { self.graceSeconds = graceSeconds }

    /// The lid opened on an armed session. Returns true to lock now; a skipped lock stays pending.
    public mutating func lidOpened(standingBy: Bool, now: TimeInterval) -> Bool {
        skippedAt = standingBy ? now : nil
        return !standingBy
    }

    /// The external display turned out to be gone. Returns true to honour the reopen lock that was skipped.
    public mutating func externalDisplayGone(lidOpen: Bool, now: TimeInterval) -> Bool {
        guard lidOpen, let at = skippedAt, now - at <= graceSeconds else { return false }
        skippedAt = nil
        return true
    }

    /// The lid closed, the session ended, or a lock was requested another way: nothing is pending.
    public mutating func clear() { skippedAt = nil }
}
