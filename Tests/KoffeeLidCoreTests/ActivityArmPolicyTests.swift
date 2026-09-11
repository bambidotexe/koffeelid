import XCTest
import KoffeeLidCore

/// The auto-arm is a level of its own, independent of the manual mode: on while work runs, off after the
/// hold-off once nothing does. The coordinator ORs it with the manual mode.
final class ActivityArmPolicyTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    func at(_ dt: TimeInterval) -> Date { t0.addingTimeInterval(dt) }
    var p = ActivityArmPolicy(holdOffs: [.claude: 1800, .terminal: 60])

    func testWorkTurnsTheLevelOnOnceAndOnlyWhenEnabled() {
        XCTAssertNil(p.update(running: [], enabled: true, now: t0))
        XCTAssertEqual(p.update(running: [.terminal], enabled: true, now: at(1)), .on)
        XCTAssertTrue(p.isOn)
        XCTAssertNil(p.update(running: [.terminal, .claude], enabled: true, now: at(2)), "already on")
        var q = ActivityArmPolicy()
        XCTAssertNil(q.update(running: [.terminal], enabled: false, now: t0), "feature off")
        XCTAssertFalse(q.isOn)
    }
    func testTheLevelDropsAfterTheKindsHoldOff() {
        _ = p.update(running: [.terminal], enabled: true, now: t0)
        XCTAssertNil(p.update(running: [], enabled: true, now: at(10)))
        XCTAssertTrue(p.isOn, "the hold-off keeps it on")
        XCTAssertEqual(p.nextDeadline(after: at(10)), at(70))
        XCTAssertNil(p.tick(now: at(69)))
        XCTAssertEqual(p.tick(now: at(70)), .off(releaseManual: false))
        XCTAssertFalse(p.isOn)
        XCTAssertNil(p.tick(now: at(71)), "fires once")
    }
    func testClaudeGetsTheLongHoldOff() {
        _ = p.update(running: [.claude], enabled: true, now: t0)
        _ = p.update(running: [], enabled: true, now: at(10))
        XCTAssertEqual(p.nextDeadline(after: at(10)), at(1810))
        XCTAssertNil(p.tick(now: at(1000))); XCTAssertEqual(p.tick(now: at(1810)), .off(releaseManual: false))
    }
    func testACommandFinishingLastDoesNotShortenClaudesHoldOff() {
        _ = p.update(running: [.claude], enabled: true, now: t0)
        _ = p.update(running: [.claude, .terminal], enabled: true, now: at(5))
        _ = p.update(running: [.terminal], enabled: true, now: at(10))    // Claude done first
        _ = p.update(running: [], enabled: true, now: at(20))
        XCTAssertEqual(p.involved, [.claude, .terminal]); XCTAssertEqual(p.nextDeadline(after: at(20)), at(1820))
    }
    func testAResumeInsideTheHoldOffCancelsTheDrop() {
        _ = p.update(running: [.terminal], enabled: true, now: t0)
        _ = p.update(running: [], enabled: true, now: at(10))
        XCTAssertNil(p.update(running: [.terminal], enabled: true, now: at(30)), "still on, no second .on")
        XCTAssertNil(p.nextDeadline(after: at(30))); XCTAssertNil(p.tick(now: at(100)))
    }
    func testAFreshStretchForgetsThePreviousKinds() {
        _ = p.update(running: [.claude], enabled: true, now: t0)
        _ = p.update(running: [], enabled: true, now: at(1))
        XCTAssertEqual(p.tick(now: at(1801)), .off(releaseManual: false))
        XCTAssertEqual(p.update(running: [.terminal], enabled: true, now: at(1900)), .on)
        _ = p.update(running: [], enabled: true, now: at(1910))
        XCTAssertEqual(p.nextDeadline(after: at(1910)), at(1970), "Claude from the previous stretch does not count")
    }
    func testABlockedArmWaitsUntilTheWorkStopsAndRestarts() {
        XCTAssertEqual(p.update(running: [.terminal], enabled: true, now: t0), .on)
        p.armFailed()
        XCTAssertFalse(p.isOn)
        XCTAssertNil(p.update(running: [.terminal], enabled: true, now: at(15)), "no retry on the level")
        _ = p.update(running: [], enabled: true, now: at(20))
        XCTAssertEqual(p.update(running: [.terminal], enabled: true, now: at(30)), .on)
    }
    func testARailSuspendsUntilTheWorkStopsAndRestarts() {
        _ = p.update(running: [.claude], enabled: true, now: t0)
        p.suspend()                                                  // low battery, thermal, external sleep, reset
        XCTAssertFalse(p.isOn); XCTAssertNil(p.nextDeadline(after: at(1)))
        XCTAssertNil(p.update(running: [.claude], enabled: true, now: at(5)))
        _ = p.update(running: [], enabled: true, now: at(10))
        XCTAssertEqual(p.update(running: [.claude], enabled: true, now: at(20)), .on)
    }
    func testSwitchingTheFeatureOffDropsTheLevelAtOnce() {
        _ = p.update(running: [.claude], enabled: true, now: t0)
        XCTAssertEqual(p.update(running: [.claude], enabled: false, now: at(1)), .off(releaseManual: false))
        XCTAssertFalse(p.isOn); XCTAssertNil(p.nextDeadline(after: at(1)))
    }
    func testEnablingWhileWorkRunsTurnsOn() {
        XCTAssertNil(p.update(running: [.terminal], enabled: false, now: t0))   // tracked while the feature was off
        XCTAssertEqual(p.update(running: [.terminal], enabled: true, now: at(5)), .on)
    }

    func testChangingAHoldOffMovesAPendingDrop() {
        _ = p.update(running: [.claude], enabled: true, now: t0)
        _ = p.update(running: [], enabled: true, now: at(10))
        XCTAssertEqual(p.nextDeadline(after: at(10)), at(1810))
        p.holdOffs[.claude] = 120                                    // Advanced slider dragged during the countdown
        XCTAssertEqual(p.nextDeadline(after: at(20)), at(130))
        XCTAssertEqual(p.tick(now: at(130)), .off(releaseManual: false))
    }

    func testLocalInputDuringTheHoldOffDropsTheLevelAtOnce() {
        _ = p.update(running: [.claude], enabled: true, now: t0)
        XCTAssertNil(p.userActive(now: at(5)), "input while the work runs changes nothing")
        _ = p.update(running: [], enabled: true, now: at(10))
        XCTAssertEqual(p.userActive(now: at(20)), .off(releaseManual: false))
        XCTAssertFalse(p.isOn); XCTAssertNil(p.nextDeadline(after: at(20)))
        XCTAssertNil(p.userActive(now: at(30)), "already off")
    }
    func testLocalInputDuringTheHoldOffReleasesAPendingDisarmOnce() {
        _ = p.update(running: [.claude], enabled: true, now: t0)
        p.requestDisarmOnce(true)
        _ = p.update(running: [], enabled: true, now: at(10))
        XCTAssertEqual(p.userActive(now: at(20)), .off(releaseManual: true))
    }

    // MARK: "Disarm once finished"

    func testDisarmOnceShortensTheHoldOffAndReleasesTheManualArm() {
        _ = p.update(running: [.claude], enabled: true, now: t0)
        p.requestDisarmOnce(true); XCTAssertTrue(p.disarmOnce)
        _ = p.update(running: [], enabled: true, now: at(100))
        XCTAssertEqual(p.nextDeadline(after: at(100)), at(160), "one minute, not Claude's half hour")
        XCTAssertEqual(p.tick(now: at(160)), .off(releaseManual: true))
        XCTAssertFalse(p.disarmOnce, "spent")
    }
    func testDisarmOnceDuringAnIdleCountdownShortensIt() {
        _ = p.update(running: [.claude], enabled: true, now: t0)
        _ = p.update(running: [], enabled: true, now: at(100))
        XCTAssertEqual(p.nextDeadline(after: at(100)), at(1900))
        p.requestDisarmOnce(true)                               // clicked right after the finish: idle time already counts
        XCTAssertEqual(p.nextDeadline(after: at(110)), at(160))
        p.requestDisarmOnce(false); p.requestDisarmOnce(true)
        XCTAssertNil(p.nextDeadline(after: at(400)), "idle for longer than the short hold-off: due now")
        XCTAssertEqual(p.tick(now: at(400)), .off(releaseManual: true))
    }
    func testDisarmOnceWithNothingRunningWaitsForTheNextWork() {
        p.requestDisarmOnce(true)
        XCTAssertNil(p.nextDeadline(after: t0)); XCTAssertNil(p.tick(now: at(1000)))
        XCTAssertEqual(p.update(running: [.terminal], enabled: true, now: at(1000)), .on)
        _ = p.update(running: [], enabled: true, now: at(1010))
        XCTAssertEqual(p.tick(now: at(1070)), .off(releaseManual: true))
    }
    func testDisarmOnceSurvivesAResumeInsideItsHoldOff() {
        p.requestDisarmOnce(true)
        _ = p.update(running: [.claude], enabled: true, now: at(1))
        _ = p.update(running: [], enabled: true, now: at(10))
        _ = p.update(running: [.claude], enabled: true, now: at(30))   // Claude picked the turn back up
        XCTAssertNil(p.nextDeadline(after: at(30))); XCTAssertTrue(p.disarmOnce, "still pending")
        _ = p.update(running: [], enabled: true, now: at(40))
        XCTAssertEqual(p.tick(now: at(100)), .off(releaseManual: true))
    }
    func testCancellingRestoresTheFullHoldOff() {
        _ = p.update(running: [.claude], enabled: true, now: t0)
        _ = p.update(running: [], enabled: true, now: at(100))
        p.requestDisarmOnce(true); XCTAssertEqual(p.nextDeadline(after: at(110)), at(160))
        p.requestDisarmOnce(false); XCTAssertEqual(p.nextDeadline(after: at(120)), at(1900), "back to the full hold-off")
        XCTAssertEqual(p.tick(now: at(1900)), .off(releaseManual: false))
    }
    func testARailClearsAPendingRequest() {
        p.requestDisarmOnce(true)
        p.suspend()
        XCTAssertFalse(p.disarmOnce)
    }
}
