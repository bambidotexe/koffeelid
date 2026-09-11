import Foundation

public enum GestureCancelReason: Equatable { case optionLost, reversed, timeout }

public enum GestureEvent: Equatable {
    case started(angle: Double)
    case progress(Double)
    case armed(angle: Double, start: Double)
    case cancelled(GestureCancelReason)
}

/// Turns an angle stream plus a trusted Option state into a single arming decision.
///
/// A gesture starts wherever the lid happens to be when Option becomes trusted (the
/// app arms from 65° as well as from 130°), and survives Option being released for up to
/// `optionGraceSeconds` — fingers leave the key a fraction of a second before the lid has
/// travelled `activationDegrees`.
///
/// After `.armed` the driver is silent (`activated`) for as long as the modifier stays down, so one
/// hold produces one arm; it resets itself as soon as the modifier is released and is then ready for
/// the next gesture. (Before 2026-09-11 it stayed `activated` until someone called `reset()`, and the
/// "gesture while already armed" path never did — the detector was dead until the next arm.)
public struct LidProgressDriver {
    public var angleOpen: Double
    public var angleClosed: Double
    public var activationDegrees: Double
    public var reverseCancelDegrees: Double
    public var graceSeconds: Double
    public var optionGraceSeconds: Double
    public var autoCalibrateOpen: Bool
    public private(set) var activated = false

    private var startAngle: Double?
    private var minAngle: Double = .infinity
    private var lastProgressTime: TimeInterval = 0
    private var optionLostAt: TimeInterval?

    public init(angleOpen: Double = 120, angleClosed: Double = 5, activationDegrees: Double = 6,
                reverseCancelDegrees: Double = 4, graceSeconds: Double = 1.5, optionGraceSeconds: Double = 1.0,
                autoCalibrateOpen: Bool = true) {
        self.angleOpen = angleOpen; self.angleClosed = angleClosed; self.activationDegrees = activationDegrees
        self.reverseCancelDegrees = reverseCancelDegrees; self.graceSeconds = graceSeconds
        self.optionGraceSeconds = optionGraceSeconds; self.autoCalibrateOpen = autoCalibrateOpen
    }

    public mutating func reset() { activated = false; startAngle = nil; minAngle = .infinity; optionLostAt = nil }

    public mutating func feed(angle: Double, optionTrusted: Bool, now: TimeInterval) -> GestureEvent? {
        if autoCalibrateOpen, angle > angleOpen { angleOpen = min(180, angle) }
        if activated {
            if !optionTrusted { reset() }          // the hold is over: ready for the next gesture
            return nil
        }

        guard let start = startAngle else {
            guard optionTrusted, angle > angleClosed else { return nil }
            startAngle = angle; minAngle = angle; lastProgressTime = now; optionLostAt = nil
            return .started(angle: angle)
        }

        if optionTrusted { optionLostAt = nil }
        else if let lost = optionLostAt {
            if now - lost > optionGraceSeconds { reset(); return .cancelled(.optionLost) }
        } else { optionLostAt = now }

        if angle < minAngle { minAngle = angle; lastProgressTime = now }
        if angle - minAngle >= reverseCancelDegrees { reset(); return .cancelled(.reversed) }
        if now - lastProgressTime > graceSeconds {
            // Not moving. If the close never really began, quietly follow the lid so a long
            // Option hold still arms from wherever the lid is; a stalled partial close is cancelled.
            if start - minAngle < 1 {
                startAngle = angle; minAngle = angle; lastProgressTime = now
                return nil
            }
            reset(); return .cancelled(.timeout)
        }

        let travelled = start - angle
        if travelled >= activationDegrees { activated = true; return .armed(angle: angle, start: start) }
        let span = max(1, start - angleClosed)
        return .progress(min(1, max(0, travelled / span)))
    }
}
