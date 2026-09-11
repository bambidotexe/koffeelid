/// Drops implausible lid-angle samples: out of range, or a single-sample jump.
/// Two consecutive samples that agree with each other are always accepted.
public struct AngleSampleFilter {
    public var validRange: ClosedRange<Double>
    public var maxJumpPerSample: Double
    private var last: Double?
    private var pendingOutlier: Double?

    public init(validRange: ClosedRange<Double> = 0...180, maxJumpPerSample: Double = 40) {
        self.validRange = validRange; self.maxJumpPerSample = maxJumpPerSample
    }

    public mutating func accept(_ degrees: Double) -> Double? {
        guard validRange.contains(degrees) else { return nil }
        guard let last else { self.last = degrees; return degrees }
        if abs(degrees - last) <= maxJumpPerSample {
            pendingOutlier = nil; self.last = degrees; return degrees
        }
        if let p = pendingOutlier, abs(degrees - p) <= maxJumpPerSample {
            pendingOutlier = nil; self.last = degrees; return degrees
        }
        pendingOutlier = degrees
        return nil
    }

    public mutating func reset() { last = nil; pendingOutlier = nil }
}
