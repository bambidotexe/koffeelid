import Foundation

/// Maps the lid angle to the fold the plane shows.
///
/// The inner screen stands upright at `uprightAngle` (90° to the keyboard), so the display is folded
/// over it by `uprightAngle − lid angle`: 1:1 with the hinge, nothing above 90°. A fold that has to begin
/// below the upright angle (the start-below gate of a menu arm, a settle-back rebase, a gesture made with
/// the lid already under 90°) cannot jump to that value: it starts flat at `zeroAngle` and catches up
/// with the 1:1 curve over at most `catchUpDegrees` of closing travel, moving faster than the lid at
/// first (quadratic ease-out) and exactly with it once caught up.
public struct FoldGeometry: Equatable {
    public var uprightAngle: Double
    public var catchUpDegrees: Double

    public init(uprightAngle: Double = 90, catchUpDegrees: Double = 30) {
        self.uprightAngle = uprightAngle; self.catchUpDegrees = catchUpDegrees
    }

    /// Fold in degrees for the lid at `angle` when the fold is zero at `zeroAngle` (`FoldTracker.zeroAngle`).
    public func fold(angle: Double, zeroAngle: Double) -> Double {
        let start = min(zeroAngle, uprightAngle)
        guard angle < start else { return 0 }
        let ideal = uprightAngle - angle
        let gap = uprightAngle - start
        guard gap > 0 else { return ideal }
        let travel = min(gap, max(0.01, catchUpDegrees))
        let p = min(1, (start - angle) / travel)
        let eased = 1 - (1 - p) * (1 - p)
        return ideal * eased
    }
}
