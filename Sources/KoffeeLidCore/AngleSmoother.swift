import Foundation

/// Turns the lid-angle sensor's stream into a value that can be read every display frame without steps.
///
/// The sensor publishes a new whole-degree value only every ~100 ms (10 Hz); the app polls it faster and
/// stamps each value with the time it was *first seen*, so the smoother receives one sample per value
/// change (a repeat with the same time and value is ignored). It keeps `window` seconds of those events,
/// fits a least-squares line through them (which averages out the rounding) and evaluates it `delay` in
/// the past. When that read point lies past the newest event, the line is followed ahead by at most
/// `prediction` seconds (bounded so a sudden stop overshoots by at most a degree or two), and once no
/// event has arrived for `staleAfter` the prediction fades out over `fade` — the lid stopped or slowed —
/// and the estimate settles on the last real reading.
/// Between events nothing is extrapolated beyond that; inside the buffer the estimate never leaves the
/// buffered value range. The result is low-passed with time constant `responseTime`, so the shift of the
/// line at each new event becomes a change of velocity rather than a jump.
///
/// `tuning(responsiveness:)` maps one user value onto the three timings: 0 waits a full sensor period
/// (smoothest, ~150 ms behind the lid, no overshoot), 1 predicts ahead (~80 ms behind, a little jitter
/// on slow closes, ≤ ~2° overshoot on an abrupt stop). Simulated in `AngleSmootherTests`.
///
/// A new value arriving with the *same* time as the last one is a change without lid motion (the fold
/// easing back to flat, a rebase): the buffer collapses to that value so it is honoured exactly.
public struct AngleSmoother {
    public var delay: TimeInterval
    public var prediction: TimeInterval
    public var window: TimeInterval
    public var responseTime: TimeInterval
    public var staleAfter: TimeInterval = 0.15
    public var fade: TimeInterval = 0.12
    private var samples: [(value: Double, time: TimeInterval)] = []
    private var output: (value: Double, time: TimeInterval)?

    public init(delay: TimeInterval = 0.1, prediction: TimeInterval = 0, window: TimeInterval = 0.25, responseTime: TimeInterval = 0.05) {
        self.delay = delay; self.prediction = prediction; self.window = window; self.responseTime = responseTime
    }

    /// The three timings for a responsiveness in 0…1 (Advanced › Lid effect › Responsiveness).
    public static func tuning(responsiveness r: Double) -> (delay: TimeInterval, prediction: TimeInterval, responseTime: TimeInterval) {
        let r = min(1, max(0, r))
        return (0.10 - 0.06 * r, 0.06 * r, 0.05 - 0.02 * r)
    }

    public init(responsiveness r: Double) {
        let t = Self.tuning(responsiveness: r)
        self.init(delay: t.delay, prediction: t.prediction, responseTime: t.responseTime)
    }

    /// Retune without dropping the buffer (the slider moves mid-session).
    public mutating func apply(responsiveness r: Double) {
        let t = Self.tuning(responsiveness: r)
        delay = t.delay; prediction = t.prediction; responseTime = t.responseTime
    }

    public mutating func reset() { samples.removeAll(); output = nil }

    public mutating func feed(_ value: Double, at time: TimeInterval) {
        if let last = samples.last, time <= last.time {
            if value != last.value { samples = [(value, time)] }      // changed without motion: hold it
            return
        }
        samples.append((value, time))
        let cutoff = time - window
        samples.removeAll { $0.time < cutoff }
    }

    /// The smoothed value at `time`. Mutating: the low-pass remembers its previous output.
    public mutating func value(at time: TimeInterval) -> Double? {
        guard let target = estimate(readAt: time - delay, now: time) else { return nil }
        guard let o = output, time > o.time else { output = (target, time); return target }
        let k = 1 - exp(-(time - o.time) / max(1e-4, responseTime))
        let v = o.value + (target - o.value) * k
        output = (v, time)
        return v
    }

    /// The fitted-line estimate for a read point `t` with no prediction fade (tests).
    public func estimate(at t: TimeInterval) -> Double? { estimate(readAt: t, now: t) }

    /// Least-squares line through the buffered events, evaluated at `t`: clamped to the events' time span
    /// and value range when inside it, followed ahead by at most `prediction` (fading once events stop)
    /// when `t` is past the newest event.
    public func estimate(readAt t: TimeInterval, now: TimeInterval) -> Double? {
        guard let first = samples.first, let last = samples.last else { return nil }
        guard samples.count >= 2 else { return last.value }
        let n = Double(samples.count)
        let mt = samples.reduce(0) { $0 + $1.time } / n
        let mv = samples.reduce(0) { $0 + $1.value } / n
        var sxx = 0.0, sxy = 0.0
        for s in samples { let dx = s.time - mt; sxx += dx * dx; sxy += dx * (s.value - mv) }
        let slope = sxx > 1e-12 ? sxy / sxx : 0
        var lo = last.value, hi = last.value
        for s in samples { lo = min(lo, s.value); hi = max(hi, s.value) }
        let line = { (x: TimeInterval) in mv + slope * (x - mt) }
        if t <= last.time { return min(hi, max(lo, line(max(t, first.time)))) }
        let ahead = min(t - last.time, prediction)
        let sinceEvent = now - last.time
        let alive = sinceEvent <= staleAfter ? 1.0 : max(0, 1 - (sinceEvent - staleAfter) / max(1e-4, fade))
        // Past the newest event: the fitted line's value there (+ the bounded prediction) while events keep
        // coming; once they stop, settle on the last real reading — the line carries a rounding residual.
        let base = min(hi, max(lo, line(last.time)))
        return base * alive + last.value * (1 - alive) + slope * ahead * alive
    }
}
