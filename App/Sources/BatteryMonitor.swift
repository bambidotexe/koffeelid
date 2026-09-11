import Foundation
import IOKit.ps
import KoffeeLidCore

final class BatteryMonitor {
    var onChange: ((BatteryState?) -> Void)?
    private var source: CFRunLoopSource?
    var current: BatteryState? { Self.read() }

    static func read() -> BatteryState? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let cap = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let onBattery = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSBatteryPowerValue
            return BatteryState(percent: Int((Double(cap) / Double(max) * 100).rounded()), onBattery: onBattery)
        }
        return nil
    }

    func start() {
        guard source == nil else { return }
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        source = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let m = Unmanaged<BatteryMonitor>.fromOpaque(ctx).takeUnretainedValue()
            m.onChange?(m.current)
        }, ctx)?.takeRetainedValue()
        if let s = source { CFRunLoopAddSource(CFRunLoopGetMain(), s, .defaultMode) }
    }
    func stop() { if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .defaultMode) }; source = nil }
    deinit { stop() }
}
