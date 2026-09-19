import AppKit
import IOKit.hid

/// Reads the built-in keyboard's own Fn (Globe) key through IOKit HID, so that an external keyboard's Fn key
/// never counts as the gesture modifier. macOS gates keyboard HID input behind the Input Monitoring grant
/// (`IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)`); without it `fnDown` is nil and the session-wide read
/// (`CGEventSource.keyState`) stands alone.
///
/// The keyboard is the HID device with `Built-In` set among those of usage page 1 (Generic Desktop), usage 6
/// (Keyboard): "Apple Internal Keyboard / Trackpad" on this Mac. `Built-In` is not a key the kernel matches
/// on (a matching dictionary carrying it matched the external keyboard too), so the keyboards are enumerated
/// and filtered here, and only that one device is opened. Its Fn key is the input element on Apple's vendor
/// top-case page 0xFF, usage 3 (report 1); an external Apple keyboard carries the same element, which is why
/// the device, not the element, tells them apart. Values arrive on the main run loop; `fnDown` is read on
/// main by `GestureController.readModifier`, and a value that went stale (a missed key-up) is neutralised
/// there by the session key state, which `FnKeyReading` ANDs with it.
final class BuiltInFnKeyReader {
    enum State: Equatable { case stopped, notGranted, noDevice, openFailed(IOReturn), reading }
    private(set) var state: State = .stopped
    /// The built-in keyboard's Fn key, or nil while it cannot be read.
    var fnDown: Bool? { state == .reading ? down : nil }
    private var down = false
    private var device: IOHIDDevice?
    var onLog: ((String) -> Void)?

    static var isGranted: Bool { IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted }
    static var isDenied: Bool { IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeDenied }
    /// Shows the system prompt the first time; returns the current state.
    @discardableResult static func requestAccess() -> Bool { IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) }
    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    private static let keyboardMatching: [String: Any] = [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard]
    /// The Fn key: Apple's vendor top-case page / KeyboardFn, or the vendor keyboard page / Function.
    private static let fnElementMatching: [[String: Any]] = [
        [kIOHIDElementUsagePageKey: 0xFF, kIOHIDElementUsageKey: 3],
        [kIOHIDElementUsagePageKey: 0xFF01, kIOHIDElementUsageKey: 3],
    ]

    /// The keyboard whose `Built-In` property is set, among the keyboard HID devices. Needs no grant.
    static func builtInKeyboard() -> IOHIDDevice? {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, keyboardMatching as CFDictionary)
        let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
        return devices.first { (IOHIDDeviceGetProperty($0, kIOHIDBuiltInKey as CFString) as? Bool) == true }
    }

    deinit { stop() }

    /// (Re)opens the built-in keyboard. Logs the outcome; every outcome but `.reading` leaves `fnDown` nil.
    func start() {
        stop()
        guard Self.isGranted else {
            state = .notGranted; onLog?("built-in Fn reader: Input Monitoring not granted; any keyboard's Fn key counts"); return
        }
        guard let d = Self.builtInKeyboard() else {
            state = .noDevice; onLog?("built-in Fn reader: no built-in keyboard found; any keyboard's Fn key counts"); return
        }
        let r = IOHIDDeviceOpen(d, IOOptionBits(kIOHIDOptionsTypeNone))
        guard r == kIOReturnSuccess else {
            state = .openFailed(r)
            onLog?("built-in Fn reader: open FAILED (0x\(String(UInt32(bitPattern: r), radix: 16))); grant Input Monitoring and relaunch KoffeeLid; any keyboard's Fn key counts")
            return
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceSetInputValueMatchingMultiple(d, Self.fnElementMatching as CFArray)
        IOHIDDeviceRegisterInputValueCallback(d, { context, _, _, value in
            guard let context else { return }
            Unmanaged<BuiltInFnKeyReader>.fromOpaque(context).takeUnretainedValue().down = IOHIDValueGetIntegerValue(value) != 0
        }, context)
        IOHIDDeviceRegisterRemovalCallback(d, { context, _, _ in
            guard let context else { return }
            Unmanaged<BuiltInFnKeyReader>.fromOpaque(context).takeUnretainedValue().deviceRemoved()
        }, context)
        IOHIDDeviceScheduleWithRunLoop(d, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        device = d
        down = false
        state = .reading
        let name = (IOHIDDeviceGetProperty(d, kIOHIDProductKey as CFString) as? String) ?? "built-in keyboard"
        onLog?("built-in Fn reader: reading \(name); only its Fn key arms the lid gesture")
    }

    /// The grant lands while System Settings or the system prompt is in front, and the device can come back
    /// after a wake: called when the app is active again and after a wake.
    func retryIfNotReading() {
        guard state != .reading, Self.isGranted else { return }
        start()
    }

    private func deviceRemoved() {
        stop()
        state = .noDevice
        onLog?("built-in Fn reader: the built-in keyboard went away; any keyboard's Fn key counts until it is back")
    }

    func stop() {
        if let d = device {
            IOHIDDeviceRegisterInputValueCallback(d, nil, nil)
            IOHIDDeviceRegisterRemovalCallback(d, nil, nil)
            IOHIDDeviceUnscheduleFromRunLoop(d, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDDeviceClose(d, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        device = nil; down = false; state = .stopped
    }
}
