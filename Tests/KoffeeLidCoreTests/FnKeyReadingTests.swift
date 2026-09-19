import XCTest
import KoffeeLidCore

final class FnKeyReadingTests: XCTestCase {
    func testFnFlagWithThePhysicalKeyDownIsFn() {
        XCTAssertTrue(FnKeyReading.isFnDown(secondaryFn: true, numericPad: false, keyDown: true))
    }
    func testArrowKeyIsNotFn() {
        // Arrow keys raise the Fn flag together with the numeric-pad flag; key 63 stays up.
        XCTAssertFalse(FnKeyReading.isFnDown(secondaryFn: true, numericPad: true, keyDown: false))
    }
    func testFunctionOrNavigationKeyWithoutThePhysicalKeyIsNotFn() {
        // F1–F12 used as function keys and an external keyboard's Home/End/Page keys raise the Fn flag
        // without the numeric-pad flag; only the physical Fn key presses key 63.
        XCTAssertFalse(FnKeyReading.isFnDown(secondaryFn: true, numericPad: false, keyDown: false))
    }
    func testPhysicalKeyWithoutTheFlagIsNotFn() {
        XCTAssertFalse(FnKeyReading.isFnDown(secondaryFn: false, numericPad: false, keyDown: true))
    }
    func testNeitherFlagIsNotFn() {
        XCTAssertFalse(FnKeyReading.isFnDown(secondaryFn: false, numericPad: false, keyDown: false))
    }
    func testNumericPadAloneIsNotFn() {
        XCTAssertFalse(FnKeyReading.isFnDown(secondaryFn: false, numericPad: true, keyDown: false))
    }

    // With the built-in keyboard's own Fn key readable (Input Monitoring granted), only that key counts.
    func testBuiltInKeyDownWithTheSessionStateIsFn() {
        XCTAssertTrue(FnKeyReading.isFnDown(secondaryFn: true, numericPad: false, keyDown: true, builtInKeyDown: true))
    }
    func testExternalKeyboardFnIsNotFnWhenTheBuiltInKeyIsUp() {
        // An external Apple keyboard's Globe key sets the flag and key 63 like the built-in one.
        XCTAssertFalse(FnKeyReading.isFnDown(secondaryFn: true, numericPad: false, keyDown: true, builtInKeyDown: false))
    }
    func testBuiltInKeyAloneIsNotFn() {
        // A stale "down" from a missed key-up never counts without the session's own key state.
        XCTAssertFalse(FnKeyReading.isFnDown(secondaryFn: false, numericPad: false, keyDown: false, builtInKeyDown: true))
    }
    func testUnknownBuiltInStateFallsBackToTheSessionRule() {
        XCTAssertTrue(FnKeyReading.isFnDown(secondaryFn: true, numericPad: false, keyDown: true, builtInKeyDown: nil))
        XCTAssertFalse(FnKeyReading.isFnDown(secondaryFn: true, numericPad: false, keyDown: false, builtInKeyDown: nil))
    }
}
