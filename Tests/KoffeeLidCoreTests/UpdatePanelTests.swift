import XCTest
import KoffeeLidCore

final class UpdatePanelTests: XCTestCase {
    private let release = LatestRelease(version: ReleaseVersion(1, 2, 0), dmgURL: URL(string: "https://example.com/KoffeeLid-1.2.0.dmg")!)

    private func panelWithRelease() -> UpdatePanel {
        var panel = UpdatePanel()
        _ = panel.press()
        panel.checked(.available(release))
        return panel
    }

    // MARK: Before and during a check

    func testStartsWithNothingToReport() {
        let panel = UpdatePanel()
        XCTAssertEqual(panel.state, .idle)
        XCTAssertNil(panel.severity)
        XCTAssertFalse(panel.isBusy)
        XCTAssertFalse(panel.offersUpdate)
    }
    func testFirstPressChecks() {
        var panel = UpdatePanel()
        XCTAssertEqual(panel.press(), .check)
        XCTAssertEqual(panel.state, .checking)
        XCTAssertEqual(panel.severity, .busy)
        XCTAssertTrue(panel.isBusy)
    }
    func testPressWhileBusyStartsNothing() {
        var panel = UpdatePanel()
        _ = panel.press()
        XCTAssertNil(panel.press())
        XCTAssertEqual(panel.state, .checking)
    }

    // MARK: The answers to a press

    func testUpToDateIsGreenAndChecksAgain() {
        var panel = UpdatePanel()
        _ = panel.press()
        panel.checked(.upToDate)
        XCTAssertEqual(panel.state, .upToDate)
        XCTAssertEqual(panel.severity, .good)
        XCTAssertFalse(panel.offersUpdate)
        XCTAssertEqual(panel.press(), .check)
    }
    func testNewerReleaseTurnsTheButtonIntoUpdate() {
        let panel = panelWithRelease()
        XCTAssertEqual(panel.state, .available(release.version))
        XCTAssertEqual(panel.severity, .info)
        XCTAssertTrue(panel.offersUpdate)
    }
    func testFailedCheckIsOrangeAndChecksAgain() {
        var panel = UpdatePanel()
        _ = panel.press()
        panel.checkFailed("offline")
        XCTAssertEqual(panel.state, .checkFailed("offline"))
        XCTAssertEqual(panel.severity, .warning)
        XCTAssertEqual(panel.press(), .check)
    }

    // MARK: Update

    func testPressWithAReleaseOpensTheUpdateAndKeepsTheRow() {
        var panel = panelWithRelease()
        XCTAssertEqual(panel.press(), .update(release))
        XCTAssertEqual(panel.state, .available(release.version))
        XCTAssertEqual(panel.press(), .update(release), "every press is the same request: the window is shown again")
    }

    // MARK: A check nobody asked for

    func testAutomaticNewerReleaseShowsLikeAnAnswerToAPress() {
        var panel = UpdatePanel()
        panel.autoChecked(.available(release))
        XCTAssertEqual(panel.state, .available(release.version))
        XCTAssertEqual(panel.press(), .update(release))
    }
    func testAutomaticUpToDateIsGreen() {
        var panel = panelWithRelease()
        panel.autoChecked(.upToDate)
        XCTAssertEqual(panel.state, .upToDate)
        XCTAssertFalse(panel.offersUpdate)
    }
    func testAutomaticAnswerNeverInterruptsAPress() {
        var panel = UpdatePanel()
        _ = panel.press()
        panel.autoChecked(.upToDate)
        XCTAssertEqual(panel.state, .checking)
    }

    // MARK: An install that did not end well

    func testFailedInstallIsOrangeAndTheNextPressChecks() {
        var panel = UpdatePanel()
        panel.installFailed("did not start")
        XCTAssertEqual(panel.state, .installFailed("did not start"))
        XCTAssertEqual(panel.severity, .warning)
        XCTAssertEqual(panel.press(), .check)
    }
    func testAutomaticNewerReleaseAfterAFailedInstallKeepsTheReasonAndOffersTheRetry() {
        var panel = UpdatePanel()
        panel.installFailed("did not start")
        panel.autoChecked(.available(release))
        XCTAssertEqual(panel.state, .installFailed("did not start"))
        XCTAssertEqual(panel.press(), .update(release))
    }
}
