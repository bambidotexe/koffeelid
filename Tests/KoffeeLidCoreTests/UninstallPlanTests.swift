import XCTest
@testable import KoffeeLidCore

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

    private func helper(home: String = "/Users/x") -> String {
        UninstallPlan.helperScript(pid: 4242, domain: "dev.rubens.koffeelid",
                                   supportDirectory: home + "/Library/Application Support/KoffeeLid",
                                   home: home)
    }

    /// The whole reason the helper exists: everything removed while the app still runs comes back, so
    /// nothing in it may run before the pid has gone.
    func testEveryRemovalWaitsForThePidToGo() {
        let lines = helper().split(separator: "\n").map(String.init)
        let wait = lines.firstIndex { $0.contains("kill -0 4242") }
        XCTAssertNotNil(wait)
        for (index, line) in lines.enumerated() where line.contains("rm -rf") || line.contains("defaults delete") || line.contains("find") {
            XCTAssertGreaterThan(index, wait!, line)
        }
    }

    func testTheWaitIsBounded() {
        XCTAssertTrue(helper().contains("[ $i -lt \(UninstallPlan.helperWaitTenths) ]"))
    }

    /// The two that came back on a real uninstall: the journal recreated on the way through `shutdown()`,
    /// and the empty domain `cfprefsd` writes as the process exits.
    func testItRemovesTheSupportFolderAndThePreferences() {
        let script = helper()
        XCTAssertTrue(script.contains("'/Users/x/Library/Application Support/KoffeeLid'"))
        XCTAssertTrue(script.contains("/usr/bin/defaults delete dev.rubens.koffeelid"))
        XCTAssertTrue(script.contains("'/Users/x/Library/Preferences/dev.rubens.koffeelid.plist'"))
    }

    /// `defaults delete` first, or cfprefsd writes its cache back over the gap the `rm` just made.
    func testThePreferencesAreDeletedBeforeTheirFileIsRemoved() {
        let script = helper()
        XCTAssertLessThan(script.range(of: "defaults delete")!.lowerBound,
                          script.range(of: "Preferences/dev.rubens.koffeelid.plist")!.lowerBound)
    }

    func testItTakesTheCachesTheHTTPStorageAndTheSavedState() {
        for tail in ["Caches/dev.rubens.koffeelid", "HTTPStorages/dev.rubens.koffeelid",
                     "HTTPStorages/dev.rubens.koffeelid.binarycookies",
                     "Saved Application State/dev.rubens.koffeelid.savedState"] {
            XCTAssertTrue(helper().contains("'/Users/x/Library/\(tail)'"), tail)
        }
    }

    /// One ByHost file per host identifier, so a glob; `find` keeps that glob away from a home folder
    /// whose name has a space in it.
    func testTheByHostPreferencesGoThroughFindRatherThanAGlob() {
        let script = helper(home: "/Users/a b")
        XCTAssertTrue(script.contains("/usr/bin/find '/Users/a b/Library/Preferences/ByHost' -maxdepth 1 -name 'dev.rubens.koffeelid.*.plist' -delete"))
    }

    func testAQuoteInTheHomeFolderCannotEndTheQuoting() {
        XCTAssertEqual(UninstallPlan.shellQuoted("/Users/o'brien"), "'/Users/o'\\''brien'")
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
