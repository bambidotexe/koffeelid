import XCTest
import KoffeeLidCore

final class EffectParametersTests: XCTestCase {
    func testDefaults() {
        let p = EffectParameters.default
        XCTAssertTrue(p.enabled); XCTAssertEqual(p.zoomStrength, 0.8); XCTAssertEqual(p.perspectiveStrength, 0.4); XCTAssertEqual(p.blurStrength, 0.15); XCTAssertEqual(p.responsiveness, 0.7)
        XCTAssertEqual(p.startBelowDegrees, 75); XCTAssertEqual(p.gestureStartBelowDegrees, 95)
        XCTAssertEqual(p.edgeSoftness, 1); XCTAssertEqual(p.shading, 1)
        XCTAssertEqual(p.settleDelay, 0.5); XCTAssertFalse(p.showAngleInMenuBar)
    }
    func testEdgeSoftnessAndShadingClampToTwo() {
        var p = EffectParameters.default
        p.edgeSoftness = 5; p.shading = -1
        XCTAssertEqual(p.clamped().edgeSoftness, 2); XCTAssertEqual(p.clamped().shading, 0)
        p.edgeSoftness = -3; p.shading = 7
        XCTAssertEqual(p.clamped().edgeSoftness, 0); XCTAssertEqual(p.clamped().shading, 2)
    }
    func testGestureStartIsNeverBelowTheOtherStart() {
        var p = EffectParameters.default
        p.startBelowDegrees = 85; p.gestureStartBelowDegrees = 60
        XCTAssertEqual(p.clamped().gestureStartBelowDegrees, 85)      // raised to the "except" value
        XCTAssertEqual(p.clamped().startBelowDegrees, 85)
        p.gestureStartBelowDegrees = 110
        XCTAssertEqual(p.clamped().gestureStartBelowDegrees, 110)     // above it is fine
        p.gestureStartBelowDegrees = 200; p.startBelowDegrees = 30
        XCTAssertEqual(p.clamped().gestureStartBelowDegrees, 120)
        p.gestureStartBelowDegrees = 10
        XCTAssertEqual(p.clamped().gestureStartBelowDegrees, 30)      // floor is the other slider's floor
    }
    func testStoredSettingsWithoutTheGestureStartKeepDecoding() throws {
        let json = #"{"enabled":true,"zoomStrength":0.6,"perspectiveStrength":0.5,"blurStrength":0.15,"responsiveness":0.7,"startBelowDegrees":70,"settleDelay":0.5,"showAngleInMenuBar":false}"#
        let p = try JSONDecoder().decode(EffectParameters.self, from: Data(json.utf8))
        XCTAssertEqual(p.zoomStrength, 0.6); XCTAssertEqual(p.startBelowDegrees, 70)
        XCTAssertEqual(p.gestureStartBelowDegrees, 95)
        XCTAssertEqual(p.edgeSoftness, 1); XCTAssertEqual(p.shading, 1)
    }
    func testClampedBounds() {
        var p = EffectParameters.default
        p.zoomStrength = 3; p.perspectiveStrength = 3; p.blurStrength = 9; p.responsiveness = 4; p.startBelowDegrees = 500; p.settleDelay = 99
        let c = p.clamped()
        XCTAssertEqual(c.zoomStrength, 2.0); XCTAssertEqual(c.perspectiveStrength, 2.0); XCTAssertEqual(c.blurStrength, 2.0); XCTAssertEqual(c.responsiveness, 1); XCTAssertEqual(c.startBelowDegrees, 90)
        XCTAssertEqual(c.settleDelay, 10)
        p.zoomStrength = -1; p.perspectiveStrength = -1; p.blurStrength = -1; p.settleDelay = 0
        let d = p.clamped()
        XCTAssertEqual(d.zoomStrength, 0); XCTAssertEqual(d.perspectiveStrength, 0); XCTAssertEqual(d.blurStrength, 0); XCTAssertEqual(d.settleDelay, 0.25)
    }
    func testRoundTripsThroughJSON() throws {
        let p = EffectParameters.default
        let data = try JSONEncoder().encode(p)
        XCTAssertEqual(try JSONDecoder().decode(EffectParameters.self, from: data), p)
    }
    func testOldStoredShapesFailToDecodeSoCallersFallBackToDefault() {
        let perspective = #"{"enabled":true,"mode":"perspective","progressiveBlur":true,"blurStrength":1,"autoAnchor":true,"anchorDelay":0.15,"anchorEaseDuration":0.2,"maxFoldDegrees":60,"showAngleInMenuBar":false}"#
        XCTAssertThrowsError(try JSONDecoder().decode(EffectParameters.self, from: Data(perspective.utf8)))
        let holdContentAngle = #"{"enabled":true,"progressiveBlur":true,"blurStrength":0.25,"startBelowDegrees":70,"maxFoldDegrees":75,"settleDelay":1,"showAngleInMenuBar":false}"#
        XCTAssertThrowsError(try JSONDecoder().decode(EffectParameters.self, from: Data(holdContentAngle.utf8)))
    }
}
