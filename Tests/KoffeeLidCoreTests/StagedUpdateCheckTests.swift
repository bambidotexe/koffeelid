import XCTest
import KoffeeLidCore

final class StagedUpdateCheckTests: XCTestCase {
    private let system = ReleaseVersion(27, 0, 0)

    private func rejection(identifier: String? = "dev.rubens.koffeelid", version: String? = "1.2.0", minimumSystem: String? = "15.0",
                           running: String = "1.1.0") -> StagedUpdateCheck.Rejection? {
        StagedUpdateCheck.rejection(staged: .init(bundleIdentifier: identifier, version: version, minimumSystemVersion: minimumSystem),
                                    runningIdentifier: "dev.rubens.koffeelid", runningVersion: running, systemVersion: system)
    }

    func testANewerCopyOfTheSameAppIsAccepted() {
        XCTAssertNil(rejection())
    }
    func testAnotherAppIsRefused() {
        XCTAssertEqual(rejection(identifier: "com.example.other"), .wrongApp)
        XCTAssertEqual(rejection(identifier: nil), .wrongApp)
    }
    func testTheSameOrAnOlderVersionIsRefusedSoAnInstallCannotLoopOrGoBack() {
        XCTAssertEqual(rejection(version: "1.1.0"), .notNewer("1.1.0"))
        XCTAssertEqual(rejection(version: "1.0.9"), .notNewer("1.0.9"))
        XCTAssertEqual(rejection(version: nil), .notNewer(nil))
        XCTAssertEqual(rejection(version: "banana"), .notNewer("banana"))
    }
    func testARunningVersionThatDoesNotParseIsNeverReplaced() {
        XCTAssertEqual(rejection(running: ""), .notNewer("1.2.0"))
    }
    func testACopyThatNeedsANewerMacOSIsRefused() {
        XCTAssertEqual(rejection(minimumSystem: "28.0"), .needsNewerSystem("28.0"))
        XCTAssertNil(rejection(minimumSystem: "27.0"))
        XCTAssertNil(rejection(minimumSystem: nil), "no stated minimum is no obstacle")
    }
}
