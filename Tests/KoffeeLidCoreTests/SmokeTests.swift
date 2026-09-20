import XCTest
import KoffeeLidCore

final class SmokeTests: XCTestCase {
    func testModuleLoads() {
        XCTAssertEqual(KoffeeLidCore.version, "0.1.2")
    }
}
