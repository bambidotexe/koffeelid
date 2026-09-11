import Foundation
import simd

/// CPU twin of the fragment shader's geometry. Keep `PlaneShader.source` in sync with this file.
///
/// "Inner screen": the desktop is a screen that stands upright at the hinge and never moves; the
/// real display is a sheet of glass folding over it by the angle `a`. Seen from the front, a
/// display row at height `h` (0 = hinge, 1 = top) sits at height `h·cos a`, so it shows the desktop
/// at that height: the desktop stays anchored at the hinge, is magnified by `1 / cos a` and its top
/// is cropped away above the display's edge. `zoom` (0…2) applies that share of the magnification
/// as an exponent, `1` being the true geometry and `2` its square.
///
/// Perspective: the further a row is from the hinge, the further the inner screen is behind the
/// glass, so it narrows toward the top — `| |` becomes `/ \`, with the void showing beside it. The
/// top row is `1 + 2·(1 − cos a)·perspective` times narrower (the same as `1 / cos a − 1` for small
/// folds, twice gentler at 80° and capped at `1 + 2·perspective` instead of exploding toward 90°,
/// which pinched the top into a spike at the end of the fold) and the visible half-width is linear
/// in `h` between the hinge and that top width, so the two edges are straight lines (a keystone),
/// not the hyperbola a linear sampling factor would draw.
/// The gap between the glass and the inner screen is `h·sin a`, so the blur grows linearly toward
/// the top and with the fold.
///
/// Soft edges and shading (the look of Apple's foldable, tuned against its frames): the inner screen
/// never ends on a hard line away from the hinge. Each keystone side melts into the void over a band
/// `sideFeather` wide (display widths, `0.35·softness·gap`, so crisp at the hinge and widest at the top
/// corners), the top row over a narrower `topFeather` (`0.08·softness·sin a` display heights), and the
/// whole picture darkens by `shade` (`1 − 0.55·strength·gap`), so the far corners go black where the
/// side melt meets the shading.
public enum PlaneRemap {
    /// How much bigger the desktop appears on the display: `cos(a)^-zoom`.
    public static func magnification(angleRadians a: Float, zoom: Float) -> Float {
        pow(max(cos(a), 1e-4), -zoom)
    }

    /// How many times narrower the inner screen is at the top row of the display (≥ 1).
    public static func topNarrowing(angleRadians a: Float, perspective: Float) -> Float {
        1 + 2 * (1 - cos(a)) * perspective
    }

    /// Horizontal sampling factor about the centre column at display height `h` (≥ 1): the
    /// reciprocal of a half-width that shrinks linearly from 1 at the hinge to `1 / topNarrowing` at the top.
    public static func narrowing(heightFromHinge h: Float, angleRadians a: Float, perspective: Float) -> Float {
        1 / (1 - h * (1 - 1 / topNarrowing(angleRadians: a, perspective: perspective)))
    }

    /// Source uv for a display uv (both y-down, 0…1); nil beside the inner screen (void).
    public static func remap(uv: SIMD2<Float>, angleRadians a: Float, zoom: Float, perspective: Float) -> SIMD2<Float>? {
        let h = 1 - uv.y
        let c = min(1, h / magnification(angleRadians: a, zoom: zoom))   // desktop height from hinge
        let x = 0.5 + (uv.x - 0.5) * narrowing(heightFromHinge: h, angleRadians: a, perspective: perspective)
        guard x >= 0, x <= 1 else { return nil }
        return SIMD2(x, 1 - c)
    }

    /// Half of the inner screen's visible width at display height `h`, in display widths (0.5 at the hinge).
    public static func halfWidth(heightFromHinge h: Float, angleRadians a: Float, perspective: Float) -> Float {
        0.5 / narrowing(heightFromHinge: h, angleRadians: a, perspective: perspective)
    }

    /// Width of the band over which a keystone side melts into the void, in display widths.
    public static func sideFeather(heightFromHinge h: Float, angleRadians a: Float, softness: Float) -> Float {
        0.35 * softness * h * abs(sin(a))
    }

    /// Height of the band under the top row over which the picture melts into the void, in display heights.
    public static func topFeather(angleRadians a: Float, softness: Float) -> Float {
        0.08 * softness * abs(sin(a))
    }

    /// Brightness factor at display height `h`: 1 at the hinge and when flat, darker toward the top with the fold.
    public static func shade(heightFromHinge h: Float, angleRadians a: Float, strength: Float) -> Float {
        max(0, 1 - 0.55 * strength * h * abs(sin(a)))
    }

    /// How much of the inner screen shows at a display uv (y-down): 1 inside, 0 in the void, in between
    /// across the side and top melts. With `softness` 0 the sides are a crisp cut.
    public static func coverage(uv: SIMD2<Float>, angleRadians a: Float, perspective: Float, softness: Float) -> Float {
        let h = 1 - uv.y
        let dSide = halfWidth(heightFromHinge: h, angleRadians: a, perspective: perspective) - abs(uv.x - 0.5)
        let side = smoothstep(0, sideFeather(heightFromHinge: h, angleRadians: a, softness: softness), dSide)
        let top = smoothstep(0, topFeather(angleRadians: a, softness: softness), 1 - h)
        return side * top
    }

    /// GLSL/MSL `smoothstep`, except that a zero-width edge is a step (1 at and above `e0`).
    static func smoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
        guard e1 > e0 else { return x >= e0 ? 1 : 0 }
        let t = min(1, max(0, (x - e0) / (e1 - e0)))
        return t * t * (3 - 2 * t)
    }

    /// Blur radius in source pixels (at 1000 px reference height), matching the shader.
    public static func blurRadius(heightFromHinge h: Float, angleRadians a: Float, strength: Float) -> Float {
        strength * h * abs(sin(a)) * 65
    }
}
