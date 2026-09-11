import XCTest
import KoffeeLidCore

final class ArmingPolicyTests: XCTestCase {
    let ok = DisplayTopology(builtInCount: 1, externalCount: 0, verified: true)
    let policy = ArmingPolicy(lowBatteryDisarmEnabled: true, lowBatteryPercent: 10)

    func testAllowsBuiltInOnlyNominal() {
        XCTAssertEqual(policy.evaluate(displays: ok, thermal: .nominal, battery: nil), .allowed)
    }
    func testExternalDisplayAllowsArmingButStandsBy() {
        let t = DisplayTopology(builtInCount: 1, externalCount: 1, verified: true)
        XCTAssertEqual(policy.evaluate(displays: t, thermal: .nominal, battery: nil), .allowed)
        XCTAssertTrue(t.standsBy)
        XCTAssertFalse(ok.standsBy)
    }
    func testBlocksUnverifiedTopology() {
        let t = DisplayTopology(builtInCount: 0, externalCount: 0, verified: false)
        XCTAssertEqual(policy.evaluate(displays: t, thermal: .nominal, battery: nil), .blocked(.displayUnverified))
    }
    func testBlocksSeriousAndCriticalThermal() {
        XCTAssertEqual(policy.evaluate(displays: ok, thermal: .serious, battery: nil), .blocked(.thermal(.serious)))
        XCTAssertEqual(policy.evaluate(displays: ok, thermal: .critical, battery: nil), .blocked(.thermal(.critical)))
        XCTAssertEqual(policy.evaluate(displays: ok, thermal: .fair, battery: nil), .allowed)
    }
    func testBlocksLowBatteryOnlyWhenOnBatteryAndEnabled() {
        let low = BatteryState(percent: 8, onBattery: true)
        XCTAssertEqual(policy.evaluate(displays: ok, thermal: .nominal, battery: low), .blocked(.batteryLow(8)))
        let charging = BatteryState(percent: 8, onBattery: false)
        XCTAssertEqual(policy.evaluate(displays: ok, thermal: .nominal, battery: charging), .allowed)
        let disabled = ArmingPolicy(lowBatteryDisarmEnabled: false, lowBatteryPercent: 10)
        XCTAssertEqual(disabled.evaluate(displays: ok, thermal: .nominal, battery: low), .allowed)
    }
    func testThermalStillBlocksWithExternalDisplay() {
        let t = DisplayTopology(builtInCount: 1, externalCount: 2, verified: true)
        XCTAssertEqual(policy.evaluate(displays: t, thermal: .critical, battery: nil), .blocked(.thermal(.critical)))
    }
    func testLowBatteryOnChargerIsAllowedAndOnBatteryIsNot() {
        // Below the threshold: allowed on AC (charging or full), refused the moment the Mac runs on battery.
        XCTAssertEqual(policy.evaluate(displays: ok, thermal: .nominal, battery: BatteryState(percent: 3, onBattery: false)), .allowed)
        XCTAssertEqual(policy.evaluate(displays: ok, thermal: .nominal, battery: BatteryState(percent: 3, onBattery: true)), .blocked(.batteryLow(3)))
    }
    func testBlockReasonCasesAreDistinct() {
        XCTAssertNotEqual(ArmBlockReason.disabled, .flagSetFailed)
        XCTAssertNotEqual(ArmBlockReason.disabled, .displayUnverified)
    }
}
