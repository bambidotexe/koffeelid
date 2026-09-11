import Foundation

public struct DisplayTopology: Equatable {
    public var builtInCount: Int
    public var externalCount: Int
    /// false when the display list could not be read; arming must refuse.
    public var verified: Bool
    public init(builtInCount: Int, externalCount: Int, verified: Bool) {
        self.builtInCount = builtInCount; self.externalCount = externalCount; self.verified = verified
    }
    /// While an external display is connected macOS runs its own closed-lid mode: darkening, the lid
    /// sound, the lid effect and the lock on reopen stand by. The kernel flag stays set so the arm
    /// takes over the instant the display goes away.
    public var standsBy: Bool { externalCount > 0 }
}

public enum ThermalLevel: Int, Comparable {
    case nominal, fair, serious, critical
    public static func < (a: ThermalLevel, b: ThermalLevel) -> Bool { a.rawValue < b.rawValue }
}

public struct BatteryState: Equatable {
    public var percent: Int
    public var onBattery: Bool
    public init(percent: Int, onBattery: Bool) { self.percent = percent; self.onBattery = onBattery }
}

public enum ArmBlockReason: Equatable {
    case displayUnverified
    case thermal(ThermalLevel)
    case batteryLow(Int)
    case disabled
    case flagSetFailed
}

public enum ArmDecision: Equatable {
    case allowed
    case blocked(ArmBlockReason)
}

/// Decides whether KoffeeLid may arm right now. Order: display verification, thermal, battery.
/// An external display does not block: the mode is allowed and the built-in-screen behaviours are
/// suspended instead (see `DisplayTopology.standsBy`).
public struct ArmingPolicy {
    public var lowBatteryDisarmEnabled: Bool
    public var lowBatteryPercent: Int

    public init(lowBatteryDisarmEnabled: Bool, lowBatteryPercent: Int) {
        self.lowBatteryDisarmEnabled = lowBatteryDisarmEnabled
        self.lowBatteryPercent = lowBatteryPercent
    }

    public func evaluate(displays: DisplayTopology, thermal: ThermalLevel, battery: BatteryState?) -> ArmDecision {
        guard displays.verified else { return .blocked(.displayUnverified) }
        if thermal >= .serious { return .blocked(.thermal(thermal)) }
        if lowBatteryDisarmEnabled, let b = battery, b.onBattery, b.percent <= lowBatteryPercent {
            return .blocked(.batteryLow(b.percent))
        }
        return .allowed
    }
}
