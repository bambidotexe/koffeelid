import XCTest
import KoffeeLidCore

/// Fixtures mirror the shapes of Copilot CLI 1.0.88's `events.jsonl` lines (`type`, `data`, `id`,
/// `timestamp`, `parentId`) and the order they came in on this Mac's probe runs (a `-p` run, an interactive
/// run, a Ctrl+C at a permission prompt, a failed model call, a subagent); every value, and all content, is
/// made up or left out.
final class CopilotTranscriptTailTests: XCTestCase {
    let sid = "5e55a0de-0000-4000-8000-000000000001"
    let subagent = "5ab0a9e7-0000-4000-8000-000000000002"
    let root = "/Users/x/.copilot/session-state"

    func line(_ type: String, at time: String, _ data: String = "") -> String {
        "{\"type\":\"\(type)\",\"data\":{\(data)},\"id\":\"0d000000-0000-4000-8000-000000000000\",\"timestamp\":\"\(time)\",\"parentId\":null}"
    }
    /// The line Copilot writes as a hook starts: its type, and the payload the hook is handed.
    func hookStart(_ hookType: String, session: String? = nil, key: String = "sessionId", at time: String) -> String {
        let input = session.map { "\"\(key)\":\"\($0)\"," } ?? ""
        return line("hook.start", at: time,
                    "\"hookInvocationId\":\"h1\",\"hookType\":\"\(hookType)\",\"input\":{\(input)\"timestamp\":1790000000000,\"cwd\":\"/Users/x/repo\"}")
    }
    func tail(_ lines: [String]) -> Data { Data((lines.joined(separator: "\n") + "\n").utf8) }
    func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: iso)!
    }
    func verdict(_ lines: [String]) -> CopilotTranscriptTail.Verdict { CopilotTranscriptTail.verdict(tail: tail(lines), sessionId: sid) }

    // MARK: The verdict

    func testAnAbortAtAPermissionPromptEndsTheTurn() {
        // Ctrl+C while the permission prompt was open: no hook at all, three lines in the file.
        XCTAssertEqual(verdict([
            hookStart("userPromptSubmitted", session: sid, at: "2026-09-25T23:49:56.500Z"),
            line("user.message", at: "2026-09-25T23:49:56.717Z", "\"interactionId\":\"i1\""),
            line("assistant.turn_start", at: "2026-09-25T23:49:56.934Z", "\"turnId\":\"0\""),
            line("assistant.message", at: "2026-09-25T23:50:28.117Z"),
            line("tool.execution_start", at: "2026-09-25T23:50:28.118Z", "\"toolName\":\"bash\""),
            hookStart("preToolUse", session: sid, at: "2026-09-25T23:50:28.118Z"),
            line("permission.requested", at: "2026-09-25T23:50:28.573Z"),
            hookStart("notification", session: sid, at: "2026-09-25T23:50:28.573Z"),
            line("hook.end", at: "2026-09-25T23:50:28.786Z", "\"hookType\":\"notification\",\"success\":true"),
            line("permission.completed", at: "2026-09-25T23:50:34.360Z", "\"result\":{\"kind\":\"cancelled\"}"),
            line("assistant.turn_end", at: "2026-09-25T23:50:34.361Z"),
            line("abort", at: "2026-09-25T23:50:34.361Z", "\"reason\":\"user_initiated\""),
        ]), .aborted(at: date("2026-09-25T23:50:34.361Z")))
        for reason in ["user_abort", "remote_command", "autopilot_credit_limit", "a_reason_not_seen_yet"] {
            XCTAssertEqual(verdict([line("abort", at: "2026-09-25T23:50:34.361Z", "\"reason\":\"\(reason)\"")]),
                           .aborted(at: date("2026-09-25T23:50:34.361Z")), "an abort ends the turn whatever its reason")
        }
    }
    func testASessionErrorIsAFailedTurn() {
        // A model call that gave up: `errorOccurred` (not subscribed), no `agentStop`.
        XCTAssertEqual(verdict([
            hookStart("userPromptSubmitted", session: sid, at: "2026-09-25T23:50:45.571Z"),
            line("user.message", at: "2026-09-25T23:50:45.788Z"),
            line("assistant.turn_start", at: "2026-09-25T23:50:45.792Z"),
            hookStart("errorOccurred", session: sid, at: "2026-09-25T23:50:45.799Z"),
            line("hook.end", at: "2026-09-25T23:50:46.010Z", "\"hookType\":\"errorOccurred\",\"success\":true"),
            line("assistant.turn_end", at: "2026-09-25T23:50:46.010Z"),
            line("session.error", at: "2026-09-25T23:50:46.010Z", "\"errorType\":\"query\",\"statusCode\":400"),
        ]), .failed(at: date("2026-09-25T23:50:46.010Z")))
    }
    func testTheSessionsOwnAgentStopIsAFinish() {
        XCTAssertEqual(verdict([
            line("tool.execution_complete", at: "2026-09-25T23:44:41.725Z", "\"success\":true"),
            line("assistant.turn_end", at: "2026-09-25T23:44:41.726Z"),
            line("assistant.turn_start", at: "2026-09-25T23:44:41.727Z"),
            line("assistant.message", at: "2026-09-25T23:44:42.662Z"),
            line("assistant.turn_end", at: "2026-09-25T23:44:42.663Z"),
            hookStart("agentStop", session: sid, at: "2026-09-25T23:44:42.664Z"),
            line("hook.end", at: "2026-09-25T23:44:42.900Z", "\"hookType\":\"agentStop\",\"success\":true"),
            line("session.usage_checkpoint", at: "2026-09-25T23:44:42.901Z"),
        ]), .complete(at: date("2026-09-25T23:44:42.664Z")), "the hook's start is the stamp")
        XCTAssertEqual(verdict([line("assistant.message", at: "2026-09-25T23:44:42.662Z"),
                                hookStart("agentStop", session: sid, key: "session_id", at: "2026-09-25T23:44:42.664Z")]),
                       .complete(at: date("2026-09-25T23:44:42.664Z")), "a snake payload names the session too")
    }
    func testASubagentsAgentStopIsNotTheSessionsEnd() {
        // The subagent's `agentStop` runs under the subagent's id and is written into its parent's file.
        let running = [
            line("tool.execution_start", at: "2026-09-25T23:50:50.371Z", "\"toolName\":\"task\""),
            hookStart("preToolUse", session: sid, at: "2026-09-25T23:50:50.371Z"),
            line("subagent.started", at: "2026-09-25T23:50:50.584Z"),
            hookStart("subagentStart", session: sid, at: "2026-09-25T23:50:50.611Z"),
            hookStart("userPromptSubmitted", session: subagent, at: "2026-09-25T23:50:50.832Z"),
            line("user.message", at: "2026-09-25T23:50:51.042Z"),
            line("assistant.turn_start", at: "2026-09-25T23:50:51.046Z"),
            hookStart("agentStop", session: subagent, at: "2026-09-25T23:50:51.046Z"),
        ]
        XCTAssertEqual(verdict(running), .running, "the parent's turn goes on")
        XCTAssertEqual(verdict(running + [
            line("hook.end", at: "2026-09-25T23:50:51.264Z", "\"hookType\":\"agentStop\",\"success\":true"),
            hookStart("subagentStop", session: sid, at: "2026-09-25T23:50:51.265Z"),
            line("subagent.completed", at: "2026-09-25T23:50:51.476Z"),
            hookStart("postToolUse", session: sid, at: "2026-09-25T23:50:51.476Z"),
            line("tool.execution_complete", at: "2026-09-25T23:50:51.693Z"),
            line("assistant.turn_end", at: "2026-09-25T23:50:51.694Z"),
            line("assistant.turn_start", at: "2026-09-25T23:50:51.694Z"),
            line("assistant.message", at: "2026-09-25T23:50:51.705Z"),
            line("assistant.turn_end", at: "2026-09-25T23:50:51.705Z"),
            hookStart("agentStop", session: sid, at: "2026-09-25T23:50:51.706Z"),
        ]), .complete(at: date("2026-09-25T23:50:51.706Z")), "then the parent's own stop ends it")
        XCTAssertEqual(verdict([line("assistant.message", at: "2026-09-25T23:44:42.662Z"), hookStart("agentStop", at: "2026-09-25T23:44:42.664Z")]),
                       .running, "an agentStop that names no session is nobody's end")
        XCTAssertEqual(CopilotTranscriptTail.verdict(tail: tail([hookStart("agentStop", session: "", at: "2026-09-25T23:44:42.664Z")]), sessionId: ""),
                       .unreadable, "an empty id names no session")
    }
    func testASessionShutdownIsAnEnd() {
        XCTAssertEqual(verdict([
            hookStart("agentStop", session: sid, at: "2026-09-25T23:40:08.403Z"),
            hookStart("sessionEnd", session: sid, at: "2026-09-25T23:40:08.539Z"),
            line("session.usage_checkpoint", at: "2026-09-25T23:40:08.668Z"),
            line("session.shutdown", at: "2026-09-25T23:40:08.679Z", "\"shutdownType\":\"routine\""),
        ]), .ended(at: date("2026-09-25T23:40:08.679Z")))
    }
    func testEachStepOfATurnIsRunningAndTheLastMarkerWins() {
        for type in ["user.message", "assistant.turn_start", "assistant.message", "tool.execution_start", "tool.execution_complete",
                     "permission.requested", "permission.completed"] {
            XCTAssertEqual(verdict([line("abort", at: "2026-09-25T23:50:34.361Z", "\"reason\":\"user_initiated\""),
                                    line(type, at: "2026-09-25T23:50:45.788Z")]), .running, "\(type) after an abort: the next turn runs")
        }
        XCTAssertEqual(verdict([line("session.error", at: "2026-09-25T23:50:46.010Z"), line("user.message", at: "2026-09-25T23:50:50.355Z")]), .running)
    }
    func testLinesThatAreNotTurnMarkersAreSkipped() {
        let abort = line("abort", at: "2026-09-25T23:50:34.361Z", "\"reason\":\"user_initiated\"")
        for type in ["assistant.turn_end", "hook.end", "session.usage_checkpoint", "system.notification", "system.message", "session.model_change",
                     "model.turn_started", "subagent.completed", "session.compaction_start", "session.compaction_complete", "session.idle",
                     "session.start", "a.type.not.seen.yet"] {
            XCTAssertEqual(verdict([abort, line(type, at: "2026-09-25T23:50:40.000Z")]), .aborted(at: date("2026-09-25T23:50:34.361Z")), type)
        }
        for hookType in ["userPromptSubmitted", "sessionStart", "preToolUse", "postToolUse", "notification", "errorOccurred", "subagentStop",
                         "preCompact", "sessionEnd"] {
            XCTAssertEqual(verdict([abort, hookStart(hookType, session: sid, at: "2026-09-25T23:50:40.000Z")]),
                           .aborted(at: date("2026-09-25T23:50:34.361Z")), "a \(hookType) hook's start is not a turn marker")
        }
        // Only the line's own type counts, never a type named inside its data.
        XCTAssertEqual(verdict([line("user.message", at: "2026-09-25T23:50:45.788Z"),
                                line("system.notification", at: "2026-09-25T23:50:46.000Z", "\"type\":\"abort\",\"kind\":\"{\\\"type\\\":\\\"abort\\\"}\"")]),
                       .running)
    }
    func testAnUnreadableOrTruncatedTailDecidesNothing() {
        XCTAssertEqual(CopilotTranscriptTail.verdict(tail: Data(), sessionId: sid), .unreadable)
        XCTAssertEqual(CopilotTranscriptTail.verdict(tail: Data("not json\n{\"type\":".utf8), sessionId: sid), .unreadable)
        XCTAssertEqual(CopilotTranscriptTail.verdict(tail: Data([0xFF, 0xFE, 0x0A, 0x00]), sessionId: sid), .unreadable)
        XCTAssertEqual(verdict([line("session.start", at: "2026-09-25T23:40:03.696Z"), line("session.model_change", at: "2026-09-25T23:40:03.700Z")]),
                       .unreadable, "no turn marker at all")
        XCTAssertEqual(verdict([line("abort", at: "yesterday")]), .unreadable, "an end without a readable stamp is not a marker")
        XCTAssertEqual(verdict(["[\"abort\"]", "\"abort\""]), .unreadable, "not an object")
        XCTAssertEqual(verdict([line("abort", at: "2026-09-25T23:50:34Z")]), .aborted(at: date("2026-09-25T23:50:34.000Z")), "a stamp without its milliseconds")
        // The last line still being written is cut: the marker before it stands.
        let writing = tail([line("user.message", at: "2026-09-25T23:50:45.788Z")]) + Data("{\"type\":\"abort\",\"data\":{\"rea".utf8)
        XCTAssertEqual(CopilotTranscriptTail.verdict(tail: writing, sessionId: sid), .running)
    }
    func testACutFirstLineIsSkipped() {
        let whole = line("session.error", at: "2026-09-25T23:50:46.010Z")
        let cut = String(whole.dropFirst(10))
        XCTAssertEqual(verdict([cut, line("user.message", at: "2026-09-25T23:50:50.355Z")]), .running)
        XCTAssertEqual(verdict([cut, line("hook.end", at: "2026-09-25T23:50:50.355Z")]), .unreadable, "the cut line's marker is not read")
        XCTAssertEqual(CopilotTranscriptTail.tailBytes, 65_536)
    }

    // MARK: The file

    func testOnlyTheSessionsOwnEventsFileIsRead() {
        let path = "\(root)/\(sid)/events.jsonl"
        XCTAssertTrue(CopilotTranscriptTail.isTranscript(path: path, ofSession: sid, sessionStateDirectory: root))
        XCTAssertTrue(CopilotTranscriptTail.isTranscript(path: path, ofSession: sid, sessionStateDirectory: root + "/"))
        XCTAssertTrue(CopilotTranscriptTail.isTranscript(path: "\(root)//\(sid)/events.jsonl", ofSession: sid, sessionStateDirectory: root))
        XCTAssertFalse(CopilotTranscriptTail.isTranscript(path: "\(root)/\(subagent)/events.jsonl", ofSession: sid, sessionStateDirectory: root),
                       "another session's file")
        XCTAssertFalse(CopilotTranscriptTail.isTranscript(path: "\(root)/\(sid)/workspace.yaml", ofSession: sid, sessionStateDirectory: root))
        XCTAssertFalse(CopilotTranscriptTail.isTranscript(path: "\(root)/\(sid)/events.jsonl.bak", ofSession: sid, sessionStateDirectory: root))
        XCTAssertFalse(CopilotTranscriptTail.isTranscript(path: "\(root)/\(sid)/files/events.jsonl", ofSession: sid, sessionStateDirectory: root))
        XCTAssertFalse(CopilotTranscriptTail.isTranscript(path: "\(root)/events.jsonl", ofSession: sid, sessionStateDirectory: root))
        XCTAssertFalse(CopilotTranscriptTail.isTranscript(path: "/Users/x/.copilot/session-state-old/\(sid)/events.jsonl", ofSession: sid, sessionStateDirectory: root))
        XCTAssertFalse(CopilotTranscriptTail.isTranscript(path: "\(root)/\(sid)/../../../../etc/events.jsonl", ofSession: sid, sessionStateDirectory: root), "no way out")
        XCTAssertFalse(CopilotTranscriptTail.isTranscript(path: "\(root)/./\(sid)/events.jsonl", ofSession: sid, sessionStateDirectory: root))
        XCTAssertFalse(CopilotTranscriptTail.isTranscript(path: "Users/x/.copilot/session-state/\(sid)/events.jsonl", ofSession: sid, sessionStateDirectory: root),
                       "absolute only")
        XCTAssertFalse(CopilotTranscriptTail.isTranscript(path: "/tmp/fifo/\(sid)/events.jsonl", ofSession: sid, sessionStateDirectory: root))
        for odd in ["", ".", ".."] {
            XCTAssertFalse(CopilotTranscriptTail.isTranscript(path: "\(root)/\(odd)/events.jsonl", ofSession: odd, sessionStateDirectory: root), "\(odd) names no session")
        }
        XCTAssertFalse(CopilotTranscriptTail.isTranscript(path: "\(root)/a/b/events.jsonl", ofSession: "a/b", sessionStateDirectory: root))
        XCTAssertFalse(CopilotTranscriptTail.isTranscript(path: path, ofSession: sid, sessionStateDirectory: ""))
        XCTAssertFalse(CopilotTranscriptTail.isTranscript(path: path, ofSession: sid, sessionStateDirectory: "Users/x/.copilot/session-state"))
        XCTAssertFalse(CopilotTranscriptTail.isTranscript(path: "/Users/x/.copilot/x/../session-state/\(sid)/events.jsonl", ofSession: sid,
                                                          sessionStateDirectory: "/Users/x/.copilot/x/../session-state"))
    }

    // MARK: The decision

    let lastEvent = Date(timeIntervalSince1970: 1_790_000_000)
    var checkedAt: Date { lastEvent.addingTimeInterval(30) }
    func decide(_ verdict: CopilotTranscriptTail.Verdict, writtenAt: Date? = nil) -> CopilotTranscriptTail.Decision {
        CopilotTranscriptTail.decision(verdict: verdict, lastMainEventAt: lastEvent, writtenAt: writtenAt ?? lastEvent.addingTimeInterval(25), now: checkedAt)
    }
    func testAnEndMarkerAfterOurLastEventEndsTheTurn() {
        let at = lastEvent.addingTimeInterval(1)
        XCTAssertEqual(decide(.complete(at: at)), .turnOver(reason: "finished", at: at), "the decision carries the marker's stamp")
        XCTAssertEqual(decide(.aborted(at: lastEvent.addingTimeInterval(0.001))), .turnOver(reason: "aborted", at: lastEvent.addingTimeInterval(0.001)))
        XCTAssertEqual(decide(.failed(at: at)), .turnOver(reason: "failed", at: at))
        XCTAssertEqual(decide(.ended(at: at)), .turnOver(reason: "ended", at: at))
    }
    func testAnEndMarkerStampedBeforeOurLastEventDecidesNothing() {
        // The previous turn's end, before our prompt: Copilot names no turn, so the stamp alone decides.
        let earlier = lastEvent.addingTimeInterval(-30)
        for marker in [CopilotTranscriptTail.Verdict.complete(at: earlier), .aborted(at: earlier), .failed(at: earlier), .ended(at: earlier),
                       .complete(at: lastEvent), .aborted(at: lastEvent)] {
            XCTAssertEqual(decide(marker), .nothing, "\(marker)")
        }
    }
    func testARunningTranscriptKeepsTheSessionWhileCopilotWritesIt() {
        let written = lastEvent.addingTimeInterval(25)
        XCTAssertEqual(decide(.running), .busy(writtenAt: written))
        let almostStale = checkedAt.addingTimeInterval(1 - ActivityConstants.staleSeconds)
        XCTAssertEqual(decide(.running, writtenAt: almostStale), .busy(writtenAt: almostStale), "written within 2 h")
        XCTAssertEqual(CopilotTranscriptTail.decision(verdict: .running, lastMainEventAt: lastEvent, writtenAt: nil, now: checkedAt),
                       .busy(writtenAt: nil), "a file whose date could not be read is taken at its word")
    }
    func testATranscriptSilentForTwoHoursNoLongerKeepsTheSessionAlive() {
        let stale = checkedAt.addingTimeInterval(-ActivityConstants.staleSeconds)
        XCTAssertEqual(decide(.running, writtenAt: stale), .nothing, "Copilot stopped writing 2 h ago: staleness decides")
        let marker = lastEvent.addingTimeInterval(1)
        XCTAssertEqual(decide(.aborted(at: marker), writtenAt: stale), .turnOver(reason: "aborted", at: marker), "the date never keeps an end from ending the turn")
    }
    func testAnUnreadableTailDecidesNothing() {
        XCTAssertEqual(decide(.unreadable), .nothing)
        XCTAssertEqual(decide(CopilotTranscriptTail.verdict(tail: Data("garbage".utf8), sessionId: sid)), .nothing)
    }
}
