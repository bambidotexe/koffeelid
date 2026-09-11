import Foundation

/// After an Option + close gesture has armed but before the lid is fully closed, the user can
/// change their mind in two ways: reopen the lid by `cancelDegrees` from the lowest angle
/// reached, or simply stop moving for `stallSeconds` (the effect eases back flat then; the
/// arm must go with it). While the gesture modifier is still held (`held`) the user is plainly
/// still in the gesture: standing still does not count, and the stall clock restarts on release.
public struct ReopenCancelWatch: Equatable {
    public enum Verdict: Equatable { case reopened, stalled }

    public private(set) var minAngle: Double
    public var stillnessDegrees: Double = 1.5     // integer sensor flicker (89, 90, 89…) is not movement
    private var motionAngle: Double
    private var lastMovement: TimeInterval

    public init(angle: Double, now: TimeInterval) { minAngle = angle; motionAngle = angle; lastMovement = now }

    public mutating func update(angle: Double, now: TimeInterval, cancelDegrees: Double, stallSeconds: TimeInterval, held: Bool = false) -> Verdict? {
        if held || abs(angle - motionAngle) >= stillnessDegrees { motionAngle = angle; lastMovement = now }
        if angle < minAngle { minAngle = angle }
        else if angle - minAngle >= cancelDegrees { return .reopened }
        if now - lastMovement >= stallSeconds { return .stalled }
        return nil
    }
}
