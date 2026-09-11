import XCTest
import KoffeeLidCore

final class ActivitySessionStoreTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    var store = ActivitySessionStore()

    func ev(_ name: ActivityEventName, _ sid: String = "s1", at dt: TimeInterval = 0, tool: String? = nil, agent: String? = nil,
            notif: String? = nil, source: String? = nil, bg: [String]? = nil, pid: Int32? = 100) -> ActivityEvent {
        var e = ActivityEvent(loggedAt: t0.addingTimeInterval(dt), event: name)
        e.sessionId = sid; e.toolName = tool; e.agentId = agent; e.notificationType = notif; e.source = source
        e.backgroundTaskIds = bg; e.claudePid = pid
        return e
    }
    func state(_ sid: String = "s1") -> ActivitySessionState? { store.sessions[sid]?.state }

    func testStartIsIdleAndPromptIsWorking() {
        store.apply(ev(.sessionStart, source: "startup")); XCTAssertEqual(state(), .idle); XCTAssertFalse(store.isRunning)
        store.apply(ev(.userPromptSubmit, at: 1)); XCTAssertEqual(state(), .working); XCTAssertTrue(store.isRunning)
        XCTAssertEqual(store.sessions["s1"]?.claudePid, 100)
    }
    func testCompactionIsWorking() {
        store.apply(ev(.sessionStart, source: "compact")); XCTAssertEqual(state(), .working)
        store.apply(ev(.preCompact, at: 1)); XCTAssertEqual(state(), .working)
        store.apply(ev(.postCompact, at: 2)); XCTAssertEqual(state(), .working)
    }
    func testToolTrafficIsWorkingAndDialogsAreWaiting() {
        store.apply(ev(.userPromptSubmit))
        store.apply(ev(.preToolUse, at: 1, tool: "Bash")); XCTAssertEqual(state(), .working)
        store.apply(ev(.preToolUse, at: 2, tool: "AskUserQuestion")); XCTAssertEqual(state(), .waiting); XCTAssertFalse(store.isRunning)
        store.apply(ev(.postToolUse, at: 3, tool: "AskUserQuestion")); XCTAssertEqual(state(), .working)
        store.apply(ev(.preToolUse, at: 4, tool: "ExitPlanMode")); XCTAssertEqual(state(), .waiting)
        store.apply(ev(.permissionDenied, at: 5)); XCTAssertEqual(state(), .working)
        store.apply(ev(.permissionRequest, at: 6, tool: "Bash")); XCTAssertEqual(state(), .waiting)
        store.apply(ev(.postToolUseFailure, at: 7)); XCTAssertEqual(state(), .working)
    }
    func testNotificationDialogsAreWaitingButEchoesKeepTheState() {
        store.apply(ev(.userPromptSubmit))
        store.apply(ev(.notification, at: 1, notif: "permission_prompt")); XCTAssertEqual(state(), .waiting)
        store.apply(ev(.preToolUse, at: 2, tool: "Bash")); XCTAssertEqual(state(), .working)
        store.apply(ev(.notification, at: 3, notif: "auth_success")); XCTAssertEqual(state(), .working)
        store.apply(ev(.notification, at: 4, notif: "idle_prompt")); XCTAssertEqual(state(), .working, "too fresh: a glitch, not a lost Stop")
        store.apply(ev(.notification, at: 4 + 50, notif: "idle_prompt")); XCTAssertEqual(state(), .done, "quiet for 50 s: the lost-Stop rescue")
    }
    func testStopIsDoneAndStopFailureIsWaiting() {
        store.apply(ev(.userPromptSubmit)); store.apply(ev(.stop, at: 1)); XCTAssertEqual(state(), .done); XCTAssertFalse(store.isRunning)
        store.apply(ev(.userPromptSubmit, at: 2)); store.apply(ev(.stopFailure, at: 3)); XCTAssertEqual(state(), .waiting)
    }
    func testSessionEndAndProcessExitRemove() {
        store.apply(ev(.userPromptSubmit)); store.apply(ev(.userPromptSubmit, "s2", pid: 200))
        store.apply(ev(.sessionEnd, at: 1)); XCTAssertNil(store.sessions["s1"]); XCTAssertTrue(store.isRunning)
        store.processExited(pid: 200); XCTAssertTrue(store.sessions.isEmpty); XCTAssertFalse(store.isRunning)
    }
    func testTwoSessionsOneFinishingKeepsRunning() {
        store.apply(ev(.userPromptSubmit)); store.apply(ev(.userPromptSubmit, "s2", pid: 200))
        store.apply(ev(.stop, at: 1)); XCTAssertTrue(store.isRunning); XCTAssertEqual(store.workingCount, 1)
        store.apply(ev(.stop, "s2", at: 2, pid: 200)); XCTAssertFalse(store.isRunning)
    }
    func testStopWithHelpersOrBackgroundShellsIsHeld() {
        store.apply(ev(.userPromptSubmit))
        store.apply(ev(.subagentStart, at: 1, agent: "a1"))
        store.apply(ev(.stop, at: 2)); XCTAssertEqual(state(), .working, "held behind a live helper"); XCTAssertTrue(store.sessions["s1"]!.pendingDone)
        store.apply(ev(.subagentStop, at: 3, agent: "a1")); XCTAssertEqual(state(), .working, "release starts a 90 s grace, not an instant done")
        store = ActivitySessionStore()
        store.apply(ev(.userPromptSubmit)); store.apply(ev(.stop, at: 1, bg: ["b1"])); XCTAssertEqual(state(), .working)
        store.apply(ev(.stop, at: 2, bg: [])); XCTAssertEqual(state(), .done, "an empty snapshot on a Stop is a plain finish")
    }
    func testPromptDoesNotClearHelpersButStartupDoes() {
        store.apply(ev(.userPromptSubmit)); store.apply(ev(.subagentStart, at: 1, agent: "a1"))
        store.apply(ev(.userPromptSubmit, at: 2)); store.apply(ev(.stop, at: 3)); XCTAssertEqual(state(), .working, "helper survives the prompt")
        store.apply(ev(.sessionStart, at: 4, source: "startup")); store.apply(ev(.userPromptSubmit, at: 5)); store.apply(ev(.stop, at: 6))
        XCTAssertEqual(state(), .done, "a process boundary clears helpers")
    }
    func testHelperEventsReopenDoneAndAnswerAgentPermission() {
        store.apply(ev(.userPromptSubmit)); store.apply(ev(.stop, at: 1)); XCTAssertEqual(state(), .done)
        store.apply(ev(.preToolUse, at: 2, tool: "Bash", agent: "a1")); XCTAssertEqual(state(), .working); XCTAssertTrue(store.sessions["s1"]!.pendingDone)
        store.apply(ev(.permissionRequest, at: 3, tool: "Bash", agent: "a1")); XCTAssertEqual(state(), .waiting)
        store.apply(ev(.postToolUse, at: 4, tool: "Bash", agent: "a1")); XCTAssertEqual(state(), .working, "the helper acting again answers its own prompt")
    }
    func testHelperBackgroundSnapshotDoesNotRewriteTheParents() {
        store.apply(ev(.userPromptSubmit))
        store.apply(ev(.postToolUse, at: 1, tool: "Bash", agent: "a1", bg: ["from-helper"]))
        XCTAssertTrue(store.sessions["s1"]!.backgroundIds.isEmpty)
    }
    func testParseErrorAndMissingSessionAreIgnored() {
        store.apply(ev(.parseError)); var e = ev(.stop); e.sessionId = nil; store.apply(e)
        XCTAssertTrue(store.sessions.isEmpty)
    }
    func testPruneDeadDropsOnlyDeadPids() {
        store.apply(ev(.userPromptSubmit)); store.apply(ev(.userPromptSubmit, "s2", pid: 200)); store.apply(ev(.userPromptSubmit, "s3", pid: nil))
        store.pruneDead(isAlive: { $0 == 100 })
        XCTAssertEqual(Set(store.sessions.keys), ["s1", "s3"]); XCTAssertEqual(store.trackedPids, [100])
    }
}
