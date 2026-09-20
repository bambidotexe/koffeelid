import XCTest
import KoffeeLidCore

final class UninstallPlanTests: XCTestCase {
    func testTheRootOwnedFilesAreTheSudoersRuleAndTheWrapper() {
        XCTAssertEqual(UninstallPlan.privilegedPaths, [SleepLockSetup.sudoersFile, "/usr/local/bin/koffeelid"])
    }

    func testNoDialogWhenNeitherFileIsThere() {
        XCTAssertFalse(UninstallPlan.needsPrivilege(present: { _ in false }))
    }

    func testOneFilePresentIsEnoughToAskForThePassword() {
        for path in UninstallPlan.privilegedPaths {
            XCTAssertTrue(UninstallPlan.needsPrivilege(present: { $0 == path }), path)
        }
    }

    /// The script is two literals behind `rm -f`: nothing is interpolated, nothing recurses.
    func testTheScriptRemovesExactlyThoseTwoFilesAndNothingElse() {
        let script = UninstallPlan.privilegedScript
        XCTAssertEqual(script, "/bin/rm -f \(SleepLockSetup.sudoersFile) /usr/local/bin/koffeelid")
        XCTAssertFalse(script.contains("-r"))
        XCTAssertFalse(script.contains("*"))
        XCTAssertFalse(script.contains(";"))
    }
}
