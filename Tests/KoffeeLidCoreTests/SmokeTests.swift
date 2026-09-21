import XCTest
import KoffeeLidCore

final class SmokeTests: XCTestCase {
    func testModuleLoads() {
        XCTAssertEqual(KoffeeLidCore.version, "1.1.0")
    }
}
