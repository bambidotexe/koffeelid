import XCTest
import KoffeeLidCore

final class AngleSampleFilterTests: XCTestCase {
    func testRejectsOutOfRange() {
        var f = AngleSampleFilter()
        XCTAssertNil(f.accept(-1)); XCTAssertNil(f.accept(181)); XCTAssertEqual(f.accept(90), 90)
    }
    func testRejectsJumpLargerThanMax() {
        var f = AngleSampleFilter(maxJumpPerSample: 40)
        XCTAssertEqual(f.accept(100), 100)
        XCTAssertNil(f.accept(30))          // 70° jump: glitch
        XCTAssertEqual(f.accept(95), 95)    // back to plausible
    }
    func testTwoConsecutiveOutliersBecomeNewBaseline() {
        var f = AngleSampleFilter(maxJumpPerSample: 40)
        _ = f.accept(100)
        XCTAssertNil(f.accept(20))
        XCTAssertEqual(f.accept(21), 21)    // sensor really moved; accept second agreeing sample
    }
    func testResetClearsHistory() {
        var f = AngleSampleFilter(maxJumpPerSample: 40)
        _ = f.accept(100); f.reset()
        XCTAssertEqual(f.accept(10), 10)
    }
}
