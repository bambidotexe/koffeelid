import XCTest
import KoffeeLidCore

final class ActivitySessionStoreTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    var store = ActivitySessionStore()

    func ev(_ name: ActivityEventName, _ sid: String = "s1", at dt: TimeInterval = 0, tool: String? = nil, agent: String? = nil,
            notif: String? = nil, source: String? = nil, bg: [String]? = nil, pid: Int32? = 100, by: ActivityAgent? = nil) -> ActivityEvent {
        var e = ActivityEvent(loggedAt: t0.addingTimeInterval(dt), event: name)
        e.sessionId = sid; e.toolName = tool; e.agentId = agent; e.notificationType = notif; e.source = source
        e.backgroundTaskIds = bg; e.agentPid = pid; e.agent = by
        return e
    }
    func state(_ sid: String = "s1") -> ActivitySessionState? { store.sessions[sid]?.state }

    func testStartIsIdleAndPromptIsWorking() {
        store.apply(ev(.sessionStart, source: "startup")); XCTAssertEqual(state(), .idle); XCTAssertFalse(store.isRunning)
        store.apply(ev(.userPromptSubmit, at: 1)); XCTAssertEqual(state(), .working); XCTAssertTrue(store.isRunning)
        XCTAssertEqual(store.sessions["s1"]?.agentPid, 100); XCTAssertEqual(store.sessions["s1"]?.agent, .claude)
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
        store.pruneDead { pid, _ in pid == 100 }
        XCTAssertEqual(Set(store.sessions.keys), ["s1", "s3"]); XCTAssertEqual(store.trackedPids, [100])
    }

    // MARK: Codex

    func testACodexSessionCountsLikeAClaudeOneAndIsToldApart() {
        store.apply(ev(.sessionStart, "c1", source: "startup", pid: 300, by: .codex)); XCTAssertEqual(state("c1"), .idle)
        store.apply(ev(.userPromptSubmit, "c1", at: 1, pid: 300, by: .codex)); XCTAssertEqual(state("c1"), .working)
        store.apply(ev(.userPromptSubmit, at: 2))
        XCTAssertEqual(store.workingCount, 2); XCTAssertEqual(store.workingCount(of: .codex), 1); XCTAssertEqual(store.workingCount(of: .claude), 1)
        XCTAssertEqual(store.sessions["c1"]?.agent, .codex); XCTAssertEqual(store.trackedPids, [100, 300])
        store.apply(ev(.stop, "c1", at: 3, pid: 300, by: .codex)); XCTAssertEqual(state("c1"), .done); XCTAssertEqual(store.workingCount(of: .codex), 0)
        store.apply(ev(.sessionEnd, "c1", at: 4, pid: 300, by: .codex)); XCTAssertNil(store.sessions["c1"])
    }
    func testInterruptEndsACodexTurnAndItsHelpersAtOnce() {
        store.apply(ev(.userPromptSubmit, "c1", pid: 300, by: .codex))
        store.apply(ev(.subagentStart, "c1", at: 1, agent: "a1", pid: 300, by: .codex))
        store.apply(ev(.interrupt, "c1", at: 2, pid: 300, by: .codex))
        XCTAssertEqual(state("c1"), .done); XCTAssertFalse(store.isRunning)
        XCTAssertTrue(store.sessions["c1"]!.liveAgents.isEmpty); XCTAssertFalse(store.sessions["c1"]!.pendingDone)
        store.apply(ev(.stop, "c1", at: 3, pid: 300, by: .codex)); XCTAssertEqual(state("c1"), .done, "a Stop after the Interrupt changes nothing")
        store.apply(ev(.interrupt, at: 4)); XCTAssertNil(state(), "Claude Code has no Interrupt: the line is ignored")
    }
    func testCodexsQuestionToTheUserIsWaiting() {
        store.apply(ev(.userPromptSubmit, "c1", pid: 300, by: .codex))
        store.apply(ev(.preToolUse, "c1", at: 1, tool: "request_user_input", pid: 300, by: .codex)); XCTAssertEqual(state("c1"), .waiting)
        store.apply(ev(.postToolUse, "c1", at: 2, tool: "request_user_input", pid: 300, by: .codex)); XCTAssertEqual(state("c1"), .working)
        store.apply(ev(.permissionRequest, "c1", at: 3, tool: "shell", pid: 300, by: .codex)); XCTAssertEqual(state("c1"), .waiting)
        store.apply(ev(.preToolUse, "c1", at: 4, tool: "shell", pid: 300, by: .codex)); XCTAssertEqual(state("c1"), .working)
    }
    func testTheRegistryRescuesAreClaudeCodesAlone() {
        store.apply(ev(.userPromptSubmit, "c1", pid: 300, by: .codex)); store.apply(ev(.userPromptSubmit))
        let quiet = t0.addingTimeInterval(ActivityConstants.abandonQuietSeconds + 1)
        XCTAssertEqual(store.abandonCandidates(at: quiet).map(\.sessionId), ["s1"])
        store.apply(ev(.permissionRequest, "c1", at: 1, pid: 300, by: .codex)); store.apply(ev(.permissionRequest, at: 1))
        XCTAssertEqual(store.openWaitCandidates().map(\.sessionId), ["s1"])
        var codexOnly = ActivitySessionStore()
        codexOnly.apply(ev(.userPromptSubmit, "c1", pid: 300, by: .codex))
        XCTAssertEqual(codexOnly.nextDeadline(after: t0), t0.addingTimeInterval(ActivityConstants.staleSeconds), "no recheck timer for a session with no registry")
    }
    func testPruneAsksAboutEachSessionsOwnAgent() {
        store.apply(ev(.userPromptSubmit)); store.apply(ev(.userPromptSubmit, "c1", pid: 300, by: .codex))
        var asked: [ActivityAgent] = []
        store.pruneDead { _, agent in asked.append(agent); return agent == .codex }
        XCTAssertEqual(Set(asked), [.claude, .codex]); XCTAssertEqual(Set(store.sessions.keys), ["c1"])
    }
}
