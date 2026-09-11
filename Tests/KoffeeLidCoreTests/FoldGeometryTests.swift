import XCTest
import KoffeeLidCore

final class FoldGeometryTests: XCTestCase {
    let g = FoldGeometry()

    func testGestureAboveUprightFollowsTheLidOneToOneFromNinety() {
        XCTAssertEqual(g.fold(angle: 100, zeroAngle: 106), 0)          // armed at 106°, nothing until 90°
        XCTAssertEqual(g.fold(angle: 90, zeroAngle: 106), 0)
        XCTAssertEqual(g.fold(angle: 80, zeroAngle: 106), 10, accuracy: 1e-9)
        XCTAssertEqual(g.fold(angle: 60, zeroAngle: 106), 30, accuracy: 1e-9)
    }
    func testNothingAtOrAboveTheZeroAngle() {
        XCTAssertEqual(g.fold(angle: 70, zeroAngle: 70), 0)
        XCTAssertEqual(g.fold(angle: 80, zeroAngle: 75), 0)
    }
    func testStartBelowUprightCatchesUpFasterThanTheLid() {
        let first = g.fold(angle: 69, zeroAngle: 70)                    // 1° of travel
        XCTAssertGreaterThan(first, 1.5); XCTAssertLessThan(first, 21)
        XCTAssertEqual(g.fold(angle: 50, zeroAngle: 70), 40, accuracy: 1e-9)   // caught up after the 20° gap
        XCTAssertEqual(g.fold(angle: 30, zeroAngle: 70), 60, accuracy: 1e-9)
    }
    func testCatchUpTravelIsCapped() {
        // zero at 40°: the gap to 90° is 50°, the catch-up takes 30°
        XCTAssertEqual(g.fold(angle: 30, zeroAngle: 40), 60 * (1 - (2.0 / 3) * (2.0 / 3)), accuracy: 1e-9)
        XCTAssertEqual(g.fold(angle: 10, zeroAngle: 40), 80, accuracy: 1e-9)
    }
    func testContinuousAtTheStart() {
        XCTAssertLessThan(g.fold(angle: 69.99, zeroAngle: 70), 0.05)
    }
    func testMonotonicWhileClosing() {
        var last = -1.0
        for a in stride(from: 88.0, through: 0, by: -0.5) {
            let f = g.fold(angle: a, zeroAngle: 88)
            XCTAssertGreaterThanOrEqual(f, last); last = f
        }
    }
}
