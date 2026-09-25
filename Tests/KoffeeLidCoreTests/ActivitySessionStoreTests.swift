import XCTest
import KoffeeLidCore

final class ActivitySessionStoreTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    var store = ActivitySessionStore()

    func ev(_ name: ActivityEventName, _ sid: String = "s1", at dt: TimeInterval = 0, tool: String? = nil, agent: String? = nil,
            notif: String? = nil, source: String? = nil, bg: [String]? = nil, pid: Int32? = 100, by: ActivityAgent? = nil, turn: String? = nil) -> ActivityEvent {
        var e = ActivityEvent(loggedAt: t0.addingTimeInterval(dt), event: name)
        e.sessionId = sid; e.toolName = tool; e.agentId = agent; e.notificationType = notif; e.source = source
        e.backgroundTaskIds = bg; e.agentPid = pid; e.agent = by; e.turnId = turn
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

    // MARK: Turn identity

    func testALatePostToolUseOfAnAbortedCodexTurnDoesNotReopenIt() {
        store.apply(ev(.userPromptSubmit, "c1", pid: 300, by: .codex, turn: "t1"))
        store.apply(ev(.preToolUse, "c1", at: 1, tool: "Bash", pid: 300, by: .codex, turn: "t1"))
        store.apply(ev(.interrupt, "c1", at: 10, pid: 300, by: .codex, turn: "t1"))
        XCTAssertEqual(state("c1"), .done); XCTAssertFalse(store.isRunning)
        store.apply(ev(.postToolUse, "c1", at: 23, tool: "Bash", pid: 300, by: .codex, turn: "t1"))
        XCTAssertEqual(state("c1"), .done, "the end of the tool Codex aborted does not reopen the turn"); XCTAssertFalse(store.isRunning)
        XCTAssertEqual(store.sessions["c1"]?.lastEventAt, t0.addingTimeInterval(23), "the hook is alive")
    }
    func testAToolEventOfAClosedTurnRefreshesLivenessOnly() {
        store.apply(ev(.userPromptSubmit, "c1", pid: 300, by: .codex, turn: "t1"))
        store.apply(ev(.interrupt, "c1", at: 5, pid: 300, by: .codex, turn: "t1")); XCTAssertEqual(state("c1"), .done)
        store.apply(ev(.postToolUse, "c1", at: 30, tool: "Bash", pid: 300, by: .codex, turn: "t1"))
        XCTAssertEqual(state("c1"), .done)
        XCTAssertEqual(store.sessions["c1"]?.lastEventAt, t0.addingTimeInterval(30))
        XCTAssertEqual(store.sessions["c1"]?.lastMainEventAt, t0.addingTimeInterval(5), "the turn's quiet keeps counting from its Interrupt")
        XCTAssertEqual(store.sessions["c1"]?.closedTurnIds, ["t1"])
    }
    func testALateToolEventAfterAStopStillCountsBecauseAStopHookMayBlockIt() {
        store.apply(ev(.userPromptSubmit, turn: "t1")); store.apply(ev(.stop, at: 5, turn: "t1")); XCTAssertEqual(state(), .done)
        XCTAssertEqual(store.sessions["s1"]?.closedTurnIds, [], "a Stop ends the turn without closing it")
        store.apply(ev(.postToolUse, at: 6, tool: "Bash", turn: "t1")); XCTAssertEqual(state(), .working)
    }
    func testAnInterruptClosesTheTurnEvenWhenNoPromptWasSeen() {
        store.apply(ev(.preToolUse, "c1", tool: "Bash", pid: 300, by: .codex, turn: "t1")); XCTAssertEqual(state("c1"), .working)
        store.apply(ev(.interrupt, "c1", at: 1, pid: 300, by: .codex, turn: "t1")); XCTAssertEqual(state("c1"), .done)
        store.apply(ev(.postToolUse, "c1", at: 14, tool: "Bash", pid: 300, by: .codex, turn: "t1")); XCTAssertEqual(state("c1"), .done)
        XCTAssertEqual(store.sessions["c1"]?.closedTurnIds, ["t1"])
    }
    func testANewPromptOpensANewTurnAfterAnInterrupt() {
        store.apply(ev(.userPromptSubmit, "c1", pid: 300, by: .codex, turn: "t1"))
        store.apply(ev(.interrupt, "c1", at: 1, pid: 300, by: .codex, turn: "t1")); XCTAssertEqual(state("c1"), .done)
        store.apply(ev(.userPromptSubmit, "c1", at: 2, pid: 300, by: .codex, turn: "t2")); XCTAssertEqual(state("c1"), .working)
        XCTAssertEqual(store.sessions["c1"]?.lastMainTurnId, "t2")
        XCTAssertNil(store.sessions["c1"]?.interruptedAt)
        store.apply(ev(.preToolUse, "c1", at: 3, tool: "Bash", pid: 300, by: .codex, turn: "t2")); XCTAssertEqual(state("c1"), .working)
    }
    func testAPromptOpensATurnWhateverIdItCarries() {
        store.apply(ev(.userPromptSubmit, "c1", pid: 300, by: .codex, turn: "t1")); store.apply(ev(.interrupt, "c1", at: 1, pid: 300, by: .codex, turn: "t1"))
        store.apply(ev(.userPromptSubmit, "c1", at: 2, pid: 300, by: .codex, turn: "t1")); XCTAssertEqual(state("c1"), .working, "a prompt always opens a turn")
        XCTAssertEqual(store.sessions["c1"]?.closedTurnIds, [], "the reopened id is no longer closed")
        store.apply(ev(.stop, "c1", at: 3, pid: 300, by: .codex, turn: "t1")); XCTAssertEqual(state("c1"), .done)
        store.apply(ev(.postToolUse, "c1", at: 4, tool: "Bash", pid: 300, by: .codex, turn: "t1")); XCTAssertEqual(state("c1"), .working, "the reopened turn's work counts")
        store.apply(ev(.interrupt, "c1", at: 5, pid: 300, by: .codex, turn: "t1")); XCTAssertEqual(state("c1"), .done, "and its Interrupt ends it")
    }
    func testAHelperEventOfAnInterruptedTurnIsIgnored() {
        store.apply(ev(.userPromptSubmit, "c1", pid: 300, by: .codex, turn: "t1"))
        store.apply(ev(.interrupt, "c1", at: 1, pid: 300, by: .codex, turn: "t1"))
        store.apply(ev(.preToolUse, "c1", at: 2, tool: "Bash", agent: "h1", pid: 300, by: .codex, turn: "t1"))
        XCTAssertEqual(state("c1"), .done, "the interrupt ended the helpers"); XCTAssertTrue(store.sessions["c1"]!.liveAgents.isEmpty)
        XCTAssertEqual(store.sessions["c1"]?.lastEventAt, t0.addingTimeInterval(2))
    }
    func testAHelperOfAStoppedTurnStillHoldsIt() {
        store.apply(ev(.userPromptSubmit, "c1", pid: 300, by: .codex, turn: "t1"))
        store.apply(ev(.subagentStart, "c1", at: 1, agent: "h1", pid: 300, by: .codex, turn: "t1"))
        store.apply(ev(.stop, "c1", at: 2, pid: 300, by: .codex, turn: "t1"))
        XCTAssertEqual(state("c1"), .working, "held behind the helper"); XCTAssertTrue(store.sessions["c1"]!.pendingDone)
        store.apply(ev(.postToolUse, "c1", at: 3, tool: "Bash", agent: "h1", pid: 300, by: .codex, turn: "t1"))
        XCTAssertEqual(state("c1"), .working); XCTAssertTrue(store.sessions["c1"]!.pendingDone)
        XCTAssertEqual(store.sessions["c1"]?.liveAgents["h1"], t0.addingTimeInterval(3), "the helper's report still counts")
    }
    func testARegistryVerdictClosesTheTurn() {
        store.apply(ev(.userPromptSubmit, turn: "p1")); store.apply(ev(.preToolUse, at: 1, tool: "Bash", turn: "p1"))
        store.turnOver(sessionId: "s1", now: t0.addingTimeInterval(30)); XCTAssertEqual(state(), .done)
        store.apply(ev(.postToolUse, at: 31, tool: "Bash", turn: "p1")); XCTAssertEqual(state(), .done)
    }
    func testTheLostStopRescueEndsTheTurnWithoutClosingIt() {
        store.apply(ev(.userPromptSubmit, turn: "p1"))
        store.apply(ev(.notification, at: 60, notif: "idle_prompt", turn: "p1")); XCTAssertEqual(state(), .done)
        store.apply(ev(.postToolUse, at: 61, tool: "Bash", turn: "p1")); XCTAssertEqual(state(), .working, "a timer, not proof: the turn's own work still counts")
    }
    func testOnlyTheLastEightClosedTurnsAreKept() {
        for i in 0..<10 {
            store.apply(ev(.userPromptSubmit, "c1", at: Double(2 * i), pid: 300, by: .codex, turn: "t\(i)"))
            store.apply(ev(.interrupt, "c1", at: Double(2 * i + 1), pid: 300, by: .codex, turn: "t\(i)"))
        }
        XCTAssertEqual(store.sessions["c1"]?.closedTurnIds, (2..<10).map { "t\($0)" })
    }
    func testAHelperEventAfterAVerdictCloseIsIgnored() {
        store.apply(ev(.userPromptSubmit, turn: "p1")); store.apply(ev(.preToolUse, at: 1, tool: "Bash", turn: "p1"))
        store.turnOver(sessionId: "s1", now: t0.addingTimeInterval(30)); XCTAssertEqual(state(), .done)
        store.apply(ev(.preToolUse, at: 31, tool: "Bash", agent: "h1", turn: "p1"))
        XCTAssertEqual(state(), .done); XCTAssertTrue(store.sessions["s1"]!.liveAgents.isEmpty); XCTAssertFalse(store.sessions["s1"]!.pendingDone)
    }
    func testAStopOrANotificationOfAClosedTurnIsIgnored() {
        store.apply(ev(.userPromptSubmit, turn: "p1")); store.turnOver(sessionId: "s1", now: t0.addingTimeInterval(30))
        store.apply(ev(.notification, at: 31, notif: "permission_prompt", turn: "p1")); XCTAssertEqual(state(), .done, "not waiting: the dialog belongs to a closed turn")
        store.apply(ev(.stop, at: 32, bg: ["b1"], turn: "p1")); XCTAssertEqual(state(), .done, "not held behind its background shell")
        XCTAssertTrue(store.sessions["s1"]!.backgroundIds.isEmpty); XCTAssertEqual(store.sessions["s1"]?.lastMainEventAt, t0)
    }
    func testANewTurnIdInsideTheQuarantineStillCounts() {
        store.apply(ev(.userPromptSubmit, "c1", pid: 300, by: .codex, turn: "t1"))
        store.apply(ev(.interrupt, "c1", at: 10, pid: 300, by: .codex, turn: "t1")); XCTAssertEqual(state("c1"), .done)
        store.apply(ev(.postToolUse, "c1", at: 20, tool: "Bash", pid: 300, by: .codex, turn: "t2")); XCTAssertEqual(state("c1"), .working, "the quarantine covers lines without an id only")
        store.apply(ev(.interrupt, "c1", at: 21, pid: 300, by: .codex, turn: "t2")); XCTAssertEqual(store.sessions["c1"]?.closedTurnIds, ["t1", "t2"])
    }
    func testToolEventsWithoutAnIdInTheQuarantineAfterAnInterruptChangeNothing() {
        store.apply(ev(.userPromptSubmit, "c1", pid: 300, by: .codex))
        store.apply(ev(.interrupt, "c1", at: 10, pid: 300, by: .codex)); XCTAssertEqual(state("c1"), .done)
        XCTAssertEqual(store.sessions["c1"]?.interruptedAt, t0.addingTimeInterval(10))
        store.apply(ev(.postToolUse, "c1", at: 70, tool: "Bash", pid: 300, by: .codex)); XCTAssertEqual(state("c1"), .done)
        store.apply(ev(.permissionRequest, "c1", at: 71, tool: "Bash", pid: 300, by: .codex)); XCTAssertEqual(state("c1"), .done)
        XCTAssertEqual(store.sessions["c1"]?.lastEventAt, t0.addingTimeInterval(71))
        store.apply(ev(.postToolUse, "c1", at: 131, tool: "Bash", pid: 300, by: .codex)); XCTAssertEqual(state("c1"), .working, "past 120 s the line counts again")
    }
    func testLinesWithoutATurnIdKeepTodaysRules() {
        store.apply(ev(.userPromptSubmit, turn: nil))
        store.apply(ev(.preToolUse, at: 1, tool: "Bash", turn: nil)); XCTAssertEqual(state(), .working)
        store.apply(ev(.preToolUse, at: 2, tool: "AskUserQuestion", turn: nil)); XCTAssertEqual(state(), .waiting); XCTAssertFalse(store.isRunning)
        store.apply(ev(.postToolUse, at: 3, tool: "AskUserQuestion", turn: nil)); XCTAssertEqual(state(), .working)
        store.apply(ev(.preToolUse, at: 4, tool: "ExitPlanMode", turn: nil)); XCTAssertEqual(state(), .waiting)
        store.apply(ev(.permissionDenied, at: 5, turn: nil)); XCTAssertEqual(state(), .working)
        store.apply(ev(.permissionRequest, at: 6, tool: "Bash", turn: nil)); XCTAssertEqual(state(), .waiting)
        store.apply(ev(.postToolUseFailure, at: 7, turn: nil)); XCTAssertEqual(state(), .working)
        store.apply(ev(.stop, at: 8, turn: nil)); XCTAssertEqual(state(), .done)
        store.apply(ev(.postToolUse, at: 9, tool: "Bash", turn: nil)); XCTAssertEqual(state(), .working, "a Stop closes nothing")
    }
}
