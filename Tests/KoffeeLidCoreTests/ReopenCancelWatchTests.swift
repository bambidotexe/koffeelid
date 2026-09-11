import XCTest
import KoffeeLidCore

final class ReopenCancelWatchTests: XCTestCase {
    private func feed(_ w: inout ReopenCancelWatch, _ angle: Double, _ now: TimeInterval) -> ReopenCancelWatch.Verdict? {
        w.update(angle: angle, now: now, cancelDegrees: 4, stallSeconds: 3)
    }
    func testClosingFurtherNeverCancels() {
        var w = ReopenCancelWatch(angle: 100, now: 0)
        XCTAssertNil(feed(&w, 90, 0.1)); XCTAssertNil(feed(&w, 40, 0.2))
        XCTAssertEqual(w.minAngle, 40)
    }
    func testReopeningByCancelDegreesFromTheMinimumCancels() {
        var w = ReopenCancelWatch(angle: 100, now: 0)
        _ = feed(&w, 60, 0.1)
        XCTAssertNil(feed(&w, 63.9, 0.2))
        XCTAssertEqual(feed(&w, 64, 0.3), .reopened)
    }
    func testMinimumIsMeasuredFromTheLowestPointNotTheStart() {
        var w = ReopenCancelWatch(angle: 100, now: 0)
        _ = feed(&w, 97, 0.1)
        XCTAssertNil(feed(&w, 99, 0.2))                 // only 2° above the minimum
        XCTAssertEqual(feed(&w, 101, 0.3), .reopened)
    }
    func testStandingStillForStallSecondsCancels() {
        var w = ReopenCancelWatch(angle: 100, now: 0)
        _ = feed(&w, 90, 0.5)
        XCTAssertNil(feed(&w, 90.3, 2.0))               // jitter under the stillness threshold
        XCTAssertNil(feed(&w, 90.2, 3.4))
        XCTAssertEqual(feed(&w, 90.4, 3.5), .stalled)   // 3 s after the last real movement at 0.5
    }
    func testIntegerFlickerCountsAsStill() {
        var w = ReopenCancelWatch(angle: 100, now: 0)
        _ = feed(&w, 90, 0.1)
        var now = 0.1; var verdict: ReopenCancelWatch.Verdict?
        for i in 0..<120 { now += 1.0 / 30; verdict = feed(&w, i % 2 == 0 ? 91 : 90, now); if verdict != nil { break } }
        XCTAssertEqual(verdict, .stalled)
        XCTAssertLessThan(now, 3.3)
    }
    func testHoldingTheModifierPausesTheStallClockAndRestartsItOnRelease() {
        var w = ReopenCancelWatch(angle: 100, now: 0)
        _ = feed(&w, 90, 0.5)
        for i in 1...120 { XCTAssertNil(w.update(angle: 90, now: 0.5 + Double(i) * 0.05, cancelDegrees: 4, stallSeconds: 3, held: true)) }   // 6 s held, still
        XCTAssertNil(feed(&w, 90, 9.4))                  // released at ~6.5 s: the clock starts there
        XCTAssertEqual(feed(&w, 90, 9.6), .stalled)
    }
    func testKeepClosingResetsTheStallClock() {
        var w = ReopenCancelWatch(angle: 100, now: 0)
        _ = feed(&w, 90, 2.9)
        XCTAssertNil(feed(&w, 80, 5.8))
        XCTAssertNil(feed(&w, 80, 8.7))
        XCTAssertEqual(feed(&w, 80, 8.9), .stalled)
    }
}
