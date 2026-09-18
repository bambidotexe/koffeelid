import Foundation
import KoffeeLidCore

/// Polls the lid-angle sensor and delivers samples on the main thread at a steady 30 Hz.
///
/// The sensor publishes a new whole-degree value only every ~100 ms. While the lid is moving (a value
/// change within the last `motionHold`) the poll runs at 120 Hz so the moment each value appears is
/// known to ~8 ms instead of ~33 ms; at rest it drops back to 30 Hz (a read costs ~0.5 ms). Delivery
/// stays at 30 Hz whatever the poll rate, so the gesture filters keep their sample counts, and every
/// delivery carries the time its value was first seen, which is what the effect's smoother interpolates.
///
/// Threading: `addConsumer`/`removeConsumer` and the `timer` property are main-thread only;
/// everything the tick touches (`filter`, `current`, `lastDelivery`, `fast`) lives on `queue`.
final class LidAngleObserver {
    private let sensor: LidAngleSensor
    private let deliveryInterval: TimeInterval
    private let fastInterval: TimeInterval = 1.0 / 120
    private let motionHold: TimeInterval = 0.7
    private let queue = DispatchQueue(label: "dev.rubens.koffeelid.lid-angle", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var consumers = Set<String>()
    // queue-only state
    private var fast = false
    private var filter = AngleSampleFilter()
    private var failures = 0
    private var current: (angle: Double, since: TimeInterval)?
    private var lastDelivery: TimeInterval = 0
    /// Angle in degrees and the system uptime at which that value was first read.
    var onSample: ((Double, TimeInterval) -> Void)?
    var onLog: ((String) -> Void)?

    init(sensor: LidAngleSensor, hz: Double = 30) { self.sensor = sensor; deliveryInterval = 1 / hz }

    /// Must be called on the main thread.
    func addConsumer(_ id: String) { consumers.insert(id); if timer == nil { start() } }
    /// Must be called on the main thread.
    func removeConsumer(_ id: String) { consumers.remove(id); if consumers.isEmpty { stop() } }

    private func start() {
        queue.async { [self] in filter.reset(); current = nil; lastDelivery = 0; fast = false; failures = 0 }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: deliveryInterval, leeway: .milliseconds(3))
        t.setEventHandler { [weak self, weak t] in
            guard let self, let t else { return }
            self.tick(timer: t)
        }
        t.resume(); timer = t
    }

    private func stop() { timer?.cancel(); timer = nil }

    private func setFast(_ on: Bool, timer: DispatchSourceTimer) {
        guard on != fast else { return }
        fast = on
        let interval = on ? fastInterval : deliveryInterval
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(on ? 1 : 3))
    }

    private func tick(timer: DispatchSourceTimer) {
        let now = ProcessInfo.processInfo.systemUptime
        guard let raw = sensor.read() else {
            failures += 1
            if failures == 30 { DispatchQueue.main.async { self.onLog?("lid-angle sensor reads failing repeatedly; tilt gesture inactive") } }
            return
        }
        if failures >= 30 { DispatchQueue.main.async { self.onLog?("lid-angle sensor recovered") } }
        failures = 0
        guard let angle = filter.accept(raw) else { return }
        if current?.angle != angle { current = (angle, now) }
        setFast(now - current!.since < motionHold, timer: timer)
        guard now - lastDelivery >= deliveryInterval - 0.004 else { return }
        lastDelivery = now
        let since = current!.since
        DispatchQueue.main.async { self.onSample?(angle, since) }
    }
}
