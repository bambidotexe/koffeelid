import XCTest
import KoffeeLidCore

final class ActivitySessionStoreTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    var store = ActivitySessionStore()

    func ev(_ name: ActivityEventName, _ sid: String = "s1", at dt: TimeInterval = 0, tool: String? = nil, agent: String? = nil,
            notif: String? = nil, source: String? = nil, bg: [String]? = nil, pid: Int32? = 100, by: ActivityAgent? = nil, turn: String? = nil, path: String? = nil) -> ActivityEvent {
        var e = ActivityEvent(loggedAt: t0.addingTimeInterval(dt), event: name)
        e.sessionId = sid; e.toolName = tool; e.agentId = agent; e.notificationType = notif; e.source = source
        e.backgroundTaskIds = bg; e.agentPid = pid; e.agent = by; e.turnId = turn; e.transcriptPath = path
        return e
    }
    func state(_ sid: String = "s1") -> ActivitySessionState? { store.sessions[sid]?.state }

    func testStartIsIdleAndPromptIsWorking() {
        store.apply(ev(.sessionStart, source: "startup")); XCTAssertEqual(state(), .idle); XCTAssertFalse(store.isRunning)
        store.apply(ev(.userPromptSubmit, at: 1)); XCTAssertEqual(state(), .working); XCTAssertTrue(store.isRunning)
        XCTAssertEqual(store.sessions["s1"]?.agentPid, 100); XCTAssertEqual(store.sessions["s1"]?.agent, .claude)
    }
    func testCompactionKeepsTheStateItFound() {
        // Idle at the prompt: working during, idle again after.
        store.apply(ev(.sessionStart, source: "startup")); XCTAssertEqual(state(), .idle)
        store.apply(ev(.preCompact, at: 1)); XCTAssertEqual(state(), .working)
        store.apply(ev(.sessionStart, at: 2, source: "compact")); XCTAssertEqual(state(), .working)
        store.apply(ev(.postCompact, at: 3)); XCTAssertEqual(state(), .idle)

        // Done after a Stop: working during, done again after.
        store = ActivitySessionStore()
        store.apply(ev(.userPromptSubmit)); store.apply(ev(.stop, at: 1)); XCTAssertEqual(state(), .done)
        store.apply(ev(.preCompact, at: 2)); XCTAssertEqual(state(), .working)
        store.apply(ev(.sessionStart, at: 3, source: "compact")); XCTAssertEqual(state(), .working)
        store.apply(ev(.postCompact, at: 4)); XCTAssertEqual(state(), .done)

        // Mid-turn: working throughout.
        store = ActivitySessionStore()
        store.apply(ev(.userPromptSubmit)); XCTAssertEqual(state(), .working)
        store.apply(ev(.preCompact, at: 1)); XCTAssertEqual(state(), .working)
        store.apply(ev(.sessionStart, at: 2, source: "compact")); XCTAssertEqual(state(), .working)
        store.apply(ev(.postCompact, at: 3)); XCTAssertEqual(state(), .working)
    }
    func testAStaleCompactionSnapshotIsForgottenAtTheNextTurn() {
        // A mid-turn compaction whose PostCompact was lost, then the turn's Stop.
        store.apply(ev(.userPromptSubmit, turn: "p1")); store.apply(ev(.preCompact, at: 1, turn: "p1"))
        store.apply(ev(.stop, at: 2, turn: "p1")); XCTAssertEqual(state(), .done)
        store.apply(ev(.preCompact, at: 3)); XCTAssertEqual(state(), .working)
        store.apply(ev(.postCompact, at: 4)); XCTAssertEqual(state(), .done, "the state this compaction found, not the lost one's")

        // Each boundary forgets it: a prompt, an Interrupt, a SessionStart that is not a compaction's.
        for boundary in [ev(.userPromptSubmit, "c1", at: 12, by: .codex, turn: "t2"), ev(.interrupt, "c1", at: 12, by: .codex, turn: "t1"),
                         ev(.sessionStart, "c1", at: 12, source: "resume", by: .codex)] {
            store = ActivitySessionStore()
            store.apply(ev(.userPromptSubmit, "c1", at: 10, by: .codex, turn: "t1")); store.apply(ev(.preCompact, "c1", at: 11, by: .codex, turn: "t1"))
            store.apply(boundary)
            XCTAssertNil(store.sessions["c1"]?.stateBeforeCompaction, "\(boundary.event) is a turn boundary")
        }

        // Between two PreCompacts with no boundary, the first snapshot wins.
        store = ActivitySessionStore()
        store.apply(ev(.sessionStart, source: "startup")); XCTAssertEqual(state(), .idle)
        store.apply(ev(.preCompact, at: 1)); store.apply(ev(.preCompact, at: 2)); XCTAssertEqual(state(), .working)
        store.apply(ev(.postCompact, at: 3)); XCTAssertEqual(state(), .idle, "a second PreCompact does not snapshot the first one's working")
    }
    func testACompactSessionStartAloneChangesNothing() {
        store.apply(ev(.sessionStart, source: "startup")); XCTAssertEqual(state(), .idle)
        store.apply(ev(.sessionStart, at: 1, source: "compact")); XCTAssertEqual(state(), .idle)
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
        store.pruneDead(isAlive: { pid, _ in pid == 100 }, registrySession: { _ in nil })
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
        XCTAssertEqual(codexOnly.abandonCandidates(at: quiet).count, 0, "a Codex session is never asked about a registry")
    }
    func testAQuietCodexSessionIsACandidateAndAClaudeOneIsNot() {
        let rollout = "/Users/x/.codex/sessions/2026/09/25/rollout-2026-09-25T18-00-00-c1.jsonl"
        store.apply(ev(.sessionStart, "c1", source: "startup", pid: 300, by: .codex, path: rollout))
        store.apply(ev(.userPromptSubmit, "c1", pid: 300, by: .codex, turn: "t1", path: rollout))
        store.apply(ev(.postToolUse, "c1", tool: "exec_command", pid: 300, by: .codex, turn: "t1"))
        store.apply(ev(.userPromptSubmit))
        store.apply(ev(.userPromptSubmit, "c2", pid: nil, by: .codex))
        store.apply(ev(.userPromptSubmit, "c3", pid: 300, by: .codex)); store.apply(ev(.subagentStart, "c3", agent: "h1", pid: 300, by: .codex))
        store.apply(ev(.userPromptSubmit, "c4", pid: 300, by: .codex)); store.apply(ev(.postToolUse, "c4", bg: ["b1"], pid: 300, by: .codex))
        store.apply(ev(.userPromptSubmit, "c5", pid: 300, by: .codex)); store.apply(ev(.stop, "c5", pid: 300, by: .codex))
        func candidates(_ dt: TimeInterval, quiet: TimeInterval = ActivityConstants.abandonQuietSeconds) -> [String: String?] {
            Dictionary(uniqueKeysWithValues: store.codexCandidates(at: t0.addingTimeInterval(dt), quietSeconds: quiet).map { ($0.sessionId, $0.transcriptPath) })
        }
        XCTAssertTrue(candidates(19).isEmpty, "not quiet yet")
        XCTAssertEqual(candidates(20), ["c1": rollout, "c2": nil], "the path a later line left out stands; Claude Code, helpers, background shells and a finished turn are not asked")
        XCTAssertEqual(Set(candidates(0, quiet: 0).keys), ["c1", "c2"], "at launch there is no quiet gate")
        store.noteBusy(sessionId: "c1", now: t0.addingTimeInterval(20))
        XCTAssertFalse(candidates(30).keys.contains("c1"), "busy re-arms the quiet gate")
        XCTAssertEqual(store.sessions["c1"]?.lastMainEventAt, t0, "busy is liveness only")
        store.turnOver(sessionId: "c1", now: t0.addingTimeInterval(45))
        XCTAssertEqual(state("c1"), .done); XCTAssertEqual(store.sessions["c1"]?.closedTurnIds, ["t1"], "the rollout's verdict closes the turn")
        store.apply(ev(.postToolUse, "c1", at: 50, tool: "exec_command", pid: 300, by: .codex, turn: "t1")); XCTAssertEqual(state("c1"), .done)
    }
    func testNextDeadlineCoversTheCodexRecheck() {
        store.apply(ev(.userPromptSubmit, "c1", at: 1, pid: 300, by: .codex))
        XCTAssertEqual(store.nextDeadline(after: t0.addingTimeInterval(1)), t0.addingTimeInterval(1 + ActivityConstants.abandonQuietSeconds), "first rollout check when the quiet gate opens")
        XCTAssertEqual(store.nextDeadline(after: t0.addingTimeInterval(25)), t0.addingTimeInterval(25 + ActivityConstants.abandonRecheckSeconds), "then on the recheck cadence")
        var noPid = ActivitySessionStore()
        noPid.apply(ev(.userPromptSubmit, "c1", at: 1, pid: nil, by: .codex))
        XCTAssertEqual(noPid.nextDeadline(after: t0.addingTimeInterval(1)), t0.addingTimeInterval(21), "the rollout needs no pid")
        var waiting = ActivitySessionStore()
        waiting.apply(ev(.permissionRequest, "c1", at: 1, pid: 300, by: .codex))
        XCTAssertEqual(waiting.nextDeadline(after: t0.addingTimeInterval(1)), t0.addingTimeInterval(1 + ActivityConstants.staleSeconds), "a waiting Codex session has nothing to recheck")
    }
    func testPruneKeepsASessionOnASharedCodexHostForTheCodexCheck() {
        let daemon: Int32 = 40531, desktop: Int32 = 41000
        store.apply(ev(.userPromptSubmit, "tui", pid: daemon, by: .codex))
        store.apply(ev(.userPromptSubmit, "app", pid: desktop, by: .codex))
        store.apply(ev(.userPromptSubmit, "exec", pid: 500, by: .codex))
        store.apply(ev(.userPromptSubmit, pid: daemon))
        store.markCodexHosts(isManagedDaemon: { $0 == daemon }, isSharedHost: { $0 == daemon || $0 == desktop })
        XCTAssertEqual(store.sessions["tui"]?.hostedByManagedDaemon, true)
        XCTAssertEqual(store.sessions["tui"]?.hostedBySharedCodex, true)
        XCTAssertEqual(store.sessions["app"]?.hostedByManagedDaemon, false, "the desktop app's codex is not the managed daemon")
        XCTAssertEqual(store.sessions["app"]?.hostedBySharedCodex, true)
        XCTAssertEqual(store.sessions["exec"]?.hostedBySharedCodex, false, "codex exec records its own process")
        XCTAssertEqual(store.sessions["s1"]?.hostedBySharedCodex, false, "only a Codex session is hosted by a Codex host")
        var asked: [Int32] = []
        store.pruneDead(isAlive: { pid, _ in asked.append(pid); return false }, registrySession: { _ in nil })
        XCTAssertEqual(Set(store.sessions.keys), ["tui", "app"], "a shared host's pid says nothing about the session: the Codex check decides it")
        XCTAssertEqual(state("tui"), .working, "the prune ends nothing it keeps")
        XCTAssertEqual(asked.sorted(), [500, daemon], "a session on a shared host is not asked about; a Claude Code session on the same pid is")
        store.processExited(pid: desktop); XCTAssertEqual(Set(store.sessions.keys), ["tui"], "a host's own death still drops its sessions")
        store.processExited(pid: daemon); XCTAssertTrue(store.sessions.isEmpty, "the daemon's own death still drops its sessions")
    }
    func testPruneAsksAboutEachSessionsOwnAgent() {
        store.apply(ev(.userPromptSubmit)); store.apply(ev(.userPromptSubmit, "c1", pid: 300, by: .codex))
        var asked: [ActivityAgent] = []
        store.pruneDead(isAlive: { _, agent in asked.append(agent); return agent == .codex }, registrySession: { _ in nil })
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
    func testAToolCallAfterARegistryVerdictReopensTheTurn() {
        // A dialog whose hook lines were lost: the registry's idle closes the turn while Claude Code waits.
        store.apply(ev(.userPromptSubmit, turn: "p1")); store.apply(ev(.preToolUse, at: 1, tool: "Bash", turn: "p1"))
        store.turnOver(sessionId: "s1", now: t0.addingTimeInterval(30)); XCTAssertEqual(state(), .done)
        store.apply(ev(.preToolUse, at: 40, tool: "Bash", turn: "p1"))
        XCTAssertEqual(state(), .working, "a new tool call is never an aborted tool's straggler")
        XCTAssertEqual(store.sessions["s1"]?.closedTurnIds, [], "the tool call opens the turn again, as a prompt does")
        store.apply(ev(.postToolUse, at: 41, tool: "Bash", turn: "p1")); XCTAssertEqual(state(), .working)
        XCTAssertEqual(store.sessions["s1"]?.lastMainEventAt, t0.addingTimeInterval(41), "the reopened turn's work counts")
        store.turnOver(sessionId: "s1", now: t0.addingTimeInterval(70)); XCTAssertEqual(store.sessions["s1"]?.closedTurnIds, ["p1"], "and a verdict closes it again")
        store.apply(ev(.preToolUse, at: 80, tool: "AskUserQuestion", turn: "p1")); XCTAssertEqual(state(), .waiting, "a dialog's tool call reopens it into the dialog")
    }
    func testAToolCallAfterAnInterruptDoesNotReopenTheTurn() {
        store.apply(ev(.userPromptSubmit, "c1", pid: 300, by: .codex, turn: "t1"))
        store.apply(ev(.interrupt, "c1", at: 10, pid: 300, by: .codex, turn: "t1")); XCTAssertEqual(state("c1"), .done)
        store.apply(ev(.preToolUse, "c1", at: 12, tool: "Bash", pid: 300, by: .codex, turn: "t1")); XCTAssertEqual(state("c1"), .done)
        store.apply(ev(.preToolUse, "c1", at: 200, tool: "Bash", pid: 300, by: .codex, turn: "t1")); XCTAssertEqual(state("c1"), .done, "past the quarantine too: the id names the aborted turn")
        XCTAssertEqual(store.sessions["c1"]?.closedTurnIds, ["t1"]); XCTAssertEqual(store.sessions["c1"]?.lastMainEventAt, t0.addingTimeInterval(10))
        // Only a prompt opens it; closed afterwards by a verdict, a tool call opens it again.
        store.apply(ev(.userPromptSubmit, "c1", at: 210, pid: 300, by: .codex, turn: "t1")); XCTAssertEqual(state("c1"), .working)
        store.turnOver(sessionId: "c1", now: t0.addingTimeInterval(240)); XCTAssertEqual(state("c1"), .done)
        store.apply(ev(.preToolUse, "c1", at: 250, tool: "Bash", pid: 300, by: .codex, turn: "t1")); XCTAssertEqual(state("c1"), .working, "the verdict's close is not the Interrupt's")
    }
    func testALatePostToolUseAfterAVerdictStillChangesNothing() {
        store.apply(ev(.userPromptSubmit, turn: "p1")); store.apply(ev(.preToolUse, at: 1, tool: "Bash", turn: "p1"))
        store.turnOver(sessionId: "s1", now: t0.addingTimeInterval(30)); XCTAssertEqual(state(), .done)
        store.apply(ev(.postToolUse, at: 31, tool: "Bash", turn: "p1")); XCTAssertEqual(state(), .done)
        store.apply(ev(.postToolUseFailure, at: 32, tool: "Bash", turn: "p1")); XCTAssertEqual(state(), .done)
        store.apply(ev(.permissionRequest, at: 33, tool: "Bash", turn: "p1")); XCTAssertEqual(state(), .done)
        store.apply(ev(.permissionDenied, at: 34, tool: "Bash", turn: "p1")); XCTAssertEqual(state(), .done)
        store.apply(ev(.stop, at: 35, turn: "p1")); XCTAssertEqual(state(), .done)
        store.apply(ev(.notification, at: 36, notif: "permission_prompt", turn: "p1")); XCTAssertEqual(state(), .done)
        store.apply(ev(.preCompact, at: 37, turn: "p1")); store.apply(ev(.postCompact, at: 38, turn: "p1")); XCTAssertEqual(state(), .done)
        store.apply(ev(.preToolUse, at: 39, tool: "Bash", agent: "h1", turn: "p1")); XCTAssertEqual(state(), .done, "a helper's tool call does not reopen it")
        XCTAssertEqual(store.sessions["s1"]?.closedTurnIds, ["p1"]); XCTAssertEqual(store.sessions["s1"]?.lastMainEventAt, t0.addingTimeInterval(1))
        XCTAssertEqual(store.sessions["s1"]?.lastEventAt, t0.addingTimeInterval(39), "the hook is alive")
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

    // MARK: The app's own verdicts

    func verdict(_ value: String?, _ sid: String = "s1", at dt: TimeInterval) -> ActivityEvent {
        var e = ActivityEvent(loggedAt: t0.addingTimeInterval(dt), event: .verdict); e.sessionId = sid; e.verdict = value; return e
    }
    func testAJournaledVerdictReplaysAsTheSameVerdict() {
        let hooks = [ev(.userPromptSubmit, turn: "p1"), ev(.preToolUse, at: 5, tool: "Bash", turn: "p1")]
        // Live: the registry's idle, stamped at 8, is applied at that stamp, then journaled with it.
        var live = ActivitySessionStore()
        hooks.forEach { live.apply($0) }
        let stamp = ActivitySessionStore.rescueStamp(endedAt: t0.addingTimeInterval(8), lastMainEventAt: t0.addingTimeInterval(5), now: t0.addingTimeInterval(30))
        live.turnOver(sessionId: "s1", now: stamp)
        let line = verdict("turn-over", at: 8)
        // Replay: the same hook lines and the verdict line give the same session.
        (hooks + [line]).forEach { store.apply($0) }
        XCTAssertEqual(store.sessions["s1"], live.sessions["s1"])
        XCTAssertEqual(state(), .done); XCTAssertEqual(store.sessions["s1"]?.stateSince, t0.addingTimeInterval(8))
        XCTAssertEqual(store.sessions["s1"]?.closedTurnIds, ["p1"], "the replayed verdict closes the turn, as the live one did")
        XCTAssertEqual(store.sessions["s1"]?.lastEventAt, t0.addingTimeInterval(5), "a verdict is not a sign of life")
        // The tailer hands the live verdict back to the store that applied it: nothing changes.
        live.apply(line); XCTAssertEqual(live.sessions["s1"], store.sessions["s1"])

        // A dialog answered without a hook replays as answered.
        let dialog = [ev(.userPromptSubmit, "s2", turn: "p2"), ev(.preToolUse, "s2", at: 5, tool: "AskUserQuestion", turn: "p2")]
        var liveDialog = ActivitySessionStore()
        dialog.forEach { liveDialog.apply($0) }
        liveDialog.dialogAnswered(sessionId: "s2", now: t0.addingTimeInterval(40))
        var replayDialog = ActivitySessionStore()
        (dialog + [verdict("dialog-answered", "s2", at: 40)]).forEach { replayDialog.apply($0) }
        XCTAssertEqual(replayDialog.sessions["s2"], liveDialog.sessions["s2"])
        XCTAssertEqual(replayDialog.sessions["s2"]?.state, .working); XCTAssertEqual(replayDialog.sessions["s2"]?.lastEventAt, t0.addingTimeInterval(5))
    }
    func testAVerdictThenALaterPromptReplaysInFileOrder() {
        // The journal holds the live verdict, then the next prompt: replayed in that order, the prompt opens its turn.
        let lines = [ev(.userPromptSubmit, turn: "p1"), ev(.preToolUse, at: 5, tool: "Bash", turn: "p1"),
                     verdict("turn-over", at: 8), ev(.userPromptSubmit, at: 40, turn: "p2")]
        lines.forEach { store.apply($0) }
        XCTAssertEqual(state(), .working); XCTAssertEqual(store.sessions["s1"]?.lastMainTurnId, "p2")
        XCTAssertEqual(store.sessions["s1"]?.closedTurnIds, ["p1"], "the verdict closed its own turn; the prompt's is open")
        store.apply(ev(.postToolUse, at: 41, tool: "Bash", turn: "p2")); XCTAssertEqual(state(), .working)
        store.apply(ev(.postToolUse, at: 42, tool: "Bash", turn: "p1")); XCTAssertEqual(store.sessions["s1"]?.lastMainEventAt, t0.addingTimeInterval(41), "the closed turn's straggler still changes nothing")
    }
    func testAVerdictForAnUnknownSessionIsIgnored() {
        store.apply(verdict("turn-over", "ghost", at: 10)); XCTAssertTrue(store.sessions.isEmpty, "a verdict never creates a session")
        store.apply(ev(.userPromptSubmit))
        store.apply(verdict("turn-over", "ghost", at: 10)); XCTAssertEqual(state(), .working, "another session's verdict")
        store.apply(verdict("resting", at: 10)); XCTAssertEqual(state(), .working, "an unknown verdict decides nothing")
        store.apply(verdict(nil, at: 10)); XCTAssertEqual(state(), .working)
        var noSession = verdict("turn-over", at: 10); noSession.sessionId = nil
        store.apply(noSession); XCTAssertEqual(state(), .working)
    }
    func testAVerdictOlderThanTheLastMainEventIsIgnored() {
        store.apply(ev(.userPromptSubmit, turn: "p1")); store.apply(ev(.postToolUse, at: 10, tool: "Bash", turn: "p1"))
        store.apply(verdict("turn-over", at: 9)); XCTAssertEqual(state(), .working, "the turn went on after the verdict's stamp")
        store.apply(ev(.preToolUse, at: 20, tool: "AskUserQuestion", turn: "p1")); XCTAssertEqual(state(), .waiting)
        store.apply(verdict("dialog-answered", at: 19)); XCTAssertEqual(state(), .waiting, "an answer to an earlier dialog")
        store.apply(verdict("dialog-answered", at: 20)); XCTAssertEqual(state(), .working, "the same instant still applies")
        store.apply(verdict("turn-over", at: 30)); XCTAssertEqual(state(), .done)
        XCTAssertEqual(store.sessions["s1"]?.lastEventAt, t0.addingTimeInterval(20))
    }
    func testTheRescueStampIsWhenTheTurnEndedWithinOurLastEventAndNow() {
        let last = t0.addingTimeInterval(10), now = t0.addingTimeInterval(40)
        XCTAssertEqual(ActivitySessionStore.rescueStamp(endedAt: t0.addingTimeInterval(25), lastMainEventAt: last, now: now), t0.addingTimeInterval(25), "the source's own stamp")
        XCTAssertEqual(ActivitySessionStore.rescueStamp(endedAt: t0.addingTimeInterval(3), lastMainEventAt: last, now: now), last, "never before our last main-agent event")
        XCTAssertEqual(ActivitySessionStore.rescueStamp(endedAt: t0.addingTimeInterval(90), lastMainEventAt: last, now: now), now, "never in the future")
        XCTAssertEqual(ActivitySessionStore.rescueStamp(endedAt: now, lastMainEventAt: last, now: now), now, "an answer without a stamp is now")
    }
    func testPruneDropsAPidWhoseRegistryNamesAnotherSession() {
        store.apply(ev(.userPromptSubmit, "recycled", pid: 100))
        store.apply(ev(.userPromptSubmit, "same", pid: 200))
        store.apply(ev(.userPromptSubmit, "norecord", pid: 300))
        store.apply(ev(.userPromptSubmit, "c1", pid: 400, by: .codex))
        let records: [Int32: String] = [100: "another", 200: "same", 400: "another"]
        var asked: [Int32] = []
        store.pruneDead(isAlive: { _, _ in true }, registrySession: { pid in asked.append(pid); return records[pid] })
        XCTAssertEqual(Set(store.sessions.keys), ["same", "norecord", "c1"], "a record naming another session is a recycled pid; no record proves nothing")
        XCTAssertEqual(asked.sorted(), [100, 200, 300], "the registry is Claude Code's: a Codex session is not asked")
        asked = []
        store.pruneDead(isAlive: { pid, _ in pid != 200 }, registrySession: { pid in asked.append(pid); return records[pid] })
        XCTAssertEqual(Set(store.sessions.keys), ["norecord", "c1"]); XCTAssertEqual(asked, [300], "a dead pid is not asked about")
    }
    func testAbandonCandidatesAtLaunchIgnoreTheQuietGate() {
        store.apply(ev(.userPromptSubmit, at: 10))
        store.apply(ev(.userPromptSubmit, "held", at: 10)); store.apply(ev(.stop, "held", at: 11, bg: ["b1"]))
        store.apply(ev(.userPromptSubmit, "c1", at: 10, pid: 300, by: .codex))
        let justNow = t0.addingTimeInterval(12)
        XCTAssertTrue(store.abandonCandidates(at: justNow).isEmpty, "live, the quiet gate holds")
        XCTAssertEqual(store.abandonCandidates(at: justNow, quietSeconds: 0).map(\.sessionId), ["s1"],
                       "at launch every working Claude Code session is asked; a held Stop and a Codex session are not")
    }
}
