import Foundation
import IOKit.hid

/// Apple lid-angle sensor: vendor 0x05AC, product 0x8104, usage page 0x20 (Sensor), usage 0x8A.
final class LidAngleSensor {
    private let manager: IOHIDManager
    private let device: IOHIDDevice
    private var report = [UInt8](repeating: 0, count: 8)

    static var matching: [String: Any] {
        [kIOHIDVendorIDKey: 0x05AC, kIOHIDProductIDKey: 0x8104, kIOHIDPrimaryUsagePageKey: 0x20, kIOHIDPrimaryUsageKey: 0x8A]
    }

    static var isPresent: Bool {
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(m, matching as CFDictionary)
        return (IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice>)?.isEmpty == false
    }

    init?() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, Self.matching as CFDictionary)
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, let d = devices.first else { return nil }
        device = d
        guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { return nil }
    }

    deinit { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }

    /// Feature report 1: byte 0 = report id, bytes 1–2 = little-endian degrees.
    func read() -> Double? {
        var length = CFIndex(report.count)
        let r = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, &report, &length)
        guard r == kIOReturnSuccess, length >= 3 else { return nil }
        let raw = Double(UInt16(report[1]) | (UInt16(report[2]) << 8))
        return (0...180).contains(raw) ? raw : nil
    }
}
