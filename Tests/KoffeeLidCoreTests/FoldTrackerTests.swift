import XCTest
import KoffeeLidCore

final class FoldTrackerTests: XCTestCase {
    func testOpeningNeverFolds() {
        var t = FoldTracker(angle: 80, now: 0, thresholdDegrees: 6)
        XCTAssertNil(t.update(angle: 90, now: 0.1))
        XCTAssertNil(t.update(angle: 100, now: 0.2))
        XCTAssertEqual(t.foldDegrees, 0); XCTAssertEqual(t.restAngle, 100)
    }
    func testNothingHappensBelowThreshold() {
        var t = FoldTracker(angle: 80, now: 0, thresholdDegrees: 6)
        XCTAssertNil(t.update(angle: 75, now: 0.1))
        XCTAssertEqual(t.foldDegrees, 0); XCTAssertFalse(t.isFolding)
    }
    func testFoldGrowsContinuouslyPastThreshold() {
        var t = FoldTracker(angle: 80, now: 0, thresholdDegrees: 6)
        XCTAssertEqual(t.update(angle: 73, now: 0.1), .foldBegan)
        XCTAssertEqual(t.foldDegrees, 1)
        XCTAssertNil(t.update(angle: 50, now: 0.2))
        XCTAssertEqual(t.foldDegrees, 24)
    }
    func testReopeningPlaysBackwardToRestMinusThresholdThenOpeningFurtherDoesNothing() {
        var t = FoldTracker(angle: 80, now: 0, thresholdDegrees: 6)
        t.update(angle: 50, now: 0.1)
        XCTAssertNil(t.update(angle: 60, now: 0.2)); XCTAssertEqual(t.foldDegrees, 14)
        XCTAssertEqual(t.update(angle: 74, now: 0.3), .foldEnded); XCTAssertEqual(t.foldDegrees, 0)
        XCTAssertNil(t.update(angle: 80, now: 0.4)); XCTAssertEqual(t.foldDegrees, 0)
        XCTAssertNil(t.update(angle: 100, now: 0.5)); XCTAssertEqual(t.foldDegrees, 0); XCTAssertEqual(t.restAngle, 100)
    }
    func testNextCloseStartsFromTheNewRestAngle() {
        var t = FoldTracker(angle: 80, now: 0, thresholdDegrees: 6)
        t.update(angle: 100, now: 0.1)
        XCTAssertNil(t.update(angle: 95, now: 0.2))
        XCTAssertEqual(t.update(angle: 93, now: 0.3), .foldBegan); XCTAssertEqual(t.foldDegrees, 1)
    }
    func testLeftPartlyClosedSettlesBackToFlat() {
        var t = FoldTracker(angle: 80, now: 0, thresholdDegrees: 6, settleDelay: 3)
        t.settleDuration = 0.5
        t.update(angle: 50, now: 0.1)
        XCTAssertNil(t.update(angle: 50.2, now: 2.0)); XCTAssertEqual(t.foldDegrees, 24, accuracy: 0.3)   // still, not yet
        XCTAssertNil(t.update(angle: 50.2, now: 3.2)); XCTAssertEqual(t.foldDegrees, 24, accuracy: 0.3)   // settling starts here
        t.update(angle: 50.2, now: 3.45)                                                                  // halfway: smoothstep(0.5) = 0.5
        XCTAssertEqual(t.foldDegrees, 12, accuracy: 0.5)
        XCTAssertEqual(t.update(angle: 50.2, now: 3.8), .foldEnded)
        XCTAssertEqual(t.foldDegrees, 0, accuracy: 1e-6); XCTAssertEqual(t.restAngle, 56.2, accuracy: 1e-6)
    }
    func testHoldingTheModifierPreventsTheSettleAndStopsOneInProgress() {
        var t = FoldTracker(angle: 80, now: 0, thresholdDegrees: 6, settleDelay: 1)
        t.settleDuration = 0.5
        t.update(angle: 60, now: 0.2)
        XCTAssertEqual(t.foldDegrees, 14, accuracy: 1e-9)
        for i in 1...100 { t.update(angle: 60, now: 0.2 + Double(i) * 0.05, holding: true) }        // 5 s still, Fn held
        XCTAssertEqual(t.foldDegrees, 14, accuracy: 1e-9)                                            // no settle
        t.update(angle: 60, now: 6.3); t.update(angle: 60, now: 6.5)                                  // released: settling begins
        XCTAssertLessThan(t.foldDegrees, 14); XCTAssertGreaterThan(t.foldDegrees, 0)
        let partial = t.foldDegrees
        t.update(angle: 60, now: 6.55, holding: true)                                                 // Fn again: settle stops where it is
        XCTAssertEqual(t.foldDegrees, partial, accuracy: 0.6)
        t.update(angle: 60, now: 9.0, holding: true)
        XCTAssertEqual(t.foldDegrees, partial, accuracy: 0.6)
    }
    func testIntegerFlickerBetweenTwoDegreesStillSettles() {
        var t = FoldTracker(angle: 110, now: 0, thresholdDegrees: 6, settleDelay: 1)
        t.settleDuration = 0.2
        t.update(angle: 89, now: 0.1)
        var now = 0.1
        for i in 0..<60 { now += 1.0 / 30; t.update(angle: i % 2 == 0 ? 90 : 89, now: now) }   // 2 s of 89↔90 flicker
        XCTAssertEqual(t.foldDegrees, 0, accuracy: 1e-6)                                          // settled back flat
    }
    func testMovementWhileSettlingCancelsTheSettle() {
        var t = FoldTracker(angle: 80, now: 0, thresholdDegrees: 6, settleDelay: 1)
        t.update(angle: 50, now: 0.1)
        t.update(angle: 50, now: 1.3)            // settling begins
        t.update(angle: 40, now: 1.4)            // user keeps closing
        XCTAssertGreaterThan(t.foldDegrees, 30)  // rest barely moved, fold follows the lid
        XCTAssertNil(t.update(angle: 30, now: 2.0)); XCTAssertGreaterThan(t.foldDegrees, 40)
    }
    func testAbsoluteGateIgnoresAdjustmentsWhileWorking() {
        var t = FoldTracker(angle: 110, now: 0, thresholdDegrees: 6, startBelowAngle: 60)
        XCTAssertNil(t.update(angle: 100, now: 0.1)); XCTAssertEqual(t.foldDegrees, 0)   // 10° adjustment: nothing
        XCTAssertNil(t.update(angle: 61, now: 0.2)); XCTAssertEqual(t.foldDegrees, 0)
        XCTAssertEqual(t.update(angle: 59, now: 0.3), .foldBegan); XCTAssertEqual(t.foldDegrees, 1)  // grows from the gate, no jump
        XCTAssertNil(t.update(angle: 30, now: 0.4)); XCTAssertEqual(t.foldDegrees, 30)
        XCTAssertEqual(t.update(angle: 60, now: 0.5), .foldEnded)
        XCTAssertNil(t.update(angle: 110, now: 0.6)); XCTAssertEqual(t.foldDegrees, 0)
    }
    func testAbsoluteGateStillHonoursThresholdFromALowerRest() {
        var t = FoldTracker(angle: 50, now: 0, thresholdDegrees: 6, startBelowAngle: 60)   // already working below the gate
        XCTAssertNil(t.update(angle: 46, now: 0.1)); XCTAssertEqual(t.foldDegrees, 0)
        XCTAssertEqual(t.update(angle: 43, now: 0.2), .foldBegan); XCTAssertEqual(t.foldDegrees, 1)
    }
    func testRebaseClearsEverything() {
        var t = FoldTracker(angle: 80, now: 0)
        t.update(angle: 40, now: 0.1)
        t.rebase(angle: 40, now: 0.2)
        XCTAssertEqual(t.foldDegrees, 0); XCTAssertEqual(t.restAngle, 40)
        XCTAssertNil(t.update(angle: 38, now: 0.3))
    }
}
