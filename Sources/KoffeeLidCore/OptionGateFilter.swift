import Foundation

/// Debounces the Option modifier for the Option + close gesture.
public struct OptionGateFilter {
    public var holdSamples: Int
    public var staleClearSamples: Int
    public var maxHoldSeconds: Double
    public private(set) var trusted = false
    private var downRun = 0
    private var upRun = 0
    private var pressStart: TimeInterval?
    private var expired = false

    public init(holdSamples: Int = 2, staleClearSamples: Int = 3, maxHoldSeconds: Double = 20) {
        self.holdSamples = holdSamples; self.staleClearSamples = staleClearSamples; self.maxHoldSeconds = maxHoldSeconds
    }

    public mutating func feed(optionDown: Bool, now: TimeInterval) -> Bool {
        if optionDown {
            upRun = 0; downRun += 1
            if pressStart == nil { pressStart = now }
            if let s = pressStart, now - s > maxHoldSeconds { expired = true }
            if expired { trusted = false } else if downRun >= holdSamples { trusted = true }
        } else {
            downRun = 0; upRun += 1
            pressStart = nil; expired = false
            if upRun >= staleClearSamples { trusted = false }
        }
        return trusted
    }
}
