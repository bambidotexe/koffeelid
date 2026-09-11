import XCTest
import KoffeeLidCore

final class AngleSmootherTests: XCTestCase {
    func testNoSamplesGivesNil() { var s = AngleSmoother(); XCTAssertNil(s.value(at: 1)) }
    func testSingleSampleHolds() {
        var s = AngleSmoother()
        s.feed(100, at: 0)
        XCTAssertEqual(s.value(at: 0.5), 100)
    }
    func testTwoEventsInterpolateLinearlyWithDelay() {
        var s = AngleSmoother(delay: 0.1)
        s.feed(100, at: 0); s.feed(90, at: 0.1)
        XCTAssertEqual(s.value(at: 0.15)!, 95, accuracy: 1e-9)   // reads at t=0.05
        var s2 = AngleSmoother(delay: 0.1)
        s2.feed(100, at: 0); s2.feed(90, at: 0.1)
        XCTAssertEqual(s2.value(at: 0.1)!, 100, accuracy: 1e-9)  // reads at t=0: the older event
    }
    func testHoldsAtLatestInsteadOfExtrapolating() {
        var s = AngleSmoother(delay: 0.1)
        s.feed(100, at: 0); s.feed(90, at: 0.1)
        XCTAssertEqual(s.value(at: 1.0), 90)
    }
    func testRepeatWithSameTimeAndValueIsIgnored() {
        var s = AngleSmoother()
        s.feed(10, at: 1.0); s.feed(13, at: 1.1); s.feed(16, at: 1.2)
        let before = s.estimate(at: 1.15)!
        s.feed(16, at: 1.2)
        XCTAssertEqual(s.estimate(at: 1.15)!, before, accuracy: 1e-12)
    }
    func testNewValueWithoutMotionIsHeldExactly() {
        // the fold eases back to flat while the lid stays put: same time stamp, new values
        var s = AngleSmoother()
        s.feed(10, at: 1.0); s.feed(13, at: 1.1); s.feed(16, at: 1.2)
        s.feed(4, at: 1.2)
        XCTAssertEqual(s.estimate(at: 1.2), 4)
        s.feed(0, at: 1.2)
        XCTAssertEqual(s.estimate(at: 5.0), 0)
    }
    /// The real pipeline: the sensor measures whole degrees at 10 Hz; the app polls at 120 Hz and
    /// delivers at 30 Hz, each delivery stamped with the time the value was first seen. Reads at 120 Hz.
    private func frameDeltas(_ angle: (Double) -> Double, from: Double, to: Double, phase: Double = 0, smoother: AngleSmoother = AngleSmoother()) -> (deltas: [Double], values: [Double], lags: [Double]) {
        var s = smoother
        var deltas: [Double] = [], values: [Double] = [], lags: [Double] = []; var last: Double?
        var poll = phase, deliver = phase; var seen: (Double, Double)?
        var t = 0.0
        while t <= to {
            while poll <= t {
                let v = angle(floor(poll * 10) / 10).rounded()
                if seen?.0 != v { seen = (v, poll) }
                if deliver <= poll { deliver += 1.0 / 30; if let seen { s.feed(seen.0, at: seen.1) } }
                poll += 1.0 / 120
            }
            if let v = s.value(at: t) {
                if t > from { if let l = last { deltas.append(l - v) }; values.append(v); lags.append(angle(t) - v) }
                last = v
            }
            t += 1.0 / 120
        }
        return (deltas, values, lags)
    }
    func testResponsivePresetCutsLagWithBoundedOvershoot() {
        let smooth = AngleSmoother(responsiveness: 0), quick = AngleSmoother(responsiveness: 1)
        XCTAssertEqual(smooth.prediction, 0); XCTAssertEqual(quick.delay, 0.04, accuracy: 1e-9); XCTAssertEqual(quick.prediction, 0.06, accuracy: 1e-9)
        let ramp: (Double) -> Double = { 100 - 45 * $0 }
        let lagSmooth = frameDeltas(ramp, from: 0.8, to: 2.0, smoother: smooth).lags, lagQuick = frameDeltas(ramp, from: 0.8, to: 2.0, smoother: quick).lags
        let mean: ([Double]) -> Double = { $0.reduce(0, +) / Double($0.count) }
        XCTAssertLessThan(abs(mean(lagQuick)), abs(mean(lagSmooth)) * 0.6)            // ~80 ms vs ~150 ms behind the lid
        let d = frameDeltas({ 100 - 15 * $0 }, from: 0.8, to: 2.0, smoother: quick).deltas
        for x in d { XCTAssertGreaterThan(x, 0.125 * 0.5); XCTAssertLessThan(x, 0.125 * 1.75) }   // jittery but never stop-and-go
        let stop = frameDeltas({ max(55, 100 - 45 * $0) }, from: 0.8, to: 2.0, smoother: quick).values    // abrupt stop at t = 1
        XCTAssertGreaterThanOrEqual(stop.min()!, 55 - 2.5)                            // overshoot bounded by the prediction cap
        XCTAssertEqual(stop.last!, 55, accuracy: 0.05)                                // and it comes back
    }
    func testSlowCloseHasNoStopAndGo() {
        for phase in [0.0, 0.003, 0.006] {
            let d = frameDeltas({ 100 - 15 * $0 }, from: 0.8, to: 2.0, phase: phase).deltas   // ideal 0.125°/frame
            XCTAssertFalse(d.isEmpty)
            XCTAssertEqual(d.reduce(0, +) / Double(d.count), 0.125, accuracy: 0.01)
            for x in d { XCTAssertGreaterThan(x, 0.125 * 0.6); XCTAssertLessThan(x, 0.125 * 1.4) }
        }
    }
    func testFastCloseReadsAtItsVelocity() {
        let d = frameDeltas({ 100 - 60 * $0 }, from: 0.8, to: 1.4).deltas                    // ideal 0.5°/frame
        for x in d { XCTAssertGreaterThan(x, 0.5 * 0.8); XCTAssertLessThan(x, 0.5 * 1.2) }
    }
    func testNeverOvershootsWhenTheLidStops() {
        let r = frameDeltas({ max(60, 100 - 60 * $0) }, from: 0.8, to: 2.5)
        for v in r.values { XCTAssertGreaterThanOrEqual(v, 60 - 1e-9) }
        XCTAssertEqual(r.values.last!, 60, accuracy: 1e-6)
    }
    func testResetForgetsSamples() {
        var s = AngleSmoother(); s.feed(1, at: 0); s.reset()
        XCTAssertNil(s.value(at: 1))
    }
}
