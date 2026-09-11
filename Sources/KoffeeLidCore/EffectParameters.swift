import Foundation

/// Tunables for the lid-close effect. The geometry is fixed ("inner screen": the desktop stands
/// upright behind the folding display, anchored at the hinge; the display crops it and blurs
/// toward the top where it is furthest from it). `zoomStrength` scales how much of the true
/// 1 / cos(fold) magnification is applied; `perspectiveStrength` narrows the inner screen toward the
/// top (| | → / \) so it reads as receding behind the glass. `edgeSoftness` melts the inner screen's
/// edges into the void the further they are from the hinge and `shading` darkens it the same way
/// (the look of Apple's foldable: a hard edge commits to one viewing angle, a soft one forgives all).
///
/// Two start angles: `gestureStartBelowDegrees` is where the inner screen stands (the fold is
/// `that − lid angle`, so a lid-gesture fold shows from there); `startBelowDegrees` is the extra gate
/// for every other arm. The gesture one is never lower than the other (`clamped()` raises it).
public struct EffectParameters: Codable, Equatable {
    public var enabled: Bool
    public var zoomStrength: Double        // 0 ... 2 — share of the true magnification (1 = exact geometry, 2 = squared)
    public var perspectiveStrength: Double // 0 ... 2 — how much the top narrows toward the centre column (1 = matches the zoom's 1/cos)
    public var blurStrength: Double        // 0 ... 2.0 — 0 switches the blur off
    public var edgeSoftness: Double        // 0 ... 2 — width of the melt at the sides and the top (0 = crisp cut)
    public var shading: Double             // 0 ... 2 — darkening toward the top with the fold (0 = none)
    public var responsiveness: Double      // 0 ... 1 — AngleSmoother.tuning: 0 waits for each sensor report, 1 predicts ahead
    public var startBelowDegrees: Double   // 30 ... 90 — absolute gate for arms other than the lid gesture
    public var gestureStartBelowDegrees: Double // startBelowDegrees ... 120 — the upright angle of the inner screen (FoldGeometry)
    public var settleDelay: Double         // 0.25 ... 10 s — stillness while folded before easing back flat
    public var showAngleInMenuBar: Bool

    public static let userDefaultsKey = "effectParameters"
    public static let gestureStartCeiling: Double = 120

    public static let `default` = EffectParameters(
        enabled: true, zoomStrength: 0.8, perspectiveStrength: 0.4, blurStrength: 0.15, edgeSoftness: 1, shading: 1, responsiveness: 0.7,
        startBelowDegrees: 75, gestureStartBelowDegrees: 95, settleDelay: 0.5, showAngleInMenuBar: false)

    public init(enabled: Bool, zoomStrength: Double, perspectiveStrength: Double, blurStrength: Double, edgeSoftness: Double = 1, shading: Double = 1,
                responsiveness: Double, startBelowDegrees: Double, gestureStartBelowDegrees: Double = 95, settleDelay: Double, showAngleInMenuBar: Bool) {
        self.enabled = enabled; self.zoomStrength = zoomStrength; self.perspectiveStrength = perspectiveStrength
        self.blurStrength = blurStrength; self.edgeSoftness = edgeSoftness; self.shading = shading; self.responsiveness = responsiveness
        self.startBelowDegrees = startBelowDegrees; self.gestureStartBelowDegrees = gestureStartBelowDegrees
        self.settleDelay = settleDelay; self.showAngleInMenuBar = showAngleInMenuBar
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, zoomStrength, perspectiveStrength, blurStrength, edgeSoftness, shading, responsiveness, startBelowDegrees, gestureStartBelowDegrees, settleDelay, showAngleInMenuBar
    }

    /// Keys added after v0.0.1 are optional so stored settings keep decoding; the ones from the first
    /// geometry are required so older shapes fall back to `default` (see `EffectParametersTests`).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        zoomStrength = try c.decode(Double.self, forKey: .zoomStrength)
        perspectiveStrength = try c.decode(Double.self, forKey: .perspectiveStrength)
        blurStrength = try c.decode(Double.self, forKey: .blurStrength)
        edgeSoftness = try c.decodeIfPresent(Double.self, forKey: .edgeSoftness) ?? Self.default.edgeSoftness
        shading = try c.decodeIfPresent(Double.self, forKey: .shading) ?? Self.default.shading
        responsiveness = try c.decode(Double.self, forKey: .responsiveness)
        startBelowDegrees = try c.decode(Double.self, forKey: .startBelowDegrees)
        gestureStartBelowDegrees = try c.decodeIfPresent(Double.self, forKey: .gestureStartBelowDegrees) ?? Self.default.gestureStartBelowDegrees
        settleDelay = try c.decode(Double.self, forKey: .settleDelay)
        showAngleInMenuBar = try c.decode(Bool.self, forKey: .showAngleInMenuBar)
    }

    public func clamped() -> EffectParameters {
        var c = self
        c.zoomStrength = min(2.0, max(0, zoomStrength))
        c.perspectiveStrength = min(2.0, max(0, perspectiveStrength))
        c.blurStrength = min(2.0, max(0, blurStrength))
        c.edgeSoftness = min(2.0, max(0, edgeSoftness))
        c.shading = min(2.0, max(0, shading))
        c.responsiveness = min(1.0, max(0, responsiveness))
        c.startBelowDegrees = min(90, max(30, startBelowDegrees))
        c.gestureStartBelowDegrees = min(Self.gestureStartCeiling, max(c.startBelowDegrees, gestureStartBelowDegrees))
        c.settleDelay = min(10, max(0.25, settleDelay))
        return c
    }
}
