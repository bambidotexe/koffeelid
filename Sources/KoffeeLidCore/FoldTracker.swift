import Foundation

/// Decides how far the desktop plane is folded from a stream of lid angles.
///
/// Closing only: the rest angle follows the lid whenever it opens, so opening never produces
/// a fold. Once the lid has closed `thresholdDegrees` past the rest angle the fold grows with
/// every further degree, and shrinks back to zero when the lid is reopened to that same point.
/// A lid left part-way closed eases back to flat after `settleDelay` of stillness, after which
/// its current position is the new rest angle — unless the gesture modifier is held (`holding`):
/// then stillness does not count and a settle in progress stops where it is.
///
/// With `startBelowAngle` set (arms that did not come from the Option + close gesture) the fold
/// additionally waits until the lid is below that absolute angle and grows from there, so small
/// adjustments while working at 100–120° never start it.
public struct FoldTracker {
    public enum Change: Equatable { case foldBegan, foldEnded }

    public var thresholdDegrees: Double
    public var settleDelay: TimeInterval
    public var startBelowAngle: Double?
    public var settleDuration: TimeInterval = 0.6
    /// The sensor reports whole degrees and can flicker between two neighbours indefinitely (89, 90, 89…);
    /// anything under this is not movement.
    public var stillnessDegrees: Double = 1.5
    public private(set) var restAngle: Double
    public private(set) var foldDegrees: Double = 0
    public var isFolding: Bool { foldDegrees > 0 }

    private var motionAngle: Double
    private var lastMovement: TimeInterval
    private var settlingSince: TimeInterval?
    private var settlingFrom: Double = 0

    public init(angle: Double, now: TimeInterval, thresholdDegrees: Double = 6, settleDelay: TimeInterval = 3, startBelowAngle: Double? = nil) {
        restAngle = angle; motionAngle = angle; lastMovement = now
        self.thresholdDegrees = thresholdDegrees; self.settleDelay = settleDelay; self.startBelowAngle = startBelowAngle
    }

    /// The angle at which the fold is zero: rest minus threshold, capped by the absolute gate.
    public var zeroAngle: Double { min(restAngle - thresholdDegrees, startBelowAngle ?? .infinity) }

    /// Rebase to the current lid position: no fold, nothing pending.
    public mutating func rebase(angle: Double, now: TimeInterval) {
        restAngle = angle; motionAngle = angle; lastMovement = now; settlingSince = nil; foldDegrees = 0
    }

    @discardableResult
    public mutating func update(angle: Double, now: TimeInterval, holding: Bool = false) -> Change? {
        let wasFolding = isFolding
        if holding || abs(angle - motionAngle) >= stillnessDegrees {
            motionAngle = angle; lastMovement = now; settlingSince = nil
        }
        if angle >= restAngle {
            restAngle = angle; settlingSince = nil
        } else if angle < zeroAngle, now - lastMovement >= settleDelay {
            // still while folded: ease the rest angle down so the plane returns to flat
            let target = angle + thresholdDegrees
            if settlingSince == nil { settlingSince = now; settlingFrom = restAngle }
            let t = min(1, max(0, (now - settlingSince!) / max(0.01, settleDuration)))
            let eased = t * t * (3 - 2 * t)
            restAngle = settlingFrom + (target - settlingFrom) * eased
            if t >= 1 { settlingSince = nil }
        }
        foldDegrees = max(0, zeroAngle - angle)
        if isFolding != wasFolding { return isFolding ? .foldBegan : .foldEnded }
        return nil
    }
}
