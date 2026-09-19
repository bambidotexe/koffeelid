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
        XCTAssertFalse(panel.isProminent)
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

    // MARK: The answers to a check

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
        XCTAssertTrue(panel.isProminent)
    }
    func testFailedCheckIsOrangeAndChecksAgain() {
        var panel = UpdatePanel()
        _ = panel.press()
        panel.checkFailed("offline")
        XCTAssertEqual(panel.state, .checkFailed("offline"))
        XCTAssertEqual(panel.severity, .warning)
        XCTAssertEqual(panel.press(), .check)
    }

    // MARK: Fetching

    func testPressWithAReleaseDownloadsIt() {
        var panel = panelWithRelease()
        XCTAssertEqual(panel.press(), .download(release))
        XCTAssertEqual(panel.state, .downloading)
        XCTAssertEqual(panel.severity, .busy)
        XCTAssertFalse(panel.isProminent)
    }
    func testDownloadedIsGreenAndKeepsTheButton() {
        var panel = panelWithRelease()
        _ = panel.press()
        panel.downloaded()
        XCTAssertEqual(panel.state, .downloaded)
        XCTAssertEqual(panel.severity, .good)
        XCTAssertTrue(panel.offersUpdate)
        XCTAssertFalse(panel.isProminent)
    }
    func testFailedDownloadKeepsTheReleaseSoThePressIsTheRetry() {
        var panel = panelWithRelease()
        _ = panel.press()
        panel.downloadFailed("disk full")
        XCTAssertEqual(panel.state, .downloadFailed("disk full"))
        XCTAssertEqual(panel.severity, .warning)
        XCTAssertFalse(panel.isProminent)
        XCTAssertEqual(panel.press(), .download(release))
    }
}
