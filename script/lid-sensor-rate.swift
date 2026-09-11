#!/usr/bin/env swift
// Measures how often the lid-angle sensor's value actually changes, to decide whether polling it
// faster than 30 Hz would buy anything. Polls the feature report at 250 Hz for N seconds (default 8)
// and prints the intervals between distinct values. Move the lid slowly and steadily while it runs:
//   swift script/lid-sensor-rate.swift 8
import Foundation
import IOKit.hid

let seconds = Double(CommandLine.arguments.dropFirst().first ?? "8") ?? 8
let matching: [String: Any] = [kIOHIDVendorIDKey: 0x05AC, kIOHIDProductIDKey: 0x8104, kIOHIDPrimaryUsagePageKey: 0x20, kIOHIDPrimaryUsageKey: 0x8A]
let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
guard let device = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>)?.first,
      IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
    print("lid-angle sensor not found"); exit(1)
}
var report = [UInt8](repeating: 0, count: 8)
func read() -> Int? {
    var length = CFIndex(report.count)
    guard IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, &report, &length) == kIOReturnSuccess, length >= 3 else { return nil }
    return Int(UInt16(report[1]) | (UInt16(report[2]) << 8))
}
print("polling at 250 Hz for \(Int(seconds)) s — move the lid slowly and steadily…")
let start = ProcessInfo.processInfo.systemUptime
var reads = 0, failures = 0
var lastValue: Int?, lastChange: TimeInterval?
var intervals: [TimeInterval] = [], steps: [Int] = []
var readCost: [TimeInterval] = []
while ProcessInfo.processInfo.systemUptime - start < seconds {
    let t0 = ProcessInfo.processInfo.systemUptime
    let v = read()
    let t1 = ProcessInfo.processInfo.systemUptime
    readCost.append(t1 - t0); reads += 1
    if let v {
        if let l = lastValue, v != l {
            if let c = lastChange { intervals.append(t1 - c) }
            steps.append(abs(v - l)); lastChange = t1
        } else if lastValue == nil { lastChange = t1 }
        lastValue = v
    } else { failures += 1 }
    usleep(4000)
}
IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
print("reads: \(reads), failed: \(failures), read cost: median \(Int(readCost.sorted()[readCost.count / 2] * 1e6)) µs, max \(Int(readCost.max()! * 1e6)) µs")
guard !intervals.isEmpty else { print("the value never changed — move the lid while this runs"); exit(0) }
let sorted = intervals.sorted()
let ms: (TimeInterval) -> String = { String(format: "%.1f ms", $0 * 1000) }
print("value changes: \(intervals.count + 1); interval between changes: min \(ms(sorted.first!)), median \(ms(sorted[sorted.count / 2])), max \(ms(sorted.last!))")
print("→ the sensor changes at most every \(ms(sorted.first!)) (~\(Int(1 / sorted.first!)) Hz); polling faster than that is wasted")
let hist = Dictionary(grouping: steps, by: { $0 }).mapValues(\.count).sorted { $0.key < $1.key }
print("step sizes: " + hist.map { "\($0.key)°×\($0.value)" }.joined(separator: ", "))
