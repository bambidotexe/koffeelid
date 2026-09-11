import Foundation

/// The two things that can be running: Claude Code sessions and terminal (zsh) commands.
public enum ActivityKind: String, CaseIterable, Sendable, Codable, Comparable {
    case claude, terminal
    public static func < (a: ActivityKind, b: ActivityKind) -> Bool { a.rawValue < b.rawValue }
}

/// What the auto level just did, for the coordinator.
public enum ActivityArmChange: Equatable {
    /// Work started: arm if the manual mode is Off (a manual arm already covers it).
    case on
    /// The hold-off ran out (or the feature went off / a rail hit): disarm unless the manual mode holds the
    /// arm. `releaseManual` is "Disarm once finished" firing: the manual mode goes Off too.
    case off(releaseManual: Bool)
}

/// The auto-arm as a level of its own, independent of the manual mode (the coordinator ORs the two): on
/// from the moment work runs, off after a hold-off once nothing does. The hold-off is the longest one among
/// the kinds that ran during the stretch (`holdOffs`; a Claude Code turn is followed by a long one, since
/// its user is usually remote and about to prompt again; a command by a short one). `requestDisarmOnce`
/// is the user's "Disarm once finished": the current or next stretch ends `onceHoldOff` after the work,
/// and the manual arm is released with it. A refused arm (`armFailed`) or a rail (`suspend`) keeps the
/// level off until the running work stops and something starts again.
public struct ActivityArmPolicy: Equatable {
    /// A change moves a pending drop too (the Advanced slider dragged during the countdown).
    public var holdOffs: [ActivityKind: TimeInterval] = ActivityConstants.holdOffDefaults {
        didSet { if isOn, let idleSince { offAt = idleSince.addingTimeInterval(currentHoldOff) } }
    }
    public var onceHoldOff: TimeInterval = ActivityConstants.disarmOnceHoldOffSeconds
    /// The auto level.
    public private(set) var isOn = false
    /// Which kinds were running at the last `update`.
    public private(set) var running: Set<ActivityKind> = []
    /// Every kind that ran during the current stretch: picks the hold-off.
    public private(set) var involved: Set<ActivityKind> = []
    /// "Disarm once finished" is pending.
    public private(set) var disarmOnce = false
    /// When the hold-off ends (only while on and idle).
    public private(set) var offAt: Date?
    /// When the work stopped (only while on and idle): local input after this moment ends the hold-off.
    public private(set) var idleSince: Date?
    /// Off until the running work stops: a refused arm or a rail must not retry on every tick.
    private var suppressed = false

    public init() {}
    public init(holdOffs: [ActivityKind: TimeInterval]) { self.holdOffs = holdOffs }

    /// The hold-off that applies to the current stretch once idle.
    public var currentHoldOff: TimeInterval {
        if disarmOnce { return onceHoldOff }
        return involved.compactMap { holdOffs[$0] }.max() ?? onceHoldOff
    }

    public mutating func update(running new: Set<ActivityKind>, enabled: Bool, now: Date) -> ActivityArmChange? {
        defer { running = new }
        guard enabled else { return isOn ? dropNow(releaseManual: false) : nil }
        if !new.isEmpty {
            offAt = nil; idleSince = nil
            if isOn { involved.formUnion(new); return nil }
            if suppressed { return nil }
            isOn = true; involved = new
            return .on
        }
        suppressed = false                                  // the work stopped: the next start may arm again
        if isOn, idleSince == nil {
            idleSince = now; involved.formUnion(running)
            offAt = now.addingTimeInterval(currentHoldOff)
        }
        return nil
    }

    /// "Disarm once finished": on, the current idle stretch (or the next one) ends `onceHoldOff` after the
    /// work — already idle for longer than that, the caller's next `tick` fires at once; off, the stretch
    /// goes back to its full hold-off.
    public mutating func requestDisarmOnce(_ on: Bool) {
        disarmOnce = on
        if isOn, let idleSince { offAt = idleSince.addingTimeInterval(currentHoldOff) }
    }

    /// The coordinator refused the arm (battery, thermal, disabled, flag): wait for the work to stop and restart.
    public mutating func armFailed() { isOn = false; involved = []; offAt = nil; idleSince = nil; suppressed = !running.isEmpty }

    /// A rail (low battery, thermal, external sleep), a reset or a quit ended every arm: same wait, and a
    /// pending "Disarm once finished" is spent.
    public mutating func suspend() { armFailed(); disarmOnce = false }

    /// Local keyboard or mouse input during the hold-off: the user is at the Mac and responsible for arming
    /// it, so the level drops at once (the hold-off exists for a remote user whose connection would die).
    public mutating func userActive(now: Date) -> ActivityArmChange? {
        guard isOn, offAt != nil, running.isEmpty else { return nil }
        return dropNow(releaseManual: disarmOnce)
    }

    public mutating func tick(now: Date) -> ActivityArmChange? {
        guard isOn, let due = offAt, now >= due, running.isEmpty else { return nil }
        return dropNow(releaseManual: disarmOnce)
    }

    private mutating func dropNow(releaseManual: Bool) -> ActivityArmChange {
        isOn = false; involved = []; offAt = nil; idleSince = nil; disarmOnce = false
        return .off(releaseManual: releaseManual)
    }

    public func nextDeadline(after now: Date) -> Date? { offAt.flatMap { $0 > now ? $0 : nil } }
}
