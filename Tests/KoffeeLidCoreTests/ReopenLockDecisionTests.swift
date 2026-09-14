import XCTest
import KoffeeLidCore

final class ReopenLockDecisionTests: XCTestCase {
    func testLocksWhenTheLidOpensWithNoExternalDisplay() {
        var d = ReopenLockDecision()
        XCTAssertTrue(d.lidOpened(standingBy: false, now: 100))
    }

    func testSkipsTheLockWhenTheLidOpensOnAnExternalDisplay() {
        var d = ReopenLockDecision()
        XCTAssertFalse(d.lidOpened(standingBy: true, now: 100))
    }

    /// The bug (2026-09-14): the charger feeding the external display is unplugged while the lid is
    /// closed, macOS only reports the topology change ~130 ms after the lid-open notification, and the
    /// session — hidden behind a closed lid with no display at all — reopened unlocked.
    func testLocksWhenTheDisplayTurnsOutToHaveBeenGoneAtTheReopen() {
        var d = ReopenLockDecision()
        XCTAssertFalse(d.lidOpened(standingBy: true, now: 100))
        XCTAssertTrue(d.externalDisplayGone(lidOpen: true, now: 100.13))
    }

    func testTheLateLockFiresOnlyOnce() {
        var d = ReopenLockDecision()
        _ = d.lidOpened(standingBy: true, now: 100)
        XCTAssertTrue(d.externalDisplayGone(lidOpen: true, now: 100.13))
        XCTAssertFalse(d.externalDisplayGone(lidOpen: true, now: 100.2))
    }

    /// Unplugging the display long after a clamshell reopen is an ordinary act, not a hidden session.
    func testDoesNotLockWhenTheDisplayGoesAwayAfterTheGraceWindow() {
        var d = ReopenLockDecision(graceSeconds: 2)
        _ = d.lidOpened(standingBy: true, now: 100)
        XCTAssertFalse(d.externalDisplayGone(lidOpen: true, now: 102.01))
    }

    func testDoesNotLockWhenTheDisplayGoesAwayWhileTheLidIsStillClosed() {
        var d = ReopenLockDecision()
        _ = d.lidOpened(standingBy: true, now: 100)
        // The lid closed again in between: the reopen it skipped is over.
        d.clear()
        XCTAssertFalse(d.externalDisplayGone(lidOpen: false, now: 100.5))
    }

    func testAReopenThatLockedLeavesNothingPending() {
        var d = ReopenLockDecision()
        XCTAssertTrue(d.lidOpened(standingBy: false, now: 100))
        XCTAssertFalse(d.externalDisplayGone(lidOpen: true, now: 100.13))
    }

    func testClearDropsThePendingSkip() {
        var d = ReopenLockDecision()
        _ = d.lidOpened(standingBy: true, now: 100)
        d.clear()
        XCTAssertFalse(d.externalDisplayGone(lidOpen: true, now: 100.13))
    }

    func testASecondReopenReplacesThePendingSkip() {
        var d = ReopenLockDecision(graceSeconds: 2)
        _ = d.lidOpened(standingBy: true, now: 100)
        _ = d.lidOpened(standingBy: true, now: 105)
        XCTAssertTrue(d.externalDisplayGone(lidOpen: true, now: 105.13))
    }
}
