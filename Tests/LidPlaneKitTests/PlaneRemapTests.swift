import XCTest
import KoffeeLidCore
@testable import LidPlaneKit

final class PlaneRemapTests: XCTestCase {
    func testZeroAngleIsIdentity() {
        let uv = SIMD2<Float>(0.3, 0.2)
        let out = PlaneRemap.remap(uv: uv, angleRadians: 0, zoom: 1, perspective: 1)!
        XCTAssertEqual(out.x, uv.x, accuracy: 1e-5); XCTAssertEqual(out.y, uv.y, accuracy: 1e-5)
    }
    func testHingeRowNeverMoves() {
        let out = PlaneRemap.remap(uv: SIMD2(0.7, 1.0), angleRadians: 0.5, zoom: 1, perspective: 1)!
        XCTAssertEqual(out.y, 1.0, accuracy: 1e-5); XCTAssertEqual(out.x, 0.7, accuracy: 1e-5)
    }
    func testRowShowsDesktopAtItsFrontViewHeight() {
        // A display row at height h sits at h·cos a when seen from the front: it shows the desktop there.
        let a: Float = 0.5
        let out = PlaneRemap.remap(uv: SIMD2(0.5, 0.6), angleRadians: a, zoom: 1, perspective: 1)!
        XCTAssertEqual(1 - out.y, 0.4 * cos(a), accuracy: 1e-5)
    }
    func testTopOfDesktopIsCroppedNotCompressed() {
        // The display's top row shows the desktop at cos a: everything above is off the glass.
        let a: Float = 60 * .pi / 180
        let top = PlaneRemap.remap(uv: SIMD2(0.5, 0.0), angleRadians: a, zoom: 1, perspective: 1)!
        XCTAssertEqual(1 - top.y, 0.5, accuracy: 1e-5)
        XCTAssertEqual(PlaneRemap.magnification(angleRadians: a, zoom: 1), 2, accuracy: 1e-5)
    }
    func testColumnsNeverMoveWithoutPerspective() {
        for y: Float in [0, 0.3, 0.9] {
            XCTAssertEqual(PlaneRemap.remap(uv: SIMD2(0.9, y), angleRadians: 1.2, zoom: 1, perspective: 0)!.x, 0.9, accuracy: 1e-6)
        }
    }
    func testPerspectiveNarrowsTheTopTowardTheCentre() {
        let a: Float = 60 * .pi / 180                               // 2·(1 − cos) = 1
        XCTAssertEqual(PlaneRemap.narrowing(heightFromHinge: 1, angleRadians: a, perspective: 1), 2, accuracy: 1e-5)
        XCTAssertEqual(PlaneRemap.narrowing(heightFromHinge: 1, angleRadians: a, perspective: 0.5), 1.5, accuracy: 1e-5)
        XCTAssertEqual(PlaneRemap.narrowing(heightFromHinge: 1, angleRadians: a, perspective: 2), 3, accuracy: 1e-5)
        XCTAssertEqual(PlaneRemap.narrowing(heightFromHinge: 0, angleRadians: a, perspective: 1), 1, accuracy: 1e-6)
        XCTAssertEqual(PlaneRemap.narrowing(heightFromHinge: 0.5, angleRadians: a, perspective: 1), 4.0 / 3.0, accuracy: 1e-5)   // not 1.5: edges are straight
        let top = PlaneRemap.remap(uv: SIMD2(0.7, 0.0), angleRadians: a, zoom: 1, perspective: 1)!
        XCTAssertEqual(top.x, 0.9, accuracy: 1e-5)                  // samples further out: content looks narrower
        XCTAssertNil(PlaneRemap.remap(uv: SIMD2(0.9, 0.0), angleRadians: a, zoom: 1, perspective: 1))   // void beside it
        XCTAssertEqual(PlaneRemap.remap(uv: SIMD2(0.7, 1.0), angleRadians: a, zoom: 1, perspective: 1)!.x, 0.7, accuracy: 1e-5)
        XCTAssertEqual(PlaneRemap.remap(uv: SIMD2(0.5, 0.0), angleRadians: a, zoom: 1, perspective: 1)!.x, 0.5, accuracy: 1e-6)
    }
    func testZoomScalesTheMagnification() {
        let a: Float = 60 * .pi / 180
        XCTAssertEqual(PlaneRemap.magnification(angleRadians: a, zoom: 0), 1, accuracy: 1e-6)
        XCTAssertEqual(PlaneRemap.magnification(angleRadians: a, zoom: 0.5), sqrt(2), accuracy: 1e-5)
        XCTAssertEqual(PlaneRemap.magnification(angleRadians: a, zoom: 2), 4, accuracy: 1e-5)
        let flat = PlaneRemap.remap(uv: SIMD2(0.2, 0.4), angleRadians: a, zoom: 0, perspective: 0)!
        XCTAssertEqual(flat.y, 0.4, accuracy: 1e-6)                 // zoom 0: only the blur remains
    }
    func testTopNarrowingSaturatesInsteadOfExploding() {
        XCTAssertEqual(PlaneRemap.topNarrowing(angleRadians: 80 * .pi / 180, perspective: 1), 1 + 2 * (1 - cos(80 * Float.pi / 180)), accuracy: 1e-5)   // 2.65, not 5.76
        XCTAssertEqual(PlaneRemap.topNarrowing(angleRadians: .pi / 2, perspective: 1), 3, accuracy: 1e-5)
        XCTAssertEqual(PlaneRemap.topNarrowing(angleRadians: 0, perspective: 2), 1, accuracy: 1e-6)
    }
    func testEdgesAreStraightLines() {
        // Visible half-width = 0.5 / narrowing; a keystone has it linear in h.
        let a: Float = 70 * .pi / 180
        let w: (Float) -> Float = { 0.5 / PlaneRemap.narrowing(heightFromHinge: $0, angleRadians: a, perspective: 1.3) }
        XCTAssertEqual(w(0.5), (w(0) + w(1)) / 2, accuracy: 1e-5)
        XCTAssertEqual(w(0.25), w(0) + (w(1) - w(0)) * 0.25, accuracy: 1e-5)
    }
    func testCentreColumnIsAlwaysOnTheDesktopEvenNearlyShut() {
        let out = PlaneRemap.remap(uv: SIMD2(0.5, 0.0), angleRadians: 89 * .pi / 180, zoom: 1, perspective: 1)!
        XCTAssertGreaterThanOrEqual(out.y, 0); XCTAssertLessThanOrEqual(out.y, 1)
    }
    // MARK: soft edges and shading (the Apple foldable look)

    func testSideFeatherGrowsWithTheGap() {
        // Width of the band over which each keystone side melts into the void, in display widths.
        XCTAssertEqual(PlaneRemap.sideFeather(heightFromHinge: 0, angleRadians: 1, softness: 1), 0)          // crisp at the hinge
        XCTAssertEqual(PlaneRemap.sideFeather(heightFromHinge: 1, angleRadians: 0, softness: 1), 0)          // nothing when flat
        XCTAssertEqual(PlaneRemap.sideFeather(heightFromHinge: 1, angleRadians: .pi / 2, softness: 1), 0.35, accuracy: 1e-5)
        XCTAssertEqual(PlaneRemap.sideFeather(heightFromHinge: 0.5, angleRadians: .pi / 2, softness: 1), 0.175, accuracy: 1e-5)
        XCTAssertEqual(PlaneRemap.sideFeather(heightFromHinge: 1, angleRadians: .pi / 2, softness: 2), 0.7, accuracy: 1e-5)
        XCTAssertEqual(PlaneRemap.sideFeather(heightFromHinge: 1, angleRadians: .pi / 2, softness: 0), 0)
    }
    func testTopFeatherIsNarrowAndFollowsTheFoldOnly() {
        XCTAssertEqual(PlaneRemap.topFeather(angleRadians: 0, softness: 1), 0)
        XCTAssertEqual(PlaneRemap.topFeather(angleRadians: .pi / 2, softness: 1), 0.08, accuracy: 1e-5)
        XCTAssertEqual(PlaneRemap.topFeather(angleRadians: .pi / 6, softness: 2), 0.08, accuracy: 1e-5)
    }
    func testShadeDarkensWithTheGap() {
        XCTAssertEqual(PlaneRemap.shade(heightFromHinge: 0, angleRadians: 1, strength: 1), 1)
        XCTAssertEqual(PlaneRemap.shade(heightFromHinge: 1, angleRadians: 0, strength: 1), 1)
        XCTAssertEqual(PlaneRemap.shade(heightFromHinge: 1, angleRadians: .pi / 2, strength: 1), 0.45, accuracy: 1e-5)
        XCTAssertEqual(PlaneRemap.shade(heightFromHinge: 1, angleRadians: .pi / 2, strength: 2), 0, accuracy: 1e-5)   // never negative
        XCTAssertEqual(PlaneRemap.shade(heightFromHinge: 1, angleRadians: .pi / 2, strength: 0), 1)
    }
    func testCoverageIsFullInsideAndZeroInTheVoid() {
        let a: Float = 60 * .pi / 180                                // top row is 1.5× narrower at perspective 0.5: half-width 1/3
        XCTAssertEqual(PlaneRemap.coverage(uv: SIMD2(0.5, 0.5), angleRadians: a, perspective: 0.5, softness: 1), 1, accuracy: 1e-5)
        XCTAssertEqual(PlaneRemap.coverage(uv: SIMD2(0.95, 0.0), angleRadians: a, perspective: 0.5, softness: 1), 0)     // beside the keystone
        XCTAssertEqual(PlaneRemap.coverage(uv: SIMD2(0.5, 1.0), angleRadians: a, perspective: 0.5, softness: 1), 1, accuracy: 1e-5)   // hinge row
    }
    func testCoverageMeltsTheSidesOverTheFeather() {
        let a: Float = 60 * .pi / 180
        // Row at h = 0.5: half-width 0.5·(1 − 0.5·(1 − 2/3)) = 0.41667, feather 0.35·0.5·sin 60° = 0.1516.
        let edge: Float = 0.5 + 0.41667
        let just = PlaneRemap.coverage(uv: SIMD2(edge - 0.01, 0.5), angleRadians: a, perspective: 0.5, softness: 1)
        let deeper = PlaneRemap.coverage(uv: SIMD2(edge - 0.08, 0.5), angleRadians: a, perspective: 0.5, softness: 1)
        let inside = PlaneRemap.coverage(uv: SIMD2(edge - 0.2, 0.5), angleRadians: a, perspective: 0.5, softness: 1)
        XCTAssertGreaterThan(just, 0); XCTAssertLessThan(just, 0.1)
        XCTAssertGreaterThan(deeper, just); XCTAssertLessThan(deeper, 0.9)
        XCTAssertEqual(inside, 1, accuracy: 1e-5)
        // Softness 0: the old crisp cut.
        XCTAssertEqual(PlaneRemap.coverage(uv: SIMD2(edge - 0.001, 0.5), angleRadians: a, perspective: 0.5, softness: 0), 1)
        XCTAssertEqual(PlaneRemap.coverage(uv: SIMD2(edge + 0.001, 0.5), angleRadians: a, perspective: 0.5, softness: 0), 0)
    }
    func testCoverageMeltsTheTopRow() {
        let a: Float = 60 * .pi / 180                                // top feather 0.08·sin 60° = 0.0693 in display heights
        XCTAssertEqual(PlaneRemap.coverage(uv: SIMD2(0.5, 0.0), angleRadians: a, perspective: 0, softness: 1), 0, accuracy: 1e-5)
        let mid = PlaneRemap.coverage(uv: SIMD2(0.5, 0.035), angleRadians: a, perspective: 0, softness: 1)
        XCTAssertGreaterThan(mid, 0.3); XCTAssertLessThan(mid, 0.7)
        XCTAssertEqual(PlaneRemap.coverage(uv: SIMD2(0.5, 0.1), angleRadians: a, perspective: 0, softness: 1), 1, accuracy: 1e-5)
    }
    func testFlatDisplayIsUntouched() {
        for uv: SIMD2<Float> in [SIMD2(0.001, 0.001), SIMD2(0.999, 0.5), SIMD2(0.5, 0.999)] {
            XCTAssertEqual(PlaneRemap.coverage(uv: uv, angleRadians: 0, perspective: 1, softness: 2), 1, accuracy: 1e-5)
            XCTAssertEqual(PlaneRemap.shade(heightFromHinge: 1 - uv.y, angleRadians: 0, strength: 2), 1)
        }
    }

    func testBlurGrowsWithTheGap() {
        XCTAssertEqual(PlaneRemap.blurRadius(heightFromHinge: 0, angleRadians: 1, strength: 1), 0)
        XCTAssertEqual(PlaneRemap.blurRadius(heightFromHinge: 1, angleRadians: 0, strength: 1), 0)
        XCTAssertEqual(PlaneRemap.blurRadius(heightFromHinge: 1, angleRadians: .pi / 2, strength: 1), 65, accuracy: 1e-4)
        XCTAssertEqual(PlaneRemap.blurRadius(heightFromHinge: 0.5, angleRadians: .pi / 2, strength: 1), 32.5, accuracy: 1e-4)
        XCTAssertEqual(PlaneRemap.blurRadius(heightFromHinge: 1, angleRadians: .pi / 2, strength: 0.5), 32.5, accuracy: 1e-4)
    }
}
