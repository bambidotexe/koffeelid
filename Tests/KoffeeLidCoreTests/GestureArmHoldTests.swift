import XCTest
import KoffeeLidCore

final class GestureArmHoldTests: XCTestCase {
    func testAnIdleHoldIgnoresEverything() {
        var h = GestureArmHold()
        XCTAssertEqual(h.observed(locked: true), .nothing)
        XCTAssertEqual(h.observed(locked: false), .nothing)
        XCTAssertEqual(h.lockGaveUp(), .nothing)
        XCTAssertFalse(h.isHolding)
    }

    func testTheLidOpeningKeepsTheArm() {
        var h = GestureArmHold()
        XCTAssertEqual(h.lidOpened(), .keepArmed)
        XCTAssertTrue(h.isHolding)
    }

    func testTheLockLandingArmsTheHold() {
        var h = GestureArmHold()
        _ = h.lidOpened()
        XCTAssertEqual(h.observed(locked: true), .held)
        XCTAssertTrue(h.isHolding)
    }

    /// The whole point: unlocking is what ends a one-close arm, not the lid opening.
    func testUnlockingEndsTheArm() {
        var h = GestureArmHold()
        _ = h.lidOpened()
        _ = h.observed(locked: true)
        XCTAssertEqual(h.observed(locked: false), .release(.unlocked))
        XCTAssertFalse(h.isHolding)
    }

    /// Between the lid opening and the lock landing the screen is legitimately unlocked; that is not
    /// the user coming back, and it must not end the arm.
    func testTheUnlockedWindowBeforeTheLockDoesNotEndTheArm() {
        var h = GestureArmHold()
        _ = h.lidOpened()
        XCTAssertEqual(h.observed(locked: false), .nothing)
        XCTAssertTrue(h.isHolding)
    }

    /// No lock (no login password, or the lock failed) means "until I log back in" has no meaning:
    /// fall back to the old behaviour rather than hold an arm over a visible desktop.
    func testGivingUpOnTheLockEndsTheArm() {
        var h = GestureArmHold()
        _ = h.lidOpened()
        XCTAssertEqual(h.lockGaveUp(), .release(.neverLocked))
        XCTAssertFalse(h.isHolding)
    }

    func testGivingUpAfterTheLockLandedChangesNothing() {
        var h = GestureArmHold()
        _ = h.lidOpened()
        _ = h.observed(locked: true)
        XCTAssertEqual(h.lockGaveUp(), .nothing)
        XCTAssertTrue(h.isHolding)
    }

    /// Someone closes the lid and opens it again without logging in: still locked, still held.
    func testClosingAndReopeningWhileLockedKeepsTheArm() {
        var h = GestureArmHold()
        _ = h.lidOpened()
        _ = h.observed(locked: true)
        XCTAssertEqual(h.lidOpened(), .keepArmed)
        XCTAssertEqual(h.observed(locked: true), .held)   // already locked: confirmed at once
        XCTAssertTrue(h.isHolding)
        XCTAssertEqual(h.observed(locked: false), .release(.unlocked))
    }

    func testStayingLockedChangesNothing() {
        var h = GestureArmHold()
        _ = h.lidOpened()
        _ = h.observed(locked: true)
        XCTAssertEqual(h.observed(locked: true), .nothing)
        XCTAssertTrue(h.isHolding)
    }

    func testTheReleaseHappensOnlyOnce() {
        var h = GestureArmHold()
        _ = h.lidOpened()
        _ = h.observed(locked: true)
        XCTAssertEqual(h.observed(locked: false), .release(.unlocked))
        XCTAssertEqual(h.observed(locked: false), .nothing)
        XCTAssertEqual(h.lockGaveUp(), .nothing)
    }

    /// A rail, a new arm or a mode switch ends the session outright; the hold must not outlive it.
    func testClearDropsTheHold() {
        var h = GestureArmHold()
        _ = h.lidOpened()
        _ = h.observed(locked: true)
        h.clear()
        XCTAssertFalse(h.isHolding)
        XCTAssertEqual(h.observed(locked: false), .nothing)
    }

    func testReleaseReasonsReadAsLogLines() {
        XCTAssertEqual(GestureArmHold.Reason.unlocked.rawValue, "unlock")
        XCTAssertEqual(GestureArmHold.Reason.neverLocked.rawValue, "lid open; the screen never locked")
    }
}
