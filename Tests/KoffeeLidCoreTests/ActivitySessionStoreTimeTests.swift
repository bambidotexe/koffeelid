import XCTest
import KoffeeLidCore

final class ActivitySessionStoreTimeTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    var store = ActivitySessionStore()
    func at(_ dt: TimeInterval) -> Date { t0.addingTimeInterval(dt) }
    func ev(_ name: ActivityEventName, at dt: TimeInterval = 0, agent: String? = nil, bg: [String]? = nil) -> ActivityEvent {
        var e = ActivityEvent(loggedAt: at(dt), event: name); e.sessionId = "s1"; e.agentId = agent; e.backgroundTaskIds = bg; e.agentPid = 100; return e
    }
    var state: ActivitySessionState? { store.sessions["s1"]?.state }

    func testHelperSilenceReleasesTheHoldThenGraceMakesItDone() {
        store.apply(ev(.userPromptSubmit)); store.apply(ev(.subagentStart, at: 1, agent: "a1")); store.apply(ev(.stop, at: 2))
        XCTAssertEqual(state, .working)
        store.tick(now: at(1 + 239)); XCTAssertEqual(state, .working, "helper still counts as live")
        store.tick(now: at(1 + 240)); XCTAssertEqual(state, .working, "released (dated to this tick), but inside the 90 s grace")
        XCTAssertEqual(store.nextDeadline(after: at(1 + 240)), at(1 + 240 + 90))
        store.tick(now: at(1 + 240 + 90)); XCTAssertEqual(state, .done); XCTAssertFalse(store.isRunning)
    }
    func testANewHelperReengagesTheHold() {
        store.apply(ev(.userPromptSubmit)); store.apply(ev(.stop, at: 1, bg: ["b1"]))
        store.apply(ev(.postToolUse, at: 2, bg: []))            // main-agent event clears pending: back to plain working
        XCTAssertEqual(state, .working); XCTAssertFalse(store.sessions["s1"]!.pendingDone)
        store.apply(ev(.stop, at: 3, agent: "a1"))               // a helper Stop arrives with no background left: stamped live
        store.apply(ev(.stop, at: 4)); XCTAssertTrue(store.sessions["s1"]!.pendingDone)
        store.tick(now: at(3 + 240)); XCTAssertEqual(state, .working, "helper silent: release dated to this tick")
        store.tick(now: at(3 + 240 + 89)); XCTAssertEqual(state, .working)
        store.tick(now: at(3 + 240 + 90)); XCTAssertEqual(state, .done)
    }
    func testHoldTTLEndsAHeldTurnWithNoEvents() {
        store.apply(ev(.userPromptSubmit)); store.apply(ev(.stop, at: 1, bg: ["b1"]))
        store.tick(now: at(1 + 1799)); XCTAssertEqual(state, .working)
        store.tick(now: at(1 + 1800)); XCTAssertEqual(state, .done)
    }
    func testDoneBecomesIdleAndStaleSessionsVanish() {
        store.apply(ev(.userPromptSubmit)); store.apply(ev(.stop, at: 1))
        store.tick(now: at(1 + 1200)); XCTAssertEqual(state, .idle)
        store.tick(now: at(1 + 7199)); XCTAssertNotNil(store.sessions["s1"])
        store.tick(now: at(1 + 7200)); XCTAssertNil(store.sessions["s1"])
    }
    func testAbandonCandidatesNeedTwentyQuietSecondsAndNoHelpers() {
        store.apply(ev(.userPromptSubmit))
        XCTAssertTrue(store.abandonCandidates(at: at(19)).isEmpty)
        XCTAssertEqual(store.abandonCandidates(at: at(20)).map(\.sessionId), ["s1"])
        XCTAssertEqual(store.abandonCandidates(at: at(20)).map(\.pid), [100])
        store.apply(ev(.subagentStart, at: 21, agent: "a1"))
        XCTAssertTrue(store.abandonCandidates(at: at(60)).isEmpty, "a live helper is not quiet")
        var e = ev(.userPromptSubmit, at: 0); e.sessionId = "nopid"; e.agentPid = nil; store.apply(e)
        XCTAssertFalse(store.abandonCandidates(at: at(100)).contains { $0.sessionId == "nopid" })
    }
    func testTurnOverIsDoneAndNoteBusyExtendsLiveness() {
        store.apply(ev(.userPromptSubmit))
        store.noteBusy(sessionId: "s1", now: at(30))
        XCTAssertTrue(store.abandonCandidates(at: at(40)).isEmpty, "busy re-arms the quiet gate")
        XCTAssertEqual(store.sessions["s1"]?.lastMainEventAt, t0, "hook silence is still measured from the last real event")
        store.tick(now: at(30 + 7199)); XCTAssertNotNil(store.sessions["s1"], "busy keeps a session alive past the original staleness")
        store.finishTurn(sessionId: "s1", endedAt: at(60), now: at(60)); XCTAssertEqual(state, .done)
        store.finishTurn(sessionId: "s1", endedAt: at(61), now: at(61)); XCTAssertEqual(state, .done, "idempotent, only acts on working")
    }
    /// A busy verdict is dated to the source's own last write, never to the moment it was checked: a rollout or
    /// an `events.jsonl` that stopped changing goes stale from its own last line, not from every recheck.
    func testABusyRolloutKeepsTheSessionAliveFromItsLastLine() {
        store.apply(ev(.userPromptSubmit))
        store.noteBusy(sessionId: "s1", now: at(600))
        XCTAssertEqual(store.sessions["s1"]?.lastEventAt, at(600))
        XCTAssertEqual(store.sessions["s1"]?.lastMainEventAt, t0, "hook silence is still measured")
        store.noteBusy(sessionId: "s1", now: at(300))
        XCTAssertEqual(store.sessions["s1"]?.lastEventAt, at(600), "liveness never moves backwards")
        store.tick(now: at(600 + ActivityConstants.staleSeconds))
        XCTAssertNil(store.sessions["s1"], "forgotten 2 h after the source's last write")
    }
    func testOpenWaitsCanBeAnsweredWithoutAHook() {
        store.apply(ev(.userPromptSubmit)); var p = ev(.permissionRequest, at: 5); p.toolName = "Bash"; store.apply(p)
        let waits = store.openWaitCandidates()
        XCTAssertEqual(waits.map(\.sessionId), ["s1"]); XCTAssertEqual(waits.first?.stateSince, at(5))
        store.dialogAnswered(sessionId: "s1", now: at(20)); XCTAssertEqual(state, .working)
        XCTAssertTrue(store.openWaitCandidates().isEmpty)
    }
    func testNextDeadlineCoversQuietWatchAndStaleness() {
        store.apply(ev(.userPromptSubmit))
        XCTAssertEqual(store.nextDeadline(after: at(1)), at(20), "first registry check when the quiet gate opens")
        XCTAssertEqual(store.nextDeadline(after: at(25)), at(25 + 15), "then on the recheck cadence")
        store.apply(ev(.stop, at: 30))
        XCTAssertEqual(store.nextDeadline(after: at(31)), at(30 + 1200), "done → idle")
        XCTAssertNil(ActivitySessionStore().nextDeadline(after: t0))
    }
}
