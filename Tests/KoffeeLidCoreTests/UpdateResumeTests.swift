import XCTest
import KoffeeLidCore

final class UpdateResumeTests: XCTestCase {
    private let quit = Date(timeIntervalSince1970: 1_800_000_000)

    func testAnArmedModeComesBackWhenTheRelaunchIsPrompt() {
        XCTAssertEqual(UpdateResume(mode: .armed, writtenAt: quit).modeToRestore(now: quit + 4), .armed)
    }
    func testScreenOnComesBackAsScreenOn() {
        XCTAssertEqual(UpdateResume(mode: .caffeinate, writtenAt: quit).modeToRestore(now: quit + 4), .caffeinate)
    }
    func testOffLeavesNothingToRestore() {
        XCTAssertNil(UpdateResume(mode: .off, writtenAt: quit).modeToRestore(now: quit + 4))
    }
    func testARelaunchThatCameTooLateRestoresNothing() {
        let resume = UpdateResume(mode: .armed, writtenAt: quit)
        XCTAssertEqual(resume.modeToRestore(now: quit + UpdateResume.window), .armed)
        XCTAssertNil(resume.modeToRestore(now: quit + UpdateResume.window + 1), "a Mac that slept in between is not armed behind the user's back")
    }
    func testAClockSetBackRestoresNothing() {
        XCTAssertNil(UpdateResume(mode: .armed, writtenAt: quit).modeToRestore(now: quit - 1))
    }
    func testContentsRoundTrip() {
        let resume = UpdateResume(mode: .caffeinate, writtenAt: quit)
        XCTAssertEqual(UpdateResume(contents: resume.contents + "\n"), resume)
    }
    func testUnreadableContentsAreNothing() {
        XCTAssertNil(UpdateResume(contents: ""))
        XCTAssertNil(UpdateResume(contents: "armed"))
        XCTAssertNil(UpdateResume(contents: "sideways 1800000000"))
        XCTAssertNil(UpdateResume(contents: "armed soon"))
    }
}
