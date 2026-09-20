import XCTest
import KoffeeLidCore

final class UpdateSessionTests: XCTestCase {
    private let sized = LatestRelease(version: ReleaseVersion(1, 2, 0), dmgURL: URL(string: "https://example.com/K.dmg")!, dmgSize: 1000)
    private let unsized = LatestRelease(version: ReleaseVersion(1, 2, 0), dmgURL: URL(string: "https://example.com/K.dmg")!)

    private func readySession() -> UpdateSession {
        var session = UpdateSession(release: sized)
        session.downloaded()
        session.prepared()
        return session
    }

    // MARK: Downloading

    func testStartsDownloadingWithGitHubsSizeAsTheTotal() {
        let session = UpdateSession(release: sized)
        XCTAssertEqual(session.phase, .downloading(received: 0, expected: 1000))
        XCTAssertEqual(session.fraction, 0)
        XCTAssertFalse(session.canInstall)
        XCTAssertTrue(session.canCancel)
    }
    func testProgressFollowsTheBytes() {
        var session = UpdateSession(release: sized)
        session.received(250, of: 1000)
        XCTAssertEqual(session.fraction, 0.25)
    }
    func testAResponseWithoutALengthFallsBackOnGitHubsSize() {
        var session = UpdateSession(release: sized)
        session.received(500, of: -1)
        XCTAssertEqual(session.phase, .downloading(received: 500, expected: 1000))
        XCTAssertEqual(session.fraction, 0.5)
    }
    func testNoTotalAtAllIsAnIndeterminateBar() {
        var session = UpdateSession(release: unsized)
        session.received(500, of: -1)
        XCTAssertNil(session.fraction)
    }
    func testTheBarNeverOverflows() {
        var session = UpdateSession(release: sized)
        session.received(1500, of: 1000)
        XCTAssertEqual(session.fraction, 1)
    }

    // MARK: Preparing, ready

    func testTheButtonEnablesOnlyOnceTheUpdateIsPrepared() {
        var session = UpdateSession(release: sized)
        session.downloaded()
        XCTAssertEqual(session.phase, .preparing)
        XCTAssertNil(session.fraction)
        XCTAssertFalse(session.canInstall)
        session.prepared()
        XCTAssertEqual(session.phase, .ready)
        XCTAssertEqual(session.fraction, 1)
        XCTAssertTrue(session.canInstall)
    }
    func testProgressAfterTheDownloadIsIgnored() {
        var session = readySession()
        session.received(10, of: 1000)
        XCTAssertEqual(session.phase, .ready)
    }
    func testAnAppThatCannotReplaceItselfOffersTheDiskImage() {
        var session = UpdateSession(release: sized)
        session.downloaded()
        session.cannotReplace()
        XCTAssertEqual(session.phase, .manual)
        XCTAssertFalse(session.canInstall)
        XCTAssertEqual(session.fraction, 1)
    }

    // MARK: Installing

    func testInstallStartsOnceAndOnlyWhenReady() {
        var session = readySession()
        XCTAssertTrue(session.install())
        XCTAssertEqual(session.phase, .installing)
        XCTAssertFalse(session.canCancel)
        XCTAssertFalse(session.install(), "a second click starts no second install")

        var early = UpdateSession(release: sized)
        XCTAssertFalse(early.install())
        XCTAssertEqual(early.phase, .downloading(received: 0, expected: 1000))
    }

    // MARK: Failing, and trying again

    func testAFailureKeepsItsReasonAndCanBeRetried() {
        var session = UpdateSession(release: sized)
        session.received(400, of: 1000)
        session.failed("offline")
        XCTAssertEqual(session.phase, .failed("offline"))
        XCTAssertFalse(session.canInstall)
        XCTAssertTrue(session.retry())
        XCTAssertEqual(session.phase, .downloading(received: 0, expected: 1000))
    }
    func testRetryDoesNothingUnlessItFailed() {
        var session = readySession()
        XCTAssertFalse(session.retry())
        XCTAssertEqual(session.phase, .ready)
    }
    func testAnInstallThatDidNotQuitTheAppCanBeTriedAgainWithoutFetchingAgain() {
        var session = readySession()
        XCTAssertFalse(session.stalled)
        _ = session.install()
        session.installStalled()
        XCTAssertEqual(session.phase, .ready)
        XCTAssertTrue(session.stalled)
        XCTAssertTrue(session.canInstall)
        XCTAssertTrue(session.install())
        XCTAssertFalse(session.stalled, "the next try starts clean")
    }
}
