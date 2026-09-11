import XCTest
import KoffeeLidCore

final class LidProgressDriverTests: XCTestCase {
    func testArmsAfterActivationDegreesWithOption() {
        var d = LidProgressDriver(angleOpen: 120, angleClosed: 5, activationDegrees: 6, reverseCancelDegrees: 4, graceSeconds: 1.5)
        XCTAssertEqual(d.feed(angle: 120, optionTrusted: true, now: 0), .started(angle: 120))
        XCTAssertEqual(d.feed(angle: 117, optionTrusted: true, now: 0.03), .progress(3.0 / 115.0))
        XCTAssertEqual(d.feed(angle: 113, optionTrusted: true, now: 0.06), .armed(angle: 113, start: 120))
        XCTAssertTrue(d.activated)
        XCTAssertNil(d.feed(angle: 100, optionTrusted: true, now: 0.09))            // silent after arming
    }
    func testArmsFromAnyOpenAngleRegardlessOfCalibratedOpenAngle() {
        // The lid was once opened to 129° (persisted as angleOpen); the user now works at 95°.
        var d = LidProgressDriver(angleOpen: 129, activationDegrees: 6)
        XCTAssertEqual(d.feed(angle: 95, optionTrusted: true, now: 0), .started(angle: 95))
        XCTAssertEqual(d.feed(angle: 88, optionTrusted: true, now: 0.03), .armed(angle: 88, start: 95))
    }
    func testDoesNotStartWhenLidIsAlreadyClosed() {
        var d = LidProgressDriver(angleClosed: 5)
        XCTAssertNil(d.feed(angle: 4, optionTrusted: true, now: 0))
    }
    func testOptionReleasedJustBeforeActivationStillArmsWithinGrace() {
        var d = LidProgressDriver(activationDegrees: 6, optionGraceSeconds: 1.0)
        _ = d.feed(angle: 100, optionTrusted: true, now: 0)
        XCTAssertEqual(d.feed(angle: 98, optionTrusted: true, now: 0.03), .progress(2.0 / 95.0))
        XCTAssertEqual(d.feed(angle: 96, optionTrusted: false, now: 0.06), .progress(4.0 / 95.0))   // option gone: tolerated
        XCTAssertEqual(d.feed(angle: 93, optionTrusted: false, now: 0.09), .armed(angle: 93, start: 100))
    }
    func testOptionLostCancelsAfterGrace() {
        var d = LidProgressDriver(optionGraceSeconds: 1.0)
        _ = d.feed(angle: 120, optionTrusted: true, now: 0)
        _ = d.feed(angle: 118, optionTrusted: true, now: 0.03)
        XCTAssertEqual(d.feed(angle: 118, optionTrusted: false, now: 0.06), .progress(2.0 / 115.0))
        XCTAssertEqual(d.feed(angle: 118, optionTrusted: false, now: 1.1), .cancelled(.optionLost))
        XCTAssertFalse(d.activated)
    }
    func testOptionBackBeforeGraceEndsClearsTheLoss() {
        var d = LidProgressDriver(optionGraceSeconds: 1.0)
        _ = d.feed(angle: 120, optionTrusted: true, now: 0)
        _ = d.feed(angle: 119, optionTrusted: false, now: 0.5)
        _ = d.feed(angle: 119, optionTrusted: true, now: 0.9)
        XCTAssertEqual(d.feed(angle: 119, optionTrusted: true, now: 1.4), .progress(1.0 / 115.0))
    }
    func testReversalCancels() {
        var d = LidProgressDriver(reverseCancelDegrees: 4)
        _ = d.feed(angle: 120, optionTrusted: true, now: 0)
        _ = d.feed(angle: 116, optionTrusted: true, now: 0.03)
        XCTAssertEqual(d.feed(angle: 120.5, optionTrusted: true, now: 0.06), .cancelled(.reversed))
    }
    func testTimeoutAfterPartialCloseCancels() {
        var d = LidProgressDriver(graceSeconds: 1.0)
        _ = d.feed(angle: 120, optionTrusted: true, now: 0)
        _ = d.feed(angle: 118, optionTrusted: true, now: 0.5)
        XCTAssertEqual(d.feed(angle: 118, optionTrusted: true, now: 1.6), .cancelled(.timeout))
    }
    func testHoldingOptionWithoutMovingSilentlyRebasesInsteadOfCancelling() {
        // The user presses Option, waits, then closes: the gesture must still work from where the lid is.
        var d = LidProgressDriver(activationDegrees: 6, graceSeconds: 1.0)
        XCTAssertEqual(d.feed(angle: 120, optionTrusted: true, now: 0), .started(angle: 120))
        XCTAssertEqual(d.feed(angle: 120.4, optionTrusted: true, now: 0.5), .progress(0))
        XCTAssertNil(d.feed(angle: 120.6, optionTrusted: true, now: 2.0))                // stalled: rebased, no event
        XCTAssertEqual(d.feed(angle: 114, optionTrusted: true, now: 2.03), .armed(angle: 114, start: 120.6))
    }
    func testNoGestureWithoutOption() {
        var d = LidProgressDriver()
        XCTAssertNil(d.feed(angle: 120, optionTrusted: false, now: 0))
        XCTAssertNil(d.feed(angle: 100, optionTrusted: false, now: 0.03))
    }
    func testAutoCalibrateOpenTracksMax() {
        var d = LidProgressDriver(angleOpen: 110, autoCalibrateOpen: true)
        _ = d.feed(angle: 125, optionTrusted: false, now: 0)
        XCTAssertEqual(d.angleOpen, 125)
    }
    func testArmedStaysSilentWhileHeldAndResetsWhenTheModifierIsReleased() {
        var d = LidProgressDriver(activationDegrees: 4)
        _ = d.feed(angle: 120, optionTrusted: true, now: 0)
        XCTAssertEqual(d.feed(angle: 115, optionTrusted: true, now: 0.03), .armed(angle: 115, start: 120))
        XCTAssertNil(d.feed(angle: 110, optionTrusted: true, now: 0.06)); XCTAssertTrue(d.activated)   // held: one arm per hold
        XCTAssertNil(d.feed(angle: 105, optionTrusted: true, now: 0.09)); XCTAssertTrue(d.activated)
        XCTAssertNil(d.feed(angle: 100, optionTrusted: false, now: 0.12)); XCTAssertFalse(d.activated) // released: reset
        XCTAssertEqual(d.feed(angle: 100, optionTrusted: true, now: 5), .started(angle: 100))         // next hold works
        XCTAssertEqual(d.feed(angle: 95, optionTrusted: true, now: 5.03), .armed(angle: 95, start: 100))
    }
    func testSoftlockReplay_gestureWhileArmedThenDisarmWithoutReset() {
        // 2026-09-11: armed from the shortcut, Fn + close as feedback (.armed), Fn released, disarmed, then
        // Fn + close again — nobody called reset(); the driver must recover on its own.
        var d = LidProgressDriver(activationDegrees: 4)
        _ = d.feed(angle: 130, optionTrusted: true, now: 0)
        XCTAssertEqual(d.feed(angle: 124, optionTrusted: true, now: 0.1), .armed(angle: 124, start: 130))
        for i in 0..<30 { XCTAssertNil(d.feed(angle: 124 - Double(i), optionTrusted: i < 10, now: 0.2 + Double(i) * 0.033)) }
        XCTAssertFalse(d.activated)
        XCTAssertEqual(d.feed(angle: 110, optionTrusted: true, now: 20), .started(angle: 110))
        XCTAssertEqual(d.feed(angle: 105, optionTrusted: true, now: 20.1), .armed(angle: 105, start: 110))
    }
    func testResetAllowsNewGesture() {
        var d = LidProgressDriver()
        _ = d.feed(angle: 120, optionTrusted: true, now: 0)
        _ = d.feed(angle: 110, optionTrusted: true, now: 0.03)
        d.reset()
        XCTAssertFalse(d.activated)
        _ = d.feed(angle: 120, optionTrusted: true, now: 5)
        XCTAssertEqual(d.feed(angle: 110, optionTrusted: true, now: 5.03), .armed(angle: 110, start: 120))
    }
}
