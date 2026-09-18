import XCTest
import KoffeeLidCore

final class FnKeyReadingTests: XCTestCase {
    func testFnAloneIsDown() {
        XCTAssertTrue(FnKeyReading.isFnDown(secondaryFn: true, numericPad: false))
    }
    func testArrowKeyIsNotFn() {
        XCTAssertFalse(FnKeyReading.isFnDown(secondaryFn: true, numericPad: true))
    }
    func testNeitherFlagIsNotFn() {
        XCTAssertFalse(FnKeyReading.isFnDown(secondaryFn: false, numericPad: false))
    }
    func testNumericPadAloneIsNotFn() {
        XCTAssertFalse(FnKeyReading.isFnDown(secondaryFn: false, numericPad: true))
    }
}
