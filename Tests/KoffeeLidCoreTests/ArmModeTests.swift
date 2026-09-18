import XCTest
import KoffeeLidCore

final class ArmModeTests: XCTestCase {
    // Right-click: Off → Armed → Armed + Caffeinate → Off within the window; from an armed mode
    // that has stood for longer than the window, straight to Off.
    func testRightClickFromOffAlwaysArms() {
        XCTAssertEqual(ModeCycle.nextOnRightClick(current: .off, sinceLastChange: 0), .armed)
        XCTAssertEqual(ModeCycle.nextOnRightClick(current: .off, sinceLastChange: 100), .armed)
    }
    func testRightClickContinuesCycleWithinWindow() {
        XCTAssertEqual(ModeCycle.nextOnRightClick(current: .armed, sinceLastChange: 1.5), .caffeinate)
        XCTAssertEqual(ModeCycle.nextOnRightClick(current: .caffeinate, sinceLastChange: 1.5), .off)
    }
    func testRightClickAfterWindowTurnsOff() {
        XCTAssertEqual(ModeCycle.nextOnRightClick(current: .armed, sinceLastChange: 3.0), .off)
        XCTAssertEqual(ModeCycle.nextOnRightClick(current: .armed, sinceLastChange: 40), .off)
        XCTAssertEqual(ModeCycle.nextOnRightClick(current: .caffeinate, sinceLastChange: 40), .off)
    }
    func testWindowIsConfigurable() {
        XCTAssertEqual(ModeCycle.nextOnRightClick(current: .armed, sinceLastChange: 4, window: 5), .caffeinate)
    }

    // Shortcuts: each targets one mode; pressing it in that mode turns off, in any other mode switches to it.
    func testArmedShortcut() {
        XCTAssertEqual(ModeCycle.nextOnShortcut(target: .armed, current: .off), .armed)
        XCTAssertEqual(ModeCycle.nextOnShortcut(target: .armed, current: .armed), .off)
        XCTAssertEqual(ModeCycle.nextOnShortcut(target: .armed, current: .caffeinate), .armed)
    }
    func testCaffeinateShortcut() {
        XCTAssertEqual(ModeCycle.nextOnShortcut(target: .caffeinate, current: .off), .caffeinate)
        XCTAssertEqual(ModeCycle.nextOnShortcut(target: .caffeinate, current: .caffeinate), .off)
        XCTAssertEqual(ModeCycle.nextOnShortcut(target: .caffeinate, current: .armed), .caffeinate)
    }
    func testOffTargetIsOff() {
        XCTAssertEqual(ModeCycle.nextOnShortcut(target: .off, current: .armed), .off)
    }

    func testModeProperties() {
        XCTAssertFalse(ArmMode.armed.keepsDisplayOn)
        XCTAssertTrue(ArmMode.caffeinate.keepsDisplayOn)
        XCTAssertEqual(ArmMode(rawValue: "caffeinate"), .caffeinate)
    }
}
