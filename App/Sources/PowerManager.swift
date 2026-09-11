import Foundation
import IOKit
import IOKit.pwr_mgt
import IOKit.ps
import AppKit

enum PowerManagerError: Error { case cannotOpenRootDomain, callFailed(kern_return_t) }

final class PowerManager {
    private static let kPMSetClamshellSleepState: UInt32 = 12   // xnu IOPMLibDefs.h
    private var connect: io_connect_t = 0
    private var rootDomain: io_service_t = 0
    private(set) var lidSleepDisabled = false

    private var idleAssertion: IOPMAssertionID = 0
    private var systemAssertion: IOPMAssertionID = 0
    private var displayAssertion: IOPMAssertionID = 0
    private var activityAssertion: IOPMAssertionID = 0
    private var activityTimer: Timer?
    private var notifyPort: IONotificationPortRef?
    private var interestNotification: io_object_t = 0
    private var powerSourceRunLoopSource: CFRunLoopSource?
    private var observers: [NSObjectProtocol] = []

    var onLog: ((String) -> Void)?
    var onLidStateNotification: (() -> Void)?
    var onReapplyNeeded: ((String) -> Void)?

    init() throws {
        rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard rootDomain != 0, IOServiceOpen(rootDomain, mach_task_self_, 0, &connect) == KERN_SUCCESS, connect != 0 else {
            throw PowerManagerError.cannotOpenRootDomain
        }
    }

    deinit { stopMonitoring(); activityTimer?.invalidate(); if activityAssertion != 0 { IOPMAssertionRelease(activityAssertion) }; if connect != 0 { IOServiceClose(connect) }; if rootDomain != 0 { IOObjectRelease(rootDomain) } }

    func setLidSleepDisabled(_ disabled: Bool) throws {
        var input: UInt64 = disabled ? 1 : 0
        let kr = IOConnectCallScalarMethod(connect, Self.kPMSetClamshellSleepState, &input, 1, nil, nil)
        guard kr == KERN_SUCCESS else { throw PowerManagerError.callFailed(kr) }
        lidSleepDisabled = disabled
    }

    func acquireAssertions() {
        // A refused assertion is silent otherwise: the Mac would sleep mid-session with no
        // trace of why, so the IOReturn goes to the diagnostics log.
        if idleAssertion == 0 {
            let kr = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 "KoffeeLid: keeping Mac awake" as CFString, &idleAssertion)
            if kr != kIOReturnSuccess { onLog?("assertion PreventUserIdleSystemSleep FAILED (IOReturn \(kr))") }
        }
        if systemAssertion == 0 {
            let kr = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventSystemSleep as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 "KoffeeLid: protecting closed-lid power transitions" as CFString, &systemAssertion)
            if kr != kIOReturnSuccess { onLog?("assertion PreventSystemSleep FAILED (IOReturn \(kr))") }
        }
    }

    func releaseAssertions() {
        if idleAssertion != 0 { IOPMAssertionRelease(idleAssertion); idleAssertion = 0 }
        if systemAssertion != 0 { IOPMAssertionRelease(systemAssertion); systemAssertion = 0 }
    }

    // MARK: caffeinate

    /// Armed + screen on: the display never sleeps on idle (what Vorssaint holds as
    /// "keep the display on"). Held for the whole caffeinate session, lid open or closed.
    var keepDisplayOn: Bool = false {
        didSet {
            guard keepDisplayOn != oldValue else { return }
            if keepDisplayOn {
                let kr = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                                     IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                     "KoffeeLid: keeping the display on" as CFString, &displayAssertion)
                if kr != kIOReturnSuccess { onLog?("assertion PreventUserIdleDisplaySleep FAILED (IOReturn \(kr))") }
                else { onLog?("display kept on (caffeinate)") }
            } else if displayAssertion != 0 {
                IOPMAssertionRelease(displayAssertion); displayAssertion = 0
                onLog?("display keep-on released")
            }
        }
    }

    /// The screen saver and "require password after…" run on the user-idle timer, which the display
    /// assertion does not reset. Declaring activity every 30 s does. Only while the lid is open:
    /// a declaration wakes a sleeping display, and the closed lid's panel must stay dark.
    var tickleUserActivity: Bool = false {
        didSet {
            guard tickleUserActivity != oldValue else { return }
            activityTimer?.invalidate(); activityTimer = nil
            guard tickleUserActivity else {
                if activityAssertion != 0 { IOPMAssertionRelease(activityAssertion); activityAssertion = 0 }
                return
            }
            let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.declareUserActivity() }
            t.tolerance = 5
            RunLoop.main.add(t, forMode: .common)
            activityTimer = t
            declareUserActivity()
        }
    }

    /// Passing the previous id refreshes the same `UserIsActive` assertion instead of piling up new ones.
    private func declareUserActivity() {
        IOPMAssertionDeclareUserActivity("KoffeeLid: caffeinate" as CFString, kIOPMUserActiveLocal, &activityAssertion)
    }

    func readLidClosed() -> Bool? {
        guard let v = IORegistryEntryCreateCFProperty(rootDomain, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0) else { return nil }
        return (v.takeRetainedValue() as? Bool)
    }

    /// The kernel's own view of the flag: `false` means closing the lid no longer sleeps
    /// the Mac, i.e. lid-close sleep is currently disabled. `nil` when unreadable.
    func readLidCausesSleep() -> Bool? {
        guard let v = IORegistryEntryCreateCFProperty(rootDomain, "AppleClamshellCausesSleep" as CFString, kCFAllocatorDefault, 0) else { return nil }
        return (v.takeRetainedValue() as? Bool)
    }

    /// The root domain's "Last Sleep Reason", written before `kIOMessageSystemWillSleep` goes out:
    /// "Clamshell Sleep" for a lid evaluation, "Software Sleep" for pmset/Apple menu, "Idle Sleep", …
    func readLastSleepReason() -> String? {
        guard let v = IORegistryEntryCreateCFProperty(rootDomain, "Last Sleep Reason" as CFString, kCFAllocatorDefault, 0) else { return nil }
        return v.takeRetainedValue() as? String
    }

    func startMonitoring() {
        guard notifyPort == nil else { return }
        notifyPort = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(notifyPort, .main)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        IOServiceAddInterestNotification(notifyPort, rootDomain, kIOGeneralInterest, { refcon, _, _, _ in
            guard let refcon else { return }
            let me = Unmanaged<PowerManager>.fromOpaque(refcon).takeUnretainedValue()
            me.onLidStateNotification?()
            // The root domain also resets the lid-sleep flag on its own around sleep/wake
            // and display changes; the coordinator re-applies it when it is actually gone.
            me.onReapplyNeeded?("root-domain notification")
        }, selfPtr, &interestNotification)

        powerSourceRunLoopSource = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            Unmanaged<PowerManager>.fromOpaque(ctx).takeUnretainedValue().onReapplyNeeded?("power-source change")
        }, selfPtr)?.takeRetainedValue()
        if let src = powerSourceRunLoopSource { CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode) }

        let ws = NSWorkspace.shared.notificationCenter
        let pairs: [(Notification.Name, String)] = [
            (NSWorkspace.screensDidSleepNotification, "display sleep"),
            (NSWorkspace.screensDidWakeNotification, "display wake"),
            (NSWorkspace.didWakeNotification, "system wake"),
        ]
        observers = pairs.map { name, reason in
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.onReapplyNeeded?(reason) }
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.onReapplyNeeded?("screen parameters change")
        })
    }

    func stopMonitoring() {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0); NotificationCenter.default.removeObserver($0) }
        observers = []
        if let src = powerSourceRunLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .defaultMode); powerSourceRunLoopSource = nil }
        if interestNotification != 0 { IOObjectRelease(interestNotification); interestNotification = 0 }
        if let p = notifyPort { IONotificationPortDestroy(p); notifyPort = nil }
    }
}
