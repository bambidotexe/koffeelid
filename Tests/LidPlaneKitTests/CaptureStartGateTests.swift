import XCTest
@testable import LidPlaneKit

/// `DesktopCapture` promises that a stop landing while a start is in flight wins, whatever the start is
/// awaiting at that moment. The gate is the part of that promise that needs no ScreenCaptureKit.
final class CaptureStartGateTests: XCTestCase {
    func testStartWithNoInterveningStopInstalls() {
        var gate = CaptureStartGate()
        let token = gate.beginStart()
        XCTAssertTrue(gate.isCurrent(token))
    }

    func testStopAfterStartBeganWins() {
        var gate = CaptureStartGate()
        let token = gate.beginStart()
        gate.stop()
        XCTAssertFalse(gate.isCurrent(token))
    }

    func testNewerStartSupersedesOlder() {
        var gate = CaptureStartGate()
        let older = gate.beginStart()
        let newer = gate.beginStart()
        XCTAssertFalse(gate.isCurrent(older))
        XCTAssertTrue(gate.isCurrent(newer))
    }

    func testStartAfterStopIsCurrent() {
        var gate = CaptureStartGate()
        _ = gate.beginStart()
        gate.stop()
        let token = gate.beginStart()
        XCTAssertTrue(gate.isCurrent(token))
    }
}
