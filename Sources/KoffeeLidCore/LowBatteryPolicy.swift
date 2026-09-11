public struct LowBatteryPolicy {
    public var enabled: Bool
    public var thresholdPercent: Int
    public init(enabled: Bool, thresholdPercent: Int) { self.enabled = enabled; self.thresholdPercent = thresholdPercent }

    /// nil state means macOS stopped reporting charge; the safety disarms so the Mac can sleep.
    public func shouldDisarm(_ state: BatteryState?) -> Bool {
        guard enabled else { return false }
        guard let s = state else { return true }
        return s.onBattery && s.percent <= thresholdPercent
    }
}
